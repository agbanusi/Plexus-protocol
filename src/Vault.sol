// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@solmate/tokens/ERC20.sol";
import {ERC4626} from "@solmate/tokens/ERC4626.sol";
import {SafeTransferLib} from "@solmate/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "@solmate/utils/FixedPointMathLib.sol";
import {Owned} from "@solmate/auth/Owned.sol";
import {Allocator} from "./Allocator.sol";
import {IOracle} from "./interfaces/IOracle.sol";

/// @notice One base asset (a stable) paired with one RWA. LPs deposit the base asset and earn
/// the redemption fee; RWA holders swap into the base asset instantly via `redeemRwa`. Idle
/// base asset is allocated out through the inherited Allocator. The RWA the vault takes on is
/// settled back into the base asset out-of-band through `redeemer`, which the owner drives
/// with `externalRedeem` and `finalizeExternalRedeem`.
contract Vault is ERC4626, Allocator {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    uint256 public constant MAX_REDEMPTION_FEE = 0.1e18;

    ERC20 public immutable rwa;
    uint256 internal immutable baseScale;
    uint256 internal immutable rwaScale;

    IOracle public oracle;
    /// @notice This vault's redemption contract, defined at onboarding. Each vault keeps its
    /// own, which is what lets a new asset onboard without touching any other vault.
    address public redeemer;

    /// @notice Fee taken from an instant redemption, in WAD. Accrues to LPs.
    uint256 public redemptionFee;
    /// @notice Max RWA exposure, valued in base asset. Bounds this vault's risk.
    uint256 public rwaCap;
    /// @notice RWA sent to the redeemer and not yet settled. Still owned by the vault.
    uint256 public rwaInRedemption;

    event OracleSet(address indexed oracle);
    event RedeemerSet(address indexed redeemer);
    event ParamsSet(uint256 redemptionFee, uint256 rwaCap);
    event RwaRedeemed(address indexed caller, uint256 rwaIn, uint256 baseOut, uint256 fee);
    event ExternalRedeemStarted(uint256 rwaIn);
    event ExternalRedeemFinalized(uint256 rwaOut, uint256 baseIn);

    error ZeroAddress();
    error FeeTooHigh();
    error RwaCapExceeded();
    error SlippageExceeded();
    error NoRedeemer();
    error ZeroAmount();

    constructor(address owner_, ERC20 base_, ERC20 rwa_, IOracle oracle_, string memory name_, string memory symbol_)
        ERC4626(base_, name_, symbol_)
        Owned(owner_)
    {
        if (
            owner_ == address(0) || address(base_) == address(0) || address(rwa_) == address(0)
                || address(oracle_) == address(0)
        ) revert ZeroAddress();

        rwa = rwa_;
        oracle = oracle_;
        baseScale = 10 ** base_.decimals();
        rwaScale = 10 ** rwa_.decimals();
    }

    receive() external payable {}

    function baseAsset() public view override returns (ERC20) {
        return asset;
    }

    /* ------------------------------ admin ------------------------------ */

    function setOracle(IOracle oracle_) external onlyOwner {
        if (address(oracle_) == address(0)) revert ZeroAddress();
        oracle = oracle_;
        emit OracleSet(address(oracle_));
    }

    function setRedeemer(address redeemer_) external onlyOwner {
        redeemer = redeemer_;
        emit RedeemerSet(redeemer_);
    }

    function setParams(uint256 redemptionFee_, uint256 rwaCap_) external onlyOwner {
        if (redemptionFee_ > MAX_REDEMPTION_FEE) revert FeeTooHigh();
        redemptionFee = redemptionFee_;
        rwaCap = rwaCap_;
        emit ParamsSet(redemptionFee_, rwaCap_);
    }

    /* ---------------------------- accounting ---------------------------- */

    /// @notice Idle base asset + base asset out in targets + RWA marked at the oracle price,
    /// counting RWA that is sitting with the redeemer mid-settlement.
    function totalAssets() public view override(ERC4626, Allocator) returns (uint256) {
        return asset.balanceOf(address(this)) + totalAllocated() + rwaValue(rwaExposure());
    }

    /// @notice All RWA the vault is on the hook for, held or mid-settlement.
    function rwaExposure() public view returns (uint256) {
        return rwa.balanceOf(address(this)) + rwaInRedemption;
    }

    function convertToShares(uint256 assets) public view override returns (uint256) {
        return assets.mulDivDown(totalSupply + 1, totalAssets() + 1);
    }

    function convertToAssets(uint256 shares) public view override returns (uint256) {
        return shares.mulDivDown(totalAssets() + 1, totalSupply + 1);
    }

    function previewMint(uint256 shares) public view override returns (uint256) {
        return shares.mulDivUp(totalAssets() + 1, totalSupply + 1);
    }

    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        return assets.mulDivUp(totalSupply + 1, totalAssets() + 1);
    }

    /// @notice Value `rwaAmount` in base asset at the oracle price.
    function rwaValue(uint256 rwaAmount) public view returns (uint256) {
        if (rwaAmount == 0) return 0;
        return rwaAmount.mulDivDown(oracle.price() * baseScale, WAD * rwaScale);
    }

    /// @notice Base asset paid out for `rwaAmount`, net of the redemption fee.
    function previewRedeemRwa(uint256 rwaAmount) public view returns (uint256) {
        return rwaValue(rwaAmount).mulDivDown(WAD - redemptionFee, WAD);
    }

    /* --------------------------- redemption --------------------------- */

    /// @notice Swap RWA for base asset instantly at the oracle price, less the fee.
    function redeemRwa(uint256 rwaAmount, uint256 minBaseOut) external nonReentrant returns (uint256 baseOut) {
        if (rwaAmount == 0) revert ZeroAmount();

        uint256 value = rwaValue(rwaAmount);
        if (rwaValue(rwaExposure()) + value > rwaCap) revert RwaCapExceeded();

        baseOut = value.mulDivDown(WAD - redemptionFee, WAD);
        if (baseOut < minBaseOut) revert SlippageExceeded();

        rwa.safeTransferFrom(msg.sender, address(this), rwaAmount);

        _ensureIdle(baseOut);
        asset.safeTransfer(msg.sender, baseOut);

        emit RwaRedeemed(msg.sender, rwaAmount, baseOut, value - baseOut);
    }

    /// @notice Push accumulated RWA into the redeemer. Settlement is not atomic and may take
    /// days, so the RWA stays on the books as `rwaInRedemption` until it is finalized.
    function externalRedeem(bytes calldata data, uint256 value)
        external
        onlyOwner
        nonReentrant
        returns (bytes memory result)
    {
        if (redeemer == address(0)) revert NoRedeemer();

        uint256 before = rwa.balanceOf(address(this));

        rwa.safeApprove(redeemer, before);
        result = _callRedeemer(data, value);
        rwa.safeApprove(redeemer, 0);

        uint256 rwaIn = before - rwa.balanceOf(address(this));
        rwaInRedemption += rwaIn;

        emit ExternalRedeemStarted(rwaIn);
    }

    /// @notice Finalize settlement: collect the base asset from the issuer and put it to work.
    function finalizeExternalRedeem(uint256 rwaAmount, bytes calldata data, uint256 value)
        external
        onlyOwner
        nonReentrant
        returns (bytes memory result)
    {
        if (redeemer == address(0)) revert NoRedeemer();

        uint256 before = asset.balanceOf(address(this));
        result = _callRedeemer(data, value);
        uint256 baseIn = asset.balanceOf(address(this)) - before;

        rwaInRedemption -= rwaAmount;
        if (liquidityTarget != address(0)) _allocate(liquidityTarget, baseIn);

        emit ExternalRedeemFinalized(rwaAmount, baseIn);
    }

    /// @dev Settlement flows are issuer-specific, so the owner supplies the calldata. The
    /// target is pinned to `redeemer` rather than being a free-form call.
    function _callRedeemer(bytes calldata data, uint256 value) internal returns (bytes memory) {
        (bool success, bytes memory result) = redeemer.call{value: value}(data);
        if (!success) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
        return result;
    }

    /* ------------------------------ hooks ------------------------------ */

    function afterDeposit(uint256 assets, uint256) internal override {
        if (liquidityTarget != address(0)) _allocate(liquidityTarget, assets);
    }

    function beforeWithdraw(uint256 assets, uint256) internal override {
        _ensureIdle(assets);
    }
}

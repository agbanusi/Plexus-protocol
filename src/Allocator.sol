// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@solmate/tokens/ERC20.sol";
import {ERC4626} from "@solmate/tokens/ERC4626.sol";
import {SafeTransferLib} from "@solmate/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "@solmate/utils/FixedPointMathLib.sol";
import {Owned} from "@solmate/auth/Owned.sol";

/// @notice Allocation layer inherited by every vault. Idle base asset is pushed into external
/// ERC4626 vaults, which is what lets many vaults draw on the same liquidity base without
/// each one needing its own dedicated pool. Targets are ERC4626 over the same base asset,
/// so there is no adapter layer.
abstract contract Allocator is Owned {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    uint256 internal constant WAD = 1e18;

    address[] public targets;
    /// @notice Max base asset this vault may hold in a target. Zero disables the target.
    mapping(address target => uint256) public absoluteCap;
    /// @notice Max share of totalAssets this vault may hold in a target, in WAD.
    mapping(address target => uint256) public relativeCap;
    mapping(address target => bool) public isTarget;
    mapping(address account => bool) public isAllocator;

    /// @notice Target that deposits flow into, and that withdrawals pull back from.
    address public liquidityTarget;

    event CapsSet(address indexed target, uint256 absoluteCap, uint256 relativeCap);
    event TargetRemoved(address indexed target);
    event AllocatorSet(address indexed account, bool enabled);
    event LiquidityTargetSet(address indexed target);
    event Allocated(address indexed caller, address indexed target, uint256 assets);
    event Deallocated(address indexed caller, address indexed target, uint256 assets);

    error NotAllocator();
    error NotTarget();
    error SelfTarget();
    error AssetMismatch();
    error AbsoluteCapExceeded();
    error RelativeCapExceeded();
    error TargetNotEmpty();

    modifier onlyAllocator() {
        if (!isAllocator[msg.sender] && msg.sender != owner) revert NotAllocator();
        _;
    }

    /// @dev Supplied by the inheriting vault.
    function baseAsset() public view virtual returns (ERC20);

    function totalAssets() public view virtual returns (uint256);

    /* ------------------------------ admin ------------------------------ */

    function setAllocator(address account, bool enabled) external onlyOwner {
        isAllocator[account] = enabled;
        emit AllocatorSet(account, enabled);
    }

    function setCaps(address target, uint256 absoluteCap_, uint256 relativeCap_) external onlyOwner {
        if (target == address(this)) revert SelfTarget();
        if (address(ERC4626(target).asset()) != address(baseAsset())) revert AssetMismatch();
        if (relativeCap_ > WAD) revert RelativeCapExceeded();

        if (!isTarget[target]) {
            isTarget[target] = true;
            targets.push(target);
        }
        absoluteCap[target] = absoluteCap_;
        relativeCap[target] = relativeCap_;

        totalAssets();

        emit CapsSet(target, absoluteCap_, relativeCap_);
    }

    function removeTarget(address target) external onlyOwner {
        if (!isTarget[target]) revert NotTarget();
        if (ERC4626(target).balanceOf(address(this)) != 0) revert TargetNotEmpty();

        isTarget[target] = false;
        absoluteCap[target] = 0;
        relativeCap[target] = 0;
        if (liquidityTarget == target) liquidityTarget = address(0);

        for (uint256 i; i < targets.length; ++i) {
            if (targets[i] == target) {
                targets[i] = targets[targets.length - 1];
                targets.pop();
                break;
            }
        }
        emit TargetRemoved(target);
    }

    function setLiquidityTarget(address target) external onlyOwner {
        if (target != address(0) && !isTarget[target]) revert NotTarget();
        liquidityTarget = target;
        emit LiquidityTargetSet(target);
    }

    /* --------------------------- allocation --------------------------- */

    /// @notice Base asset this vault currently holds in `target`.
    function allocation(address target) public view returns (uint256) {
        return ERC4626(target).previewRedeem(ERC4626(target).balanceOf(address(this)));
    }

    /// @notice Base asset held across every target.
    function totalAllocated() public view returns (uint256) {
        uint256 total;
        for (uint256 i; i < targets.length; ++i) {
            total += allocation(targets[i]);
        }
        return total;
    }

    function allocate(address target, uint256 assets) external onlyAllocator {
        _allocate(target, assets);
    }

    function deallocate(address target, uint256 assets) external onlyAllocator {
        _deallocate(target, assets);
    }

    function _allocate(address target, uint256 assets) internal {
        if (!isTarget[target]) revert NotTarget();
        if (assets == 0) return;

        ERC20 base = baseAsset();
        base.safeApprove(target, assets);
        ERC4626(target).deposit(assets, address(this));

        uint256 newAllocation = allocation(target);
        if (newAllocation > absoluteCap[target]) revert AbsoluteCapExceeded();
        if (newAllocation > totalAssets().mulDivDown(relativeCap[target], WAD)) revert RelativeCapExceeded();

        emit Allocated(msg.sender, target, assets);
    }

    function _deallocate(address target, uint256 assets) internal {
        if (!isTarget[target]) revert NotTarget();
        if (assets == 0) return;

        ERC4626(target).withdraw(assets, address(this), address(this));
        emit Deallocated(msg.sender, target, assets);
    }

    /// @dev Pull base asset back from the liquidity target so the vault holds `assets` idle.
    function _ensureIdle(uint256 assets) internal {
        ERC20 base = baseAsset();
        uint256 idle = base.balanceOf(address(this));
        if (idle >= assets) return;

        address target = liquidityTarget;
        if (target == address(0)) return;

        uint256 needed = assets - idle;
        uint256 available = ERC4626(target).maxWithdraw(address(this));
        _deallocate(target, needed < available ? needed : available);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@solmate/tokens/ERC20.sol";
import {ERC4626} from "@solmate/tokens/ERC4626.sol";
import {SafeTransferLib} from "@solmate/utils/SafeTransferLib.sol";
import {IPriceFeed} from "../../src/interfaces/IPriceFeed.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_, decimals_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Stands in for a yield-bearing ERC4626 such as a Morpho vault.
contract MockYieldVault is ERC4626 {
    constructor(ERC20 asset_) ERC4626(asset_, "Mock Yield", "mY") {}

    function totalAssets() public view override returns (uint256) {
        return asset.balanceOf(address(this));
    }

    /// @notice Donate assets to the vault, raising the share price.
    function accrue(uint256 amount) external {
        MockERC20(address(asset)).mint(address(this), amount);
    }
}

contract MockPriceFeed is IPriceFeed {
    uint8 public decimals;
    int256 public answer;
    uint256 public updatedAt;

    constructor(uint8 decimals_, int256 answer_) {
        decimals = decimals_;
        answer = answer_;
        updatedAt = block.timestamp;
    }

    function set(int256 answer_) external {
        answer = answer_;
        updatedAt = block.timestamp;
    }

    function setUpdatedAt(uint256 updatedAt_) external {
        updatedAt = updatedAt_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }

    function getRoundData(uint80) external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

/// @notice Stands in for an issuer's off-chain redemption desk. `pull` takes the RWA, `settle`
/// pays the base asset back some days later.
contract MockRedeemer {
    using SafeTransferLib for ERC20;

    ERC20 public immutable base;
    ERC20 public immutable rwa;

    constructor(ERC20 base_, ERC20 rwa_) {
        base = base_;
        rwa = rwa_;
    }

    function pull(uint256 rwaAmount) external {
        rwa.safeTransferFrom(msg.sender, address(this), rwaAmount);
    }

    function settle(uint256 baseAmount) external {
        MockERC20(address(base)).mint(msg.sender, baseAmount);
    }

    function boom() external pure {
        revert("redeemer failed");
    }
}

/// @notice An RWA that re-enters the vault from inside its own transferFrom.
contract ReentrantRwa is ERC20 {
    address public vault;
    bool public armed;

    constructor() ERC20("Reentrant RWA", "rRWA", 18) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(address vault_) external {
        vault = vault_;
        armed = true;
    }

    bool public reentrySucceeded;
    bytes public reentryError;

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (armed) {
            armed = false;
            (bool ok, bytes memory err) = vault.call(abi.encodeWithSignature("redeemRwa(uint256,uint256)", amount, 0));
            reentrySucceeded = ok;
            reentryError = err;
        }
        return super.transferFrom(from, to, amount);
    }
}

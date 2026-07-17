// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Owned} from "@solmate/auth/Owned.sol";
import {FixedPointMathLib} from "@solmate/utils/FixedPointMathLib.sol";
import {IOracle} from "./interfaces/IOracle.sol";
import {IPriceFeed} from "./interfaces/IPriceFeed.sol";

/// @notice Wraps one Chainlink-style feed quoting the RWA in a vault's base asset. Deployed
/// per vault, so the vault reads it with no arguments.
contract Oracle is IOracle, Owned {
    using FixedPointMathLib for uint256;

    uint256 internal constant WAD = 1e18;

    IPriceFeed public immutable priceFeed;
    uint256 internal immutable feedScale;

    /// @notice Max age of a feed answer before this oracle stops reporting, in seconds.
    uint256 public maxAge;

    event MaxAgeSet(uint256 maxAge);

    error ZeroAddress();
    error InvalidRoundData();
    error StalePrice();

    constructor(address owner_, address priceFeed_, uint256 maxAge_) Owned(owner_) {
        if (owner_ == address(0) || priceFeed_ == address(0)) revert ZeroAddress();
        priceFeed = IPriceFeed(priceFeed_);
        feedScale = 10 ** IPriceFeed(priceFeed_).decimals();
        maxAge = maxAge_;
        emit MaxAgeSet(maxAge_);
    }

    function setMaxAge(uint256 maxAge_) external onlyOwner {
        maxAge = maxAge_;
        emit MaxAgeSet(maxAge_);
    }

    /// @inheritdoc IOracle
    function price() external view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = priceFeed.latestRoundData();
        if (answer <= 0 || updatedAt == 0) revert InvalidRoundData();
        if (block.timestamp - updatedAt > maxAge) revert StalePrice();

        return uint256(answer).mulDivDown(WAD, feedScale);
    }
}

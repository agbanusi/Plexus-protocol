// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IOracle {
    /// @notice Price of one whole RWA denominated in the vault's base asset, scaled by 1e18.
    function price() external view returns (uint256);
}

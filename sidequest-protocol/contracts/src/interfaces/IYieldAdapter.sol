// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IYieldAdapter
/// @notice Pluggable yield-source interface for YieldVault. Real implementations
///         (Morpho, Aave fork, etc.) deposit the underlying and report back
///         the current `totalAssets()` value. The stub implementation just holds
///         the underlying and returns the balance unchanged.
interface IYieldAdapter {
    /// @notice Returns the total underlying currently attributable to this adapter.
    function totalAssets() external view returns (uint256);

    /// @notice Deposits `amount` of underlying into the yield source.
    function deposit(uint256 amount) external;

    /// @notice Withdraws `amount` of underlying from the yield source.
    function withdraw(uint256 amount) external;
}

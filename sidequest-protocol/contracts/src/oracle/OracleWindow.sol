// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title OracleWindow
/// @notice The one invariant that makes per-asset staleness windows work, and
///         the reason getting it backwards is silent rather than loud.
///
///         A consuming vault has its own `maxOracleStaleness`. A `MedianOracle`
///         has its own `maxStaleness`. They are not interchangeable, and their
///         ORDER decides whether the vault works:
///
///         `MedianOracle.latestRoundData` returns the OLDEST contributing
///         timestamp -- deliberately, so an answer is never presented as fresher
///         than its stalest input. A report counts as contributing while it is
///         within the ORACLE's window.
///
///         vault >= oracle   SAFE. Any report older than the oracle's window is
///                           dropped from the fresh set entirely, so it can
///                           never pin `updatedAt` beyond what the vault
///                           tolerates. When every report ages out the oracle
///                           refuses first, with InsufficientFreshReports.
///
///         vault <  oracle   BROKEN, and quietly. Reports living in the gap
///                           still count toward the median AND drag `updatedAt`
///                           older than the vault accepts, so the vault reverts
///                           StaleOracle while a perfectly fresh report sits in
///                           the same oracle, unused.
///
///         The second case is not hypothetical. Measured on testnet 46630, with
///         a 90s vault against the 3600s production oracle, moments after a
///         price was posted:
///
///             gov    age 157s   <- just posted
///             keeper age 541s   <- hosted keeper, its own 900s schedule
///             latestRoundData -> age 541s  => StaleOracle
///
///         Adding updaters -- which is the plan for mainnet, and the whole
///         point of a median -- can only make the reported age worse. So the
///         gap has to be closed by construction rather than by discipline.
///
///         WHY A STATICCALL AND NOT AN INTERFACE
///
///         `AggregatorV3Interface` does not declare `maxStaleness()`, and real
///         Chainlink aggregators do not have it: their heartbeat is a property
///         of the feed's off-chain configuration, not a getter. So this probes,
///         and enforces only when the oracle is one of ours. A Chainlink feed
///         returns `false` and the caller keeps whatever window it was given --
///         the invariant is unenforceable there, which is a fact about
///         Chainlink rather than a reason to skip it for MedianOracle.
library OracleWindow {
    error VaultWindowTighterThanOracle(address oracle, uint256 vaultWindow, uint256 oracleWindow);

    /// @notice Revert if `vaultWindow` is tighter than `oracle`'s own window.
    /// @dev    A no-op for oracles that do not expose `maxStaleness()`.
    function requireNotTighterThan(address oracle, uint256 vaultWindow) internal view {
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok, bytes memory data) = oracle.staticcall(abi.encodeWithSignature("maxStaleness()"));
        if (!ok || data.length != 32) return;

        uint256 oracleWindow = abi.decode(data, (uint256));
        if (vaultWindow < oracleWindow) {
            revert VaultWindowTighterThanOracle(oracle, vaultWindow, oracleWindow);
        }
    }
}

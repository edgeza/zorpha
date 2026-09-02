// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title MainnetSafety
/// @notice Deploy-time refusals for configurations that are survivable on a
///         testnet and catastrophic on mainnet.
///
/// @dev    A library rather than a private function on the deploy script, so a
///         test can exercise the real check instead of a copy of it. That
///         distinction is the whole reason this file exists: the three
///         conditions below were previously guarded by `console2.log` warnings
///         printed at the end of a *successful* deploy, which is a note, not a
///         gate. It arrives after the transactions have landed, buried in a
///         wall of addresses, at the moment attention is lowest.
library MainnetSafety {
    /// @notice Robinhood Chain mainnet. Testnet is 46630.
    uint256 internal constant MAINNET_CHAIN_ID = 4663;

    /// @notice The thinnest oracle set that is both a real median and tolerant
    ///         of one updater being offline.
    /// @dev    Quorum 1 is not a median: one updater sets the price alone, and
    ///         every vault's NAV, slippage bound and rebalance decision follows
    ///         it. Three updaters at quorum 3 is a median but halts on a single
    ///         outage, and a halted oracle blocks rebalances and redemptions.
    ///         So 2-of-3 is the floor.
    uint256 internal constant MIN_UPDATERS = 3;
    uint256 internal constant MIN_QUORUM = 2;

    error StubSwapAdapterOnMainnet();
    error StubYieldAdapterOnMainnet();
    error TooFewOracleUpdaters(uint256 have, uint256 need);
    error OracleQuorumTooLow(uint256 have, uint256 need);

    /// @notice Revert if this configuration must not reach mainnet.
    ///
    /// @dev No-op on any other chain, so testnet drills are unaffected.
    ///
    ///      Deliberately no override parameter. An override would be set once
    ///      during a rehearsal and never unset, which is exactly how the
    ///      printed warnings stopped being read. If a staged launch genuinely
    ///      needs different thresholds, changing the constants above is a
    ///      reviewed diff rather than an environment variable nobody sees.
    ///
    /// @param chainId       the chain being deployed to
    /// @param swapIsReal    false when the 1:1 stub swap adapter is in use.
    ///                      The stub prices 1:1 on RAW UNITS, ignoring both
    ///                      price and decimals; it destroyed every vault it
    ///                      touched on testnet before being fixed.
    /// @param yieldIsReal   false when the stub yield adapter is in use. It
    ///                      holds the deposit and earns nothing, so the vault
    ///                      would take real money into a contract that does not
    ///                      invest it.
    /// @param updaterCount  oracle updaters actually seated
    /// @param minQuorum     the oracle's immutable quorum. It cannot be raised
    ///                      afterwards, so whatever is deployed is what mainnet
    ///                      lives with until the oracle is replaced.
    function check(
        uint256 chainId,
        bool swapIsReal,
        bool yieldIsReal,
        uint256 updaterCount,
        uint256 minQuorum
    ) internal pure {
        if (chainId != MAINNET_CHAIN_ID) return;

        if (!swapIsReal) revert StubSwapAdapterOnMainnet();
        if (!yieldIsReal) revert StubYieldAdapterOnMainnet();
        if (updaterCount < MIN_UPDATERS) revert TooFewOracleUpdaters(updaterCount, MIN_UPDATERS);
        if (minQuorum < MIN_QUORUM) revert OracleQuorumTooLow(minQuorum, MIN_QUORUM);
    }
}

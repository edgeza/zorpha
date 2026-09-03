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

    /// @notice The launch liquidity tranche would be sent somewhere that can
    ///         move it with no delay and no public notice.
    error LiquidityRecipientNotAContract(address recipient);

    /// @notice The launch liquidity tranche would be sent to the deployer.
    error LiquidityRecipientIsDeployer(address recipient);

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

    /// @notice Gate the TOKEN launch on mainnet. Separate from `check` above,
    ///         which gates the vault layer and is called from a different
    ///         script.
    ///
    /// @dev    Why this exists.
    ///
    ///         13% of supply -- 130,000,000 ZOR -- is transferred to
    ///         `LIQUIDITY_RECIPIENT` in a single plain `transfer` during the
    ///         token deploy. The only constraint was `!= address(0)`, so on
    ///         mainnet that tranche could go to an externally owned account and
    ///         be moved anywhere, instantly, by one key.
    ///
    ///         That is not a hypothetical concern about intent. It is a
    ///         published listing criterion: the curation that actually drives
    ///         discovery on this chain looks at "verified contract, locked
    ///         liquidity, sane distribution", and there are no paid listings to
    ///         substitute for it. An unlocked launch tranche fails one of three
    ///         checks that decide whether anybody sees the token at all.
    ///
    ///         Requiring a CONTRACT rather than specifically the Timelock is
    ///         deliberate. A CCA seeds its pool from a contract, a locker is a
    ///         contract, and the Timelock is a contract -- naming one of them
    ///         here would force a redeploy of this library the first time the
    ///         launch plan changed. What is being excluded is the case with no
    ///         accountability at all: a private key holding 13% of supply.
    ///
    ///         `codeLength` is passed in because this is `pure`; the caller
    ///         reads `recipient.code.length`. Keeping it pure means it can be
    ///         unit-tested without deploying anything, which is the whole
    ///         reason these checks live in a library rather than inline in a
    ///         script.
    ///
    /// @param chainId     the chain being deployed to
    /// @param recipient   LIQUIDITY_RECIPIENT, the address receiving 13%
    /// @param codeLength  `recipient.code.length`, read by the caller
    /// @param deployer    the deploying key, which must not be the recipient
    function checkTokenLaunch(
        uint256 chainId,
        address recipient,
        uint256 codeLength,
        address deployer
    ) internal pure {
        if (chainId != MAINNET_CHAIN_ID) return;

        if (recipient == deployer) revert LiquidityRecipientIsDeployer(recipient);
        if (codeLength == 0) revert LiquidityRecipientNotAContract(recipient);
    }
}

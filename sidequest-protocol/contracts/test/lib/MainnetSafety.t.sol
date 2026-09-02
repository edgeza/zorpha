// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {MainnetSafety} from "../../src/lib/MainnetSafety.sol";

/// @notice The deploy-time mainnet refusals.
///
///         `DeployVaultsV1` had no tests at all, and these three conditions were
///         guarded only by `console2.log` warnings printed after a successful
///         deploy. The library exists so these tests exercise the real check
///         rather than a reimplementation of it -- a test that passes against
///         its own copy of the logic proves nothing about the code that ships.
contract MainnetSafetyTest is Test {
    // A thin wrapper, because `internal pure` cannot be called across the
    // `expectRevert` boundary directly.
    function _check(
        uint256 chainId,
        bool swapIsReal,
        bool yieldIsReal,
        uint256 updaterCount,
        uint256 minQuorum
    ) external pure {
        MainnetSafety.check(chainId, swapIsReal, yieldIsReal, updaterCount, minQuorum);
    }

    uint256 constant MAINNET = 4663;
    uint256 constant TESTNET = 46630;

    // ─── The mainnet refusals ───────────────────────────────────────────────

    function test_Mainnet_RejectsStubSwapAdapter() public {
        vm.expectRevert(MainnetSafety.StubSwapAdapterOnMainnet.selector);
        this._check(MAINNET, false, true, 3, 2);
    }

    function test_Mainnet_RejectsStubYieldAdapter() public {
        vm.expectRevert(MainnetSafety.StubYieldAdapterOnMainnet.selector);
        this._check(MAINNET, true, false, 3, 2);
    }

    function test_Mainnet_RejectsTooFewUpdaters() public {
        vm.expectRevert(
            abi.encodeWithSelector(MainnetSafety.TooFewOracleUpdaters.selector, 2, 3)
        );
        this._check(MAINNET, true, true, 2, 2);
    }

    /// The specific configuration testnet is running today: quorum 1 against
    /// two seated updaters. One updater sets the price alone.
    function test_Mainnet_RejectsQuorumOfOne() public {
        vm.expectRevert(abi.encodeWithSelector(MainnetSafety.OracleQuorumTooLow.selector, 1, 2));
        this._check(MAINNET, true, true, 3, 1);
    }

    /// 2-of-3 is the floor and must be accepted, or the gate is unshippable.
    function test_Mainnet_AcceptsTwoOfThree() public view {
        this._check(MAINNET, true, true, 3, 2);
    }

    function test_Mainnet_AcceptsStricterConfigurations() public view {
        this._check(MAINNET, true, true, 5, 3);
    }

    // ─── Everywhere else is untouched ───────────────────────────────────────

    /// The drills run on testnet with the stubs and a quorum of 1. If the gate
    /// fired there it would block every existing workflow, so this pins that it
    /// does not -- the reason the check takes a chain id rather than reading
    /// `block.chainid` itself.
    function test_Testnet_AllowsEverythingTheDrillsUse() public view {
        this._check(TESTNET, false, false, 1, 1);
    }

    function test_LocalAnvil_AllowsEverything() public view {
        this._check(31337, false, false, 1, 1);
    }

    /// A near-miss on the chain id must not silently disable the gate. 4663 is
    /// mainnet; 46630 is testnet and differs by one appended digit, which is
    /// exactly the kind of pair a typo slips between.
    function test_ChainIdIsExact() public {
        vm.expectRevert(MainnetSafety.StubSwapAdapterOnMainnet.selector);
        this._check(4663, false, true, 3, 2);

        // 46630 and 466 must both be treated as not-mainnet.
        this._check(46630, false, true, 3, 2);
        this._check(466, false, true, 3, 2);
    }

    /// Fuzz: no non-mainnet chain may ever revert, whatever the configuration.
    function testFuzz_OnlyMainnetEverReverts(
        uint256 chainId,
        bool swapIsReal,
        bool yieldIsReal,
        uint8 updaters,
        uint8 quorum
    ) public view {
        vm.assume(chainId != MainnetSafety.MAINNET_CHAIN_ID);
        this._check(chainId, swapIsReal, yieldIsReal, updaters, quorum);
    }
}

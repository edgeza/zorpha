// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ReputationRegistry} from "../../src/reputation/ReputationRegistry.sol";
import {ReceiptRenderer} from "../../src/lib/ReceiptRenderer.sol";

contract ReputationRegistryTest is Test {
    ReputationRegistry registry;
    address admin = makeAddr("admin");
    address manager = makeAddr("manager");
    address challenger = makeAddr("challenger");

    uint256 constant T0 = 1_700_000_000;

    function setUp() public {
        vm.warp(T0);
        registry = new ReputationRegistry(admin);
    }

    function test_Publish_StoresCommitmentAndIncrementsNonce() public {
        bytes32 commit = keccak256("first");
        uint256 ws = T0 - 1 days;
        uint256 we = T0;

        vm.expectEmit(true, true, true, true);
        emit ReputationRegistry.StatsPublished(manager, commit, ws, we, 1, T0 + 7 days);

        registry.publish(manager, commit, ws, we);

        assertEq(registry.nonces(manager), 1);
        ReputationRegistry.StatsCommitment memory c = registry.getLatest(manager);
        assertEq(c.commitment, commit);
        assertEq(c.windowStart, ws);
        assertEq(c.windowEnd, we);
        assertEq(c.nonce, 1);
        assertFalse(c.challenged);
        assertEq(registry.getHistoryLength(manager), 1);
    }

    function test_Publish_BadWindow_Reverts() public {
        vm.expectRevert();
        registry.publish(manager, bytes32("x"), 100, 50);
    }

    function test_Publish_ZeroCommitment_Reverts() public {
        vm.expectRevert();
        registry.publish(manager, bytes32(0), T0 - 1, T0);
    }

    /// A challenger who reproduces the published hash has not found a dispute.
    /// Recording that as a positive outcome is what made `upheld` forgeable.
    function test_Challenge_MatchingIsNotADispute() public {
        bytes32 commit = keccak256("y");
        registry.publish(manager, commit, T0 - 1, T0);

        vm.expectRevert(ReputationRegistry.NoDispute.selector);
        registry.challenge(manager, 0, commit);

        ReputationRegistry.StatsCommitment memory c = registry.getLatest(manager);
        assertFalse(c.challenged, "entry must stay open");
        assertFalse(c.upheld, "no free upheld badge");
    }

    /// The specific attack: publish anything, self-challenge with the same hash
    /// to mint "upheld", and thereby block every real challenge.
    function test_ManagerCannotSelfMintUpheld() public {
        bytes32 fabricated = keccak256("stats nobody verified");
        registry.publish(manager, fabricated, T0 - 1, T0);

        vm.prank(manager);
        vm.expectRevert(ReputationRegistry.NoDispute.selector);
        registry.challenge(manager, 0, fabricated);

        // A genuine challenge is still possible afterwards.
        vm.prank(challenger);
        registry.challenge(manager, 0, keccak256("what the receipts actually say"));

        ReputationRegistry.StatsCommitment memory c = registry.getLatest(manager);
        assertTrue(c.challenged, "real dispute recorded");
        assertFalse(c.upheld, "unresolved disputes are not upheld");
        assertEq(registry.challengerOf(manager, 0), challenger);
    }

    /// `upheld` only becomes true when an arbiter says so.
    function test_ResolveChallenge_IsArbiterOnly() public {
        registry.publish(manager, keccak256("y"), T0 - 1, T0);
        vm.prank(challenger);
        registry.challenge(manager, 0, keccak256("wrong"));

        vm.prank(challenger);
        vm.expectRevert();
        registry.resolveChallenge(manager, 0, true);

        vm.expectEmit(true, true, true, true);
        emit ReputationRegistry.StatsUpheld(manager, 0, admin);
        vm.prank(admin);
        registry.resolveChallenge(manager, 0, true);

        assertTrue(registry.getLatest(manager).upheld);
    }

    function test_ResolveChallenge_RequiresAnOpenDispute() public {
        registry.publish(manager, keccak256("y"), T0 - 1, T0);
        vm.prank(admin);
        vm.expectRevert(ReputationRegistry.NotChallenged.selector);
        registry.resolveChallenge(manager, 0, true);
    }

    /// The divergence bug: `challenge` wrote only to history, so `getLatest`
    /// kept reporting a disputed commitment as unchallenged. `getLatest` is now
    /// derived from history and cannot disagree with it.
    function test_Challenge_MismatchIsVisibleThroughGetLatest() public {
        bytes32 commit = keccak256("y");
        registry.publish(manager, commit, T0 - 1, T0);

        vm.expectEmit(true, true, true, true);
        emit ReputationRegistry.StatsChallenged(manager, 0, challenger, keccak256("wrong"));
        vm.prank(challenger);
        registry.challenge(manager, 0, keccak256("wrong"));

        ReputationRegistry.StatsCommitment memory c = registry.getLatest(manager);
        assertTrue(c.challenged, "getLatest must reflect the dispute");
        assertFalse(c.upheld);
        assertEq(registry.getAt(manager, 0).challenged, true, "history agrees");
    }

    function test_DoubleChallengeReverts() public {
        registry.publish(manager, keccak256("y"), T0 - 1, T0);
        vm.prank(challenger);
        registry.challenge(manager, 0, keccak256("wrong"));

        vm.prank(makeAddr("other"));
        vm.expectRevert(ReputationRegistry.AlreadyChallenged.selector);
        registry.challenge(manager, 0, keccak256("also wrong"));
    }

    function test_GetLatestOnUnknownManagerIsZeroed() public {
        ReputationRegistry.StatsCommitment memory c = registry.getLatest(makeAddr("nobody"));
        assertEq(c.commitment, bytes32(0));
        assertEq(c.nonce, 0);
        assertFalse(c.challenged);
    }

    function test_LatestTracksTheNewestPublish() public {
        registry.publish(manager, keccak256("one"), T0 - 1, T0);
        vm.warp(T0 + 1 days);
        registry.publish(manager, keccak256("two"), T0, T0 + 1 days);

        ReputationRegistry.StatsCommitment memory c = registry.getLatest(manager);
        assertEq(c.commitment, keccak256("two"));
        assertEq(c.nonce, 2);
        assertEq(registry.getHistoryLength(manager), 2);
    }

    function test_Challenge_AfterWindow_Reverts() public {
        bytes32 commit = keccak256("y");
        registry.publish(manager, commit, T0 - 1, T0);
        vm.warp(T0 + 8 days);
        vm.expectRevert(ReputationRegistry.ChallengeWindowClosed.selector);
        registry.challenge(manager, 0, keccak256("wrong"));
    }

    function test_ReceiptRenderer_ReputationHash_Stable() public {
        bytes32 h1 = ReceiptRenderer.reputationHash(
            manager, 50, 1500, 800, 200, 100, 200, 1
        );
        bytes32 h2 = ReceiptRenderer.reputationHash(
            manager, 50, 1500, 800, 200, 100, 200, 1
        );
        assertEq(h1, h2, "deterministic");

        bytes32 h3 = ReceiptRenderer.reputationHash(
            manager, 51, 1500, 800, 200, 100, 200, 1
        );
        assertTrue(h1 != h3, "different inputs -> different hash");
    }
}

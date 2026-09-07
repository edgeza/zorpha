// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {VaultLauncher} from "../../src/leadership/VaultLauncher.sol";

/// @notice Replay safe-batches/B-lower-seed-minimum.json as the Safe.
///
/// Batch B lowers the launch escrow floor to 90 USDG. It is NOT the current
/// policy: the floor was deliberately set to 1,000 USDG on 7 September 2026 and
/// that is what the launcher holds. The batch stays because it is a correct,
/// re-runnable artifact, and this test proves it stays correct, so the choice
/// between the two numbers is a decision rather than a piece of work.
///
/// What this asserts is a property of the BATCH, not of the chain's current
/// settings: it moves the escrow floor to 90 USDG and leaves the other four
/// parameters alone. That is what makes it safe to sign. An earlier version of
/// this file also asserted the launcher's live value, which is the wrong shape
/// for a test: a fork test pinning a governance parameter goes red every time
/// governance legitimately changes it, and this one did exactly that within the
/// hour.
///
/// It reads the JSON off disk rather than a copy of the calldata, so it
/// exercises the file that would be signed.
///
/// ON READING THE SAFE QUEUE, since guessing at it caused a wrong diagnosis
/// here. The pending queue is not on chain and `cast` cannot see it, only
/// nonces and past executions. It lives in Safe's hosted Transaction Service:
/// see safe-batches/README.md for the endpoints.
contract SeedMinimumBatchTest is Test {
    address constant SAFE = 0xC75E64Ccf3ce6E2F40939Ab58255681769BcF8C4;
    address constant LAUNCHER = 0x9eD12842A222aeD986E768b3D50aDCf89691159A;

    bool forked;
    function setUp() public {
        string memory url = vm.envOr("RH_MAINNET_RPC_URL", string(""));
        if (bytes(url).length == 0) return;
        vm.createSelectFork(url); forked = true;
    }

    function test_ReplayBatchB_ChangesOnlyTheSeedMinimum() public {
        if (!forked) { vm.skip(true); }
        VaultLauncher l = VaultLauncher(LAUNCHER);

        // Read the batch off disk, so this tests the file that gets signed and
        // not a transcription of it.
        string memory json = vm.readFile("safe-batches/B-lower-seed-minimum.json");
        address to = vm.parseJsonAddress(json, ".transactions[0].to");
        bytes memory data = vm.parseJsonBytes(json, ".transactions[0].data");
        assertEq(to, LAUNCHER, "batch must target the launcher");

        uint256 bondBefore = l.bondAmount();
        uint256 seedBefore = l.minSeedEscrow();
        uint16 covBefore = l.minCoverageBps();
        uint16 feeShareBefore = l.leaderFeeShareBps();
        uint256 perfBefore = l.performanceFeeBps();

        vm.prank(SAFE);
        (bool ok,) = LAUNCHER.call(data);
        assertTrue(ok, "the Safe must still be able to call setParams");

        console2.log("minSeedEscrow before / after", seedBefore, l.minSeedEscrow());

        // 90 USDG whether it started at 1,000 or was already applied. Asserting
        // the destination rather than the transition is what keeps this test
        // meaningful after the batch has run: replaying it is then a no-op, and
        // a no-op is exactly what a re-runnable governance batch should be.
        assertEq(l.minSeedEscrow(), 90_000_000, "seed minimum should land on 90 USDG");
        assertEq(l.bondAmount(), bondBefore, "bond must not move");
        assertEq(l.minCoverageBps(), covBefore, "coverage must not move");
        assertEq(l.leaderFeeShareBps(), feeShareBefore, "leader fee share must not move");
        assertEq(l.performanceFeeBps(), perfBefore, "performance fee must not move");
    }
}

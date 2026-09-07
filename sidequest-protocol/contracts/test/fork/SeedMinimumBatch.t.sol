// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {VaultLauncher} from "../../src/leadership/VaultLauncher.sol";

/// @notice Replay safe-batches/B-lower-seed-minimum.json as the Safe.
///
/// The batch is being run a second time because a stale queued proposal reset
/// minSeedEscrow to the launcher's constructor default on 7 September 2026. Its
/// safety property is that the other four arguments are passed at their current
/// on-chain values, so re-running it changes one field and nothing else. That
/// property is only true as long as those values have not moved since the batch
/// was written, which is exactly what this asserts, from the artifact rather
/// than from a copy of the calldata.
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

    /// Now a regression guard rather than a pre-flight check.
    ///
    /// It read `minSeedEscrow == 1_000_000_000` while the batch was waiting to
    /// be signed, so a stale batch could not be signed on the strength of a
    /// green suite. Batch B then executed at block 56,896,762
    /// (tx 0x2f871e61adfc8fa02c2d1bb6a60fd43c2651b7910fbd772f6422a17edac3d518),
    /// so the useful thing to watch became the opposite: that the value stays.
    ///
    /// THIS TEST IS CURRENTLY RED AGAINST MAINNET, DELIBERATELY.
    ///
    /// Sixteen minutes after batch B landed, a second queued proposal carrying
    /// the launcher's constructor defaults executed at block 56,906,350
    /// (tx 0x9f1c0c53505d511ee24bc2e2c249927566af03dba5686c96bfdf3a75ffaa8839)
    /// and put minSeedEscrow back to 1,000 USDG. That is the second time the
    /// same parameter has been reverted by a proposal older than the work it
    /// undid; the first was at block 56,853,183.
    ///
    /// So this asserts the value the protocol intends, not the value on chain,
    /// and stays red until the Safe queue is cleared of those entries and batch
    /// B is run again. Weakening it to match the current state would delete the
    /// only automated record that this keeps happening.
    ///
    /// It does not gate CI: .github/workflows/contracts.yml sets no fork RPC, so
    /// every test in test/fork skips there. That is a real limitation of this
    /// guard, not a convenience. It bites when someone runs the suite against
    /// mainnet, and nowhere else.
    function test_SeedMinimumIsStillNinetyUSDG() public {
        if (!forked) { vm.skip(true); }
        VaultLauncher l = VaultLauncher(LAUNCHER);
        assertTrue(
            l.hasRole(l.GOVERNANCE_ROLE(), SAFE),
            "the Safe must hold GOVERNANCE_ROLE, or a correction needs the Timelock instead"
        );
        assertEq(
            l.minSeedEscrow(),
            90_000_000,
            "seed minimum is off 90 USDG: check the Safe queue for a stale setParams before re-running batch B"
        );
    }
}

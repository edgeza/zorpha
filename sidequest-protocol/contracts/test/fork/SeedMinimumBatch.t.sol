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

        assertEq(l.minSeedEscrow(), 90_000_000, "seed minimum should land on 90 USDG");
        assertEq(l.bondAmount(), bondBefore, "bond must not move");
        assertEq(l.minCoverageBps(), covBefore, "coverage must not move");
        assertEq(l.leaderFeeShareBps(), feeShareBefore, "leader fee share must not move");
        assertEq(l.performanceFeeBps(), perfBefore, "performance fee must not move");
    }

    /// The batch is pointless if it is already applied, and dangerous to sign
    /// blind if the launcher has drifted. Fails loudly in either case.
    function test_BatchIsStillNeededAndStillSafe() public {
        if (!forked) { vm.skip(true); }
        VaultLauncher l = VaultLauncher(LAUNCHER);
        assertEq(l.minSeedEscrow(), 1_000_000_000, "if this is not 1,000 USDG the batch is stale");
        assertTrue(
            l.hasRole(l.GOVERNANCE_ROLE(), SAFE),
            "the Safe must hold GOVERNANCE_ROLE, or this needs the Timelock instead"
        );
    }
}

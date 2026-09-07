// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SpotVaultMinimal} from "../../src/vaults/SpotVaultMinimal.sol";

/// @notice Executes the SAFE BATCH FILE itself, transaction by transaction, as
///         the Safe, against a mainnet fork.
///
///         The sibling rehearsal in SeedStockVault.t.sol proves the SEQUENCE
///         works by calling the contracts through typed interfaces. That is a
///         reimplementation of the batch, and a reimplementation can agree with
///         itself while the artifact that actually gets signed carries a wrong
///         address, a stale amount or a truncated hex string. This reads
///         J-seed-stock-vault.json off disk and replays exactly what is in it.
contract SeedBatchArtifactTest is Test {
    address constant SAFE = 0xC75E64Ccf3ce6E2F40939Ab58255681769BcF8C4;
    address constant VAULT = 0xB129495f0ad616EdD2f28b3B49470FC1f0FAD413;
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    bool forked;

    function setUp() public {
        string memory url = vm.envOr("RH_MAINNET_RPC_URL", string(""));
        if (bytes(url).length == 0) return;
        vm.createSelectFork(url);
        forked = true;
    }

    function test_TheBatchFileExecutes() public {
        if (!forked) { vm.skip(true); }

        string memory raw = vm.readFile("safe-batches/J-seed-stock-vault.json");
        assertEq(vm.parseJsonString(raw, ".chainId"), "4663", "wrong chain in the batch");

        SpotVaultMinimal vault = SpotVaultMinimal(VAULT);
        uint256 before = vault.rebalanceCount();

        for (uint256 i = 0; i < 5; i++) {
            string memory base = string.concat(".transactions[", vm.toString(i), "]");
            address to = vm.parseJsonAddress(raw, string.concat(base, ".to"));
            bytes memory data = vm.parseJsonBytes(raw, string.concat(base, ".data"));

            vm.prank(SAFE);
            (bool ok, bytes memory ret) = to.call(data);
            if (!ok) {
                console2.log("tx", i + 1, "REVERTED at", to);
                console2.logBytes(ret);
            }
            assertTrue(ok, "a batch transaction reverted");
            console2.log("tx", i + 1, "ok ->", to);
        }

        console2.log("--- end state ---");
        console2.log("rebalanceCount   :", vault.rebalanceCount());
        console2.log("targetWeightBps  :", vault.targetWeightBps());
        console2.log("shares to Safe   :", vault.balanceOf(SAFE));
        console2.log("NVDA leg         :", IERC20(NVDA).balanceOf(VAULT));
        console2.log("USDG leg         :", IERC20(USDG).balanceOf(VAULT));
        console2.log("totalAssets      :", vault.totalAssets());
        console2.log("navPerShare      :", vault.getNavPerShare());
        console2.log("NVDA change kept :", IERC20(NVDA).balanceOf(SAFE));

        assertEq(vault.rebalanceCount(), before + 1, "receipt one was not emitted");
        assertEq(vault.targetWeightBps(), 5000);
        assertGt(vault.balanceOf(SAFE), 0, "the Safe holds no shares");
        assertGt(IERC20(NVDA).balanceOf(VAULT), 0, "no asset leg");
        assertGt(IERC20(USDG).balanceOf(VAULT), 0, "no cash leg");
    }
}

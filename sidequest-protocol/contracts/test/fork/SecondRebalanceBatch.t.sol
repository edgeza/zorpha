// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SpotVaultMinimal} from "../../src/vaults/SpotVaultMinimal.sol";

/// @notice Replays batch L's own JSON as the Safe against the live vault.
///
///         The assertion that matters is the direction. Receipt one sold NVDA
///         for USDG, so only the asset-to-cash leg of the swap adapter has run
///         on mainnet. This buys, and the check is that the NVDA balance rises
///         and the cash leg is spent, not merely that a receipt appeared.
contract SecondRebalanceBatchTest is Test {
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

    function test_BatchLBuysAndEmitsAReceipt() public {
        if (!forked) { vm.skip(true); }

        string memory raw = vm.readFile("safe-batches/L-second-rebalance.json");
        assertEq(vm.parseJsonString(raw, ".chainId"), "4663");

        SpotVaultMinimal vault = SpotVaultMinimal(VAULT);
        uint256 receiptsBefore = vault.rebalanceCount();
        uint256 nvdaBefore = IERC20(NVDA).balanceOf(VAULT);
        uint256 usdgBefore = IERC20(USDG).balanceOf(VAULT);
        uint256 navBefore = vault.getNavPerShare();

        assertEq(vault.targetWeightBps(), 5000, "precondition: the vault sits at 50%");
        assertGt(usdgBefore, 0, "precondition: there is a cash leg to spend");

        address to = vm.parseJsonAddress(raw, ".transactions[0].to");
        bytes memory data = vm.parseJsonBytes(raw, ".transactions[0].data");
        vm.prank(SAFE);
        (bool ok, ) = to.call(data);
        assertTrue(ok, "the batch transaction reverted");

        uint256 nvdaAfter = IERC20(NVDA).balanceOf(VAULT);
        uint256 usdgAfter = IERC20(USDG).balanceOf(VAULT);

        console2.log("NVDA leg   before / after :", nvdaBefore, nvdaAfter);
        console2.log("USDG leg   before / after :", usdgBefore, usdgAfter);
        console2.log("navPerShare before / after:", navBefore, vault.getNavPerShare());
        console2.log("receipts                  :", vault.rebalanceCount());

        assertEq(vault.rebalanceCount(), receiptsBefore + 1, "no receipt emitted");
        assertEq(vault.targetWeightBps(), 10000);

        // The direction. This is the leg mainnet has never run.
        assertGt(nvdaAfter, nvdaBefore, "NVDA did not increase, so this did not buy");
        assertLt(usdgAfter, usdgBefore, "the cash leg was not spent");

        // Value survives, minus one swap's fee and slippage inside the 1% cap.
        assertApproxEqRel(vault.getNavPerShare(), navBefore, 1e16, "lost more than 1% of NAV");
    }
}

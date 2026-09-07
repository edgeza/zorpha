// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SpotVaultMinimal} from "../../src/vaults/SpotVaultMinimal.sol";

/// @notice What batch L actually left behind, measured against the live vault.
///
/// Receipt 2 executed `rebalanceTo(10000)` at block 56,864,010. The batch was
/// justified on the grounds that it restores withdrawals, so the claim is worth
/// checking against the chain rather than against the fork run that predicted
/// it, which said the full exit would clear and was wrong.
///
/// Measured 7 September 2026:
///
///     redeem  10% .. 90%   all clear
///     redeem 100%          reverts, ERC20InsufficientBalance
///     largest exit         55,399,995,696,251,520,585,413 shares
///     of supply            55,400,000,000,000,000,000,000
///     stranded             4,303,748,479,414,587 shares, 0 bps
///
/// The deterministic reproduction lives in test/vaults/WithdrawShortfall.t.sol.
/// This exists to keep the live figure honest, so it asserts the shape of the
/// result and prints the numbers rather than pinning values that move with the
/// vault.
contract ExitAfterBatchLTest is Test {
    address constant SAFE = 0xC75E64Ccf3ce6E2F40939Ab58255681769BcF8C4;
    address constant VAULT = 0xB129495f0ad616EdD2f28b3B49470FC1f0FAD413;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    bool forked;
    function setUp() public {
        string memory url = vm.envOr("RH_MAINNET_RPC_URL", string(""));
        if (bytes(url).length == 0) return;
        vm.createSelectFork(url); forked = true;
    }

    function test_MostOfTheVaultExitsAndOnlyDustIsStranded() public {
        if (!forked) { vm.skip(true); }
        SpotVaultMinimal v = SpotVaultMinimal(VAULT);

        // Preconditions. Skip rather than fail if the vault has moved on, so a
        // later rebalance does not leave a red test that says nothing.
        if (v.rebalanceCount() < 2) { vm.skip(true); }
        if (IERC20(USDG).balanceOf(VAULT) != 1) { vm.skip(true); }

        uint256 shares = v.balanceOf(SAFE);

        // Everything short of the whole position comes out.
        for (uint256 pct = 10; pct <= 90; pct += 10) {
            uint256 snap = vm.snapshotState();
            vm.prank(SAFE);
            v.redeem((shares * pct) / 100, SAFE, SAFE);
            vm.revertToState(snap);
        }

        // The whole position does not, and it is the dust round-trip that stops
        // it: the shortfall a full exit leaves is the cash leg's asset value,
        // and converting that back is zero, so nothing is bought.
        assertEq(
            v.previewRedeem(shares) - IERC20(v.asset()).balanceOf(VAULT),
            v.cashToAsset(1),
            "the shortfall is exactly the dust's asset value"
        );
        assertEq(v.assetToCash(v.cashToAsset(1)), 0, "and the dust cannot be converted back");

        uint256 snapFull = vm.snapshotState();
        vm.prank(SAFE);
        (bool ok,) = address(VAULT).call(abi.encodeCall(v.redeem, (shares, SAFE, SAFE)));
        vm.revertToState(snapFull);
        assertFalse(ok, "a full exit still reverts; batch L did not make it clear");

        // And what that costs, to the wei.
        uint256 lo = 0;
        uint256 hi = shares;
        while (lo < hi) {
            uint256 mid = lo + (hi - lo + 1) / 2;
            uint256 snap = vm.snapshotState();
            vm.prank(SAFE);
            (bool fine,) = address(VAULT).call(abi.encodeCall(v.redeem, (mid, SAFE, SAFE)));
            vm.revertToState(snap);
            if (fine) lo = mid; else hi = mid - 1;
        }

        uint256 stranded = shares - lo;
        assertEq((stranded * 10000) / shares, 0, "stranded must be under a basis point of supply");

        console2.log("cashToAsset(1)  ", v.cashToAsset(1));
        console2.log("largest exit    ", lo);
        console2.log("of supply       ", shares);
        console2.log("stranded shares ", stranded);
    }
}

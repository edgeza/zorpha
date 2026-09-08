// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SpotVaultMinimal} from "../../src/vaults/SpotVaultMinimal.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockOracle} from "../mocks/MockOracle.sol";
import {SlippingSpotAdapter} from "../mocks/SlippingSpotAdapter.sol";

/// @notice The withdrawal path delivers what it advertises, and these tests are
///         what keep it that way.
///
/// This file was written the other way round. Until the exit paths were fixed, a
/// withdrawal needing the cash leg converted back reverted, and the vault was
/// exitable only as far as its asset leg reached; these tests asserted that the
/// defect existed. They now assert it stays gone. Everything below is the
/// original analysis, kept because WHY the defect hid for so long is the part
/// worth remembering.
///
/// WHY IT WAS NOT COVERED BY test/vaults/SpotVaultMinimal.t.sol
///
/// Two things there hid it, and both were properties of the harness rather than
/// of the vault:
///
///   1. `MockSpotAdapter` fills at the oracle price exactly. `_withdraw` used to
///      round the shortfall DOWN into cash units and then allow the fill to come
///      back up to `maxSlippageBps` short, so exposing it needed a venue that
///      actually charges. `SlippingSpotAdapter` is used here, at the 0.05% the
///      live NVDA/USDG pool charges.
///
///   2. That suite pairs an 8-decimal asset with 6-decimal cash. One cash unit
///      is 100 asset units, so rounding the conversion down loses ~100 wei and
///      `previewRedeem`'s own truncation absorbs it. The live stock vault pairs
///      an 18-decimal asset with 6-decimal cash: one USDG unit is 4.3e9 NVDA
///      wei, so the same rounding loses billions of wei and nothing absorbs it.
///
/// The decimal gap is the whole mechanism, so this test reproduces it: 18dp
/// asset, 6dp cash, fee-charging venue.
///
/// MEASURED ON MAINNET BEFORE THE FIX, vault 0xB129495f0ad616EdD2f28b3B49470FC1f0FAD413 at a
/// 50/50 position, forked 7 September 2026:
///
///     redeem  40%  ok
///     redeem  50%  ERC20InsufficientBalance(vault, 27710798703467998,
///                                                  27710807884585675)
///
/// a gap of 9,181,117,677 wei -- 2.13 USDG units of granularity, on a leg of
/// 0.0277 NVDA. The swap ran and bought asset; it simply bought slightly less
/// than the transfer that followed demanded.
contract WithdrawShortfallTest is Test {
    MockERC20 stock;   // 18dp, like the tokenised equities on 4663
    MockERC20 cash;    // 6dp, like USDG
    MockOracle oracle;
    SlippingSpotAdapter venue;
    SpotVaultMinimal vault;

    address alice = makeAddr("alice");
    address keeper = makeAddr("keeper");

    int256 constant PRICE = 232 * 1e8;   // ~NVDA
    uint256 constant DEPOSIT = 100e18;

    function setUp() public {
        vm.warp(1_700_000_000);
        stock = new MockERC20("Tokenised NVDA", "NVDA", 18);
        cash = new MockERC20("Global Dollar", "USDG", 6);
        oracle = new MockOracle(PRICE, 8);
        venue = new SlippingSpotAdapter(address(stock), address(cash), address(oracle));
        venue.setFee(5); // 0.05%, the live pool's tier

        vault = new SpotVaultMinimal(
            address(stock), address(cash), address(oracle), 1 hours,
            "Zorpha NVDA Vault", "zqNVDA",
            0, 100, 0,
            address(this), address(this),
            1 hours
        );
        vault.setSwapAdapter(address(venue));
        vault.grantRole(vault.KEEPER_ROLE(), keeper);

        stock.mint(address(venue), 1_000_000e18);
        cash.mint(address(venue), 1_000_000_000e6);
        stock.mint(alice, DEPOSIT);

        vm.startPrank(alice);
        stock.approve(address(vault), DEPOSIT);
        vault.deposit(DEPOSIT, alice);
        vm.stopPrank();

        // Half into cash, which is the state the live vault was left in by
        // receipt one.
        vm.prank(keeper);
        vault.rebalanceTo(5000);
    }

    /// A withdrawal that needs the cash leg converted must be delivered in
    /// full. The venue's cut comes out of the cash leg, not out of the
    /// depositor's payment.
    ///
    /// WHY 70% AND NOT HALF. An exact-half redeem does NOT enter the shortfall
    /// branch, so a test built on it passes with or without this fix and proves
    /// nothing. After rebalanceTo(5000) the asset leg is 50e18 while
    /// totalAssets is 99.975e18, because the rebalance paid the venue fee out
    /// of the position: half of NAV is therefore LESS than half of the original
    /// position, and the asset leg covers it outright. Measured against this
    /// fixture, pre-fix against post-fix:
    ///
    ///     45%, 50%      pass / pass    no conversion needed
    ///     55% .. 80%    FAIL / pass    conversion needed
    ///
    /// 70% sits well inside the band at both ends.
    function test_SeventyPercentExit_ConvertsAndDeliversInFull() public {
        uint256 shares = vault.balanceOf(alice);
        uint256 want = (shares * 70) / 100;
        uint256 owed = vault.previewRedeem(want);

        // Confirm the test is not vacuous: this exit MUST need a conversion.
        assertGt(owed, stock.balanceOf(address(vault)), "test must exercise the shortfall branch");

        uint256 before = stock.balanceOf(alice);
        vm.prank(alice);
        uint256 got = vault.redeem(want, alice, alice);

        assertEq(got, owed, "redeem must return what previewRedeem promised");
        assertEq(stock.balanceOf(alice) - before, owed, "and actually transfer it");
    }

    /// A full exit now succeeds through the standard path, typed refusal and
    /// all removed. It used to be refused here IN ADVANCE, with the typed
    /// ERC-4626 error rather than a raw ERC-20 revert, because the withdrawer
    /// was being paid the WHOLE oracle NAV of their shares -- including the
    /// venue's cut for converting the last of the cash leg, which the pool
    /// would have had to fund on the exiter's behalf. Superseded: the exiting
    /// holder now pays for their own conversion (previewRedeem, previewWithdraw),
    /// so nothing is left for the pool to fund and nothing stops a full exit.
    /// See docs/design/stock-vault-exit-paths.md, "Who bears the conversion
    /// cost, settled".
    function test_FullRedeem_NowSucceedsInFull() public {
        uint256 shares = vault.balanceOf(alice);
        uint256 mr = vault.maxRedeem(alice);
        assertEq(mr, shares, "capacity is 100% of the holding at every position");

        uint256 before = stock.balanceOf(alice);
        vm.prank(alice);
        uint256 got = vault.redeem(shares, alice, alice);

        assertEq(vault.balanceOf(alice), 0, "the whole holding must be gone");
        assertEq(stock.balanceOf(alice) - before, got, "and delivered in full");
    }

    /// The cliff is gone, and so is the shortfall that used to sit just below
    /// 100%. The advertised ceiling at a 50/50 position used to be nearly the
    /// whole holding but not quite -- 99.5%, because the missing half percent
    /// was the venue's cut for converting the cash leg, charged to the pool
    /// rather than to the exiter. Superseded: the exiting holder now pays their
    /// own conversion cost, so the pool owes nothing extra and the advertised
    /// ceiling is the whole holding, exactly.
    function test_NoCliff_AdvertisedCapacityIsTheWholeHolding() public {
        uint256 shares = vault.balanceOf(alice);
        uint256 mr = vault.maxRedeem(alice);

        assertEq(mr, shares, "capacity is 100% of the holding at a 50/50 position");

        for (uint256 pct = 10; pct <= 100; pct += 10) {
            uint256 want = (mr * pct) / 100;
            if (want == 0) continue;
            uint256 snap = vm.snapshotState();
            vm.prank(alice);
            vault.redeem(want, alice, alice);
            vm.revertToState(snap);
        }
    }

    /// The mitigation batch L applies, in the case where it fully works: with
    /// the position all in the asset AND the cash leg landing on zero, no
    /// withdrawal needs a conversion, so every size clears.
    ///
    /// Landing on zero is where this harness happens to end up. Mainnet landed
    /// on one unit, which is a different case, tested below. The original
    /// version of this test was named IsExitableAtEverySize and was read as a
    /// general guarantee about batch L; it is not one.
    function test_FullyLongVault_CashLegZero_IsExitableAtEverySize() public {
        vm.prank(keeper);
        vault.rebalanceTo(10000);
        assertEq(cash.balanceOf(address(vault)), 0, "this case is specifically the zero cash leg");

        uint256 shares = vault.balanceOf(alice);
        for (uint256 pct = 10; pct <= 100; pct += 10) {
            uint256 snap = vm.snapshotState();
            vm.prank(alice);
            vault.redeem((shares * pct) / 100, alice, alice);
            vm.revertToState(snap);
        }
    }

    /// The dust case, which used to strand the whole exit. One unit of a
    /// 6-decimal cash asset is billions of wei of an 18-decimal one, and
    /// converting it back rounded to nothing, so `_withdraw` swapped zero and
    /// the transfer came up short. Now the bound accounts for it in advance and
    /// everything the vault advertises is delivered.
    function test_FullyLongVault_OneUnitOfDust_AdvertisesAndDelivers() public {
        vm.prank(keeper);
        vault.rebalanceTo(10000);
        cash.mint(address(vault), 1);

        uint256 mr = vault.maxRedeem(alice);
        assertGt(mr, 0, "one unit of dust must not close the vault");

        uint256 before = stock.balanceOf(alice);
        vm.prank(alice);
        uint256 got = vault.redeem(mr, alice, alice);
        assertEq(stock.balanceOf(alice) - before, got, "delivered in full");
    }

    /// Nothing is stranded any more, not even the dust. Binary search for the
    /// largest exit that clears, the same way the live vault was measured
    /// before this fix: back then the search found a real, if tiny, cliff
    /// short of the full holding, because `_withdraw` was being asked to
    /// cover the FULL oracle NAV of the redeemed shares and the last unit of
    /// cash could not convert cleanly at that exact boundary. `previewRedeem`
    /// now charges the exiting holder their own conversion cost, so the
    /// shortfall `_withdraw` is actually asked to cover is smaller by exactly
    /// that cost -- and the search finds the largest clearing exit IS the
    /// whole holding.
    function test_FullyLongVault_OneUnitOfDust_NothingIsStranded() public {
        vm.prank(keeper);
        vault.rebalanceTo(10000);
        cash.mint(address(vault), 1);

        uint256 shares = vault.balanceOf(alice);
        uint256 lo = 0;
        uint256 hi = shares;
        while (lo < hi) {
            uint256 mid = lo + (hi - lo + 1) / 2;
            uint256 snap = vm.snapshotState();
            vm.prank(alice);
            (bool ok,) = address(vault).call(abi.encodeCall(vault.redeem, (mid, alice, alice)));
            vm.revertToState(snap);
            if (ok) lo = mid; else hi = mid - 1;
        }

        uint256 stranded = shares - lo;
        assertEq(stranded, 0, "the largest clearing exit must be the whole holding");
        console2.log("largest exit", lo);
        console2.log("stranded    ", stranded);
    }

    /// Not something a tighter slippage bound fixes. A vault built with zero
    /// tolerance cannot even reach the broken state: `rebalanceTo` requires the
    /// venue to fill at the oracle price exactly, and a venue that charges for
    /// liquidity refuses. So the two settings fail in opposite directions --
    /// tolerance lets the withdrawal swap come back short of what the transfer
    /// demands, and no tolerance stops the vault trading at all. Redeploying
    /// with different bps is not the fix; line 350 is.
    function test_ZeroSlippageBound_CannotEvenRebalance() public {
        SpotVaultMinimal tight = new SpotVaultMinimal(
            address(stock), address(cash), address(oracle), 1 hours,
            "Zorpha NVDA Vault", "zqNVDA",
            0, 0, 0,
            address(this), address(this),
            1 hours
        );
        tight.setSwapAdapter(address(venue));
        tight.grantRole(tight.KEEPER_ROLE(), keeper);

        stock.mint(alice, DEPOSIT);
        vm.startPrank(alice);
        stock.approve(address(tight), DEPOSIT);
        tight.deposit(DEPOSIT, alice);
        vm.stopPrank();

        vm.prank(keeper);
        vm.expectRevert("venue: slippage");
        tight.rebalanceTo(5000);
    }
}

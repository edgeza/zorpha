// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SpotVaultMinimal} from "../../src/vaults/SpotVaultMinimal.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockOracle} from "../mocks/MockOracle.sol";
import {SlippingSpotAdapter} from "../mocks/SlippingSpotAdapter.sol";

/// @notice A withdrawal that needs the cash leg converted back reverts, and the
///         vault is therefore exitable only up to its asset leg.
///
/// WHY THIS IS NOT COVERED BY test/vaults/SpotVaultMinimal.t.sol
///
/// Two things there hide it, and both are properties of the harness rather than
/// of the vault:
///
///   1. `MockSpotAdapter` fills at the oracle price exactly. `_withdraw` rounds
///      the shortfall DOWN into cash units and then allows the fill to come
///      back up to `maxSlippageBps` short, so it needs a venue that actually
///      charges to under-deliver. `SlippingSpotAdapter` is used here, at the
///      0.05% the live NVDA/USDG pool charges.
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
/// MEASURED ON MAINNET, vault 0xB129495f0ad616EdD2f28b3B49470FC1f0FAD413 at a
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

    /// A full exit still cannot happen through the standard path, because the
    /// last of the cash leg cannot be converted for free. What changed is that
    /// the vault now says so in advance and refuses in a typed, standard way,
    /// instead of advertising the shares and failing inside an ERC-20 transfer.
    function test_FullRedeem_IsRefusedInAdvanceAndTyped() public {
        uint256 shares = vault.balanceOf(alice);
        uint256 mr = vault.maxRedeem(alice);
        assertLt(mr, shares, "a vault holding cash cannot promise a full exit");

        vm.prank(alice);
        (bool ok, bytes memory err) = address(vault).call(
            abi.encodeCall(vault.redeem, (shares, alice, alice))
        );
        assertFalse(ok, "the over-large request must be refused");
        // ERC4626ExceededMaxRedeem(address,uint256,uint256)
        assertEq(
            bytes4(err),
            ERC4626.ERC4626ExceededMaxRedeem.selector,
            "refusal must be the typed ERC-4626 error"
        );

        // And the advertised amount goes through.
        vm.prank(alice);
        vault.redeem(mr, alice, alice);
    }

    /// The cliff is gone. It used to sit exactly where the asset leg ran out,
    /// which on a 50/50 position meant half the vault was unreachable. Now
    /// every advertised size clears and the advertised size is nearly all of
    /// the holding.
    function test_NoCliff_AdvertisedCapacityIsNearlyTheWholeHolding() public {
        uint256 shares = vault.balanceOf(alice);
        uint256 mr = vault.maxRedeem(alice);

        // 99.5% at a 50/50 position: the missing half percent is the venue's
        // cut for converting the cash leg, which is real money.
        assertGe((mr * 10000) / shares, 9900, "capacity should be within 1% of the holding");

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

    /// How much is actually stranded, to the wei, so "cannot fully exit" is not
    /// mistaken for "cannot exit". Binary search for the largest exit that
    /// clears, the same way the live vault was measured.
    function test_FullyLongVault_OneUnitOfDust_StrandsOnlyDust() public {
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
        assertGt(stranded, 0, "something must be stranded, or there is no bug here");
        // Under one basis point of supply. The live vault measured 0 bps.
        assertLt((stranded * 10000) / shares, 1, "stranded should be dust, not a real position");
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

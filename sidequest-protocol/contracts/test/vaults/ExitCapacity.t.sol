// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {SpotVaultMinimal} from "../../src/vaults/SpotVaultMinimal.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockOracle} from "../mocks/MockOracle.sol";
import {SlippingSpotAdapter} from "../mocks/SlippingSpotAdapter.sol";

/// @notice Whatever the vault advertises as withdrawable must actually execute.
///
/// The pairing is 18dp asset against 6dp cash, through a venue that charges
/// 5bps, because that is the live NVDA/USDG configuration and the decimal gap
/// is what makes the rounding matter. The suite's other spot vault fixture
/// pairs 8dp with 6dp through a perfect-fill venue, where neither the venue
/// cost nor the rounding can appear.
contract ExitCapacityTest is Test {
    MockERC20 stock;
    MockERC20 cash;
    MockOracle oracle;
    SlippingSpotAdapter venue;
    SpotVaultMinimal vault;

    address alice = makeAddr("alice");
    address keeper = makeAddr("keeper");

    uint256 constant DEPOSIT = 100e18;

    function setUp() public {
        vm.warp(1_700_000_000);
        stock = new MockERC20("Tokenised NVDA", "NVDA", 18);
        cash = new MockERC20("Global Dollar", "USDG", 6);
        oracle = new MockOracle(232 * 1e8, 8);
        venue = new SlippingSpotAdapter(address(stock), address(cash), address(oracle));
        venue.setFee(5);

        vault = new SpotVaultMinimal(
            address(stock), address(cash), address(oracle), 1 hours,
            "Zorpha NVDA Long/Flat", "zqNVDA",
            0, 100, 0,
            address(this), address(this),
            0
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
    }

    /// The headline property: the advertised maximum executes, at every
    /// position a long/flat manager can choose.
    function test_AdvertisedMaximumExecutesAtEveryPosition() public {
        uint16[5] memory targets = [uint16(10000), 7500, 5000, 2500, 0];
        for (uint256 i = 0; i < targets.length; i++) {
            uint256 snap = vm.snapshotState();
            vm.prank(keeper);
            vault.rebalanceTo(targets[i]);

            uint256 held = vault.balanceOf(alice);
            uint256 mr = vault.maxRedeem(alice);
            assertLe(mr, held, "cannot advertise more shares than are held");
            assertGt(mr, 0, "a solvent vault must advertise some capacity");

            vm.prank(alice);
            vault.redeem(mr, alice, alice);

            console2.log("target", targets[i]);
            console2.log("   capacity bps", (mr * 10000) / held);
            vm.revertToState(snap);
        }
    }

    /// The gross-up in `_withdraw` must be the INVERSE of the haircut
    /// `_deliverableAssets` applies to the cash leg -- `10000/(10000-h)`, not
    /// `(10000+h)/10000`. The two agree to first order and only diverge once
    /// the venue's real cost gets close to `h`, so a fixed venue fee never
    /// catches this; the fee itself has to sweep up toward the bound.
    ///
    /// Held at a 50/50 position (h = maxSlippageBps = 100 here), the wrong
    /// formula clears every fill up to 99bps and reverts at exactly 100bps:
    /// the breakeven is 10000h/(10000+h) = 99.0099bps, so 99 rounds down to
    /// "still clears" and 100 is the first integer past it.
    function test_MaxRedeemExecutesAsVenueFeeApproachesMaxSlippage() public {
        vm.prank(keeper);
        vault.rebalanceTo(5000);

        uint256[5] memory venueFeesBps = [uint256(96), 97, 98, 99, 100];
        for (uint256 i = 0; i < venueFeesBps.length; i++) {
            uint256 snap = vm.snapshotState();
            venue.setFee(venueFeesBps[i]);

            uint256 mr = vault.maxRedeem(alice);
            assertGt(mr, 0, "a solvent vault must advertise some capacity");

            vm.prank(alice);
            vault.redeem(mr, alice, alice);

            console2.log("venue fee bps", venueFeesBps[i]);
            vm.revertToState(snap);
        }
    }

    /// A vault holding no cash at all must be fully redeemable. This is the
    /// virtual-share offset trap: deriving the bound by conversion alone comes
    /// out 501 wei short of the supply and refuses this exit.
    ///
    /// THE ROUND TRIP THROUGH 50/50 IS WHAT MAKES THIS TEST BITE. Going
    /// straight to 10000 from a fully long vault is a no-op: no venue fee is
    /// paid, totalAssets stays exactly equal to the deposit, totalSupply is
    /// exactly totalAssets * 1e6, and previewRedeem agrees with
    /// _convertToShares to the wei, so the short-circuit in maxRedeem could be
    /// deleted with this test still green. Paying the venue twice breaks that
    /// exact relationship and the gap appears. Measured:
    ///
    ///     straight to 10000:   totalAssets 100.000000000e18  gap   0
    ///     via 5000:            totalAssets  99.950012500e18  gap 501
    function test_ZeroCashLeg_IsFullyRedeemable() public {
        // Pay the venue, so totalSupply is no longer an exact multiple of
        // totalAssets and the virtual-share gap can exist.
        vm.prank(keeper);
        vault.rebalanceTo(5000);
        vm.prank(keeper);
        vault.rebalanceTo(10000);
        assertEq(cash.balanceOf(address(vault)), 0, "fixture must reach a zero cash leg");

        // Guard against this test going vacuous: the exact-case short-circuit is
        // only load-bearing while conversion alone would come out short.
        uint256 held = vault.balanceOf(alice);
        assertLt(
            _convertToSharesFloor(),
            held,
            "conversion alone must fall short here, or the short-circuit is untested"
        );

        assertEq(vault.maxRedeem(alice), held, "a zero-cash vault must be fully redeemable");
        vm.prank(alice);
        vault.redeem(held, alice, alice);
        assertEq(vault.balanceOf(alice), 0, "and the exit must complete");
    }

    /// What maxRedeem would return WITHOUT its exact-case short-circuit, so the
    /// test above can assert the short-circuit is doing something. Mirrors
    /// `_convertToShares(deliverable, Floor)` using only public views.
    function _convertToSharesFloor() internal view returns (uint256) {
        // deliverable == the asset leg when the cash leg is zero
        uint256 deliverable = stock.balanceOf(address(vault));
        return vault.convertToShares(deliverable);
    }

    /// maxWithdraw must agree with maxRedeem about reality.
    function test_MaxWithdrawExecutes() public {
        vm.prank(keeper);
        vault.rebalanceTo(5000);
        uint256 mw = vault.maxWithdraw(alice);
        assertGt(mw, 0, "a solvent vault must advertise some capacity");
        vm.prank(alice);
        vault.withdraw(mw, alice, alice);
    }

    /// `withdraw` calls `_evaluateFees()` before OpenZeppelin re-reads
    /// `maxWithdraw` to check the caller's request against it, so a fee that
    /// accrues in between shrinks totalAssets() out from under the very bound
    /// a caller just read. The live vault runs a 1000bps performance fee
    /// (script/DeployStockVault.s.sol); every fixture in this file and in
    /// ExitInvariants.t.sol runs zero, which is how this survived: netting
    /// nothing against a fee that is always zero is indistinguishable from
    /// netting correctly.
    ///
    /// Two holders, a 50/50 position, and a price drop from 232 to 200: the
    /// cash leg re-prices to more NVDA than before, so NAV climbs past the
    /// high-water mark and a fee is pending the instant `withdraw` calls
    /// `_evaluateFees()`. maxRedeem is untouched by this -- accrual only
    /// relaxes both of its branches -- so this is maxWithdraw-specific.
    function test_MaxWithdrawExecutesUnderPendingPerformanceFee() public {
        MockOracle feeOracle = new MockOracle(232 * 1e8, 8);
        SlippingSpotAdapter feeVenue = new SlippingSpotAdapter(address(stock), address(cash), address(feeOracle));
        feeVenue.setFee(5);

        SpotVaultMinimal feeVault = new SpotVaultMinimal(
            address(stock), address(cash), address(feeOracle), 1 hours,
            "Zorpha NVDA Long/Flat", "zqNVDA",
            0, 100, 1000, // performanceFeeBps: the live figure, not the fixture's zero
            address(this), address(this),
            0
        );
        feeVault.setSwapAdapter(address(feeVenue));
        feeVault.grantRole(feeVault.KEEPER_ROLE(), keeper);

        stock.mint(address(feeVenue), 1_000_000e18);
        cash.mint(address(feeVenue), 1_000_000_000e6);

        address bob = makeAddr("bob");
        stock.mint(alice, DEPOSIT);
        stock.mint(bob, DEPOSIT);

        vm.startPrank(alice);
        stock.approve(address(feeVault), DEPOSIT);
        feeVault.deposit(DEPOSIT, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        stock.approve(address(feeVault), DEPOSIT);
        feeVault.deposit(DEPOSIT, bob);
        vm.stopPrank();

        vm.prank(keeper);
        feeVault.rebalanceTo(5000);

        feeOracle.setPrice(200 * 1e8);

        uint256 mw = feeVault.maxWithdraw(alice);
        assertGt(mw, 0, "a solvent vault must advertise some capacity");
        vm.prank(alice);
        feeVault.withdraw(mw, alice, alice);
    }

    /// An integrator must be able to ask whether the vault is open, even when
    /// the oracle is refusing. Both of these reach totalAssets() today and
    /// revert rather than answering.
    function test_DepositMaximumsAnswerWhenTheOracleRefuses() public {
        vm.prank(keeper);
        vault.rebalanceTo(5000);
        oracle.setRevertOnRead(true);

        assertEq(vault.maxDeposit(alice), 0, "closed, not unanswerable");
        assertEq(vault.maxMint(alice), 0, "closed, not unanswerable");
        assertEq(vault.maxRedeem(alice), 0, "and the same for the exit side");
        assertEq(vault.maxWithdraw(alice), 0, "and the same for the exit side");
    }

    /// A breaker must not remove the one exit that cannot misprice. It exists
    /// to suspend the paths that can.
    function test_BreakerSuspendsTheStandardPathButNotTheInKindOne() public {
        vault.grantRole(vault.RISK_COUNCIL_ROLE(), address(this));
        vm.prank(keeper);
        vault.rebalanceTo(5000);
        vault.setCircuitBreaker(true);

        assertEq(vault.maxRedeem(alice), 0, "standard path must be shut");
        assertEq(vault.maxDeposit(alice), 0, "deposits must be shut");

        uint256 held = vault.balanceOf(alice);
        uint256 stockBefore = stock.balanceOf(alice);
        uint256 cashBefore = cash.balanceOf(alice);

        vm.prank(alice);
        vault.redeemEmergency(held, alice, alice);

        assertEq(vault.balanceOf(alice), 0, "the in-kind exit must still work");
        assertGt(stock.balanceOf(alice) - stockBefore, 0, "paid the asset leg");
        assertGt(cash.balanceOf(alice) - cashBefore, 0, "and the cash leg, in kind");
    }

    /// The lockout case. When the oracle refuses, the standard path must close
    /// itself rather than advertise shares it cannot pay, and the in-kind path
    /// must still work, because it reads no oracle.
    function test_RefusingOracle_ClosesTheStandardPathAndLeavesTheInKindOne() public {
        vm.prank(keeper);
        vault.rebalanceTo(5000);
        oracle.setRevertOnRead(true);

        assertEq(vault.maxRedeem(alice), 0, "must not advertise a path that reverts");
        assertEq(vault.maxWithdraw(alice), 0, "same");

        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        (bool ok,) = address(vault).call(abi.encodeCall(vault.redeem, (shares, alice, alice)));
        assertFalse(ok, "and the standard path must indeed be shut");

        // Read the balance BEFORE pranking: an argument that is itself a call
        // consumes the prank.
        uint256 held = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeemEmergency(held, alice, alice);
        assertEq(vault.balanceOf(alice), 0, "the in-kind exit must always work");
    }

    /// A vault holding NO cash needs no oracle to serve an exit, and must not
    /// be gated on one. This is why _cashLegValue short-circuits at zero.
    function test_RefusingOracle_ZeroCashVaultStillExits() public {
        vm.prank(keeper);
        vault.rebalanceTo(10000);
        assertEq(cash.balanceOf(address(vault)), 0, "fixture must reach a zero cash leg");
        oracle.setRevertOnRead(true);

        uint256 held = vault.balanceOf(alice);
        assertEq(vault.maxRedeem(alice), held, "no cash leg means no oracle dependency");
        vm.prank(alice);
        vault.redeem(held, alice, alice);
    }

    /// Shared setup for the P1/P2 proofs below: a second holder, bob, joins
    /// with 1e18 against alice's 100e18, and the vault is rebalanced to 50/50
    /// -- the exact configuration docs/design/stock-vault-exit-paths.md
    /// measured the pre-fix dilution against ("Who bears the conversion cost,
    /// settled").
    function _addBobAndRebalanceToFifty() internal returns (address bob) {
        bob = makeAddr("bob");
        stock.mint(bob, 1e18);
        vm.startPrank(bob);
        stock.approve(address(vault), 1e18);
        vault.deposit(1e18, bob);
        vm.stopPrank();

        vm.prank(keeper);
        vault.rebalanceTo(5000);
    }

    /// P1. NO DILUTION -- the whole point of the fix. On this EXACT fixture
    /// (verified by temporarily running it against the pre-fix contract), the
    /// old code takes bob from 999750000000000000 to 974762626260775861: a
    /// 249bps loss, charged to a holder who did nothing, just for sharing a
    /// pool with someone who exited. After the fix, bob is never worse off.
    ///
    /// NOT asserted: that bob's figure is unchanged to a wei or two. It is
    /// not, on this fixture, and that is a separate, understood effect, not a
    /// defect. `previewRedeem`/`maxWithdraw` charge the exiting holder the
    /// RESERVED `maxSlippageBps`, because a view function has no live quote to
    /// charge the REAL fee instead -- the same reason `_deliverableAssets`
    /// haircuts the cash leg by the reserve rather than a real-time price.
    /// `_withdraw`'s own gross-up (unchanged by this fix) sizes the swap off
    /// that same reserve, so whenever the venue's real fee is BELOW it --
    /// 5bps against the 100bps allowance here, the live NVDA/USDG relationship
    /// -- the swap converts more value than alice's exit actually cost, and
    /// the difference remains in the pool for bob. Measured below: he more
    /// than doubles. Both directions -- unchanged, or better -- satisfy
    /// "never diluted"; only a decrease would not, and none is observed.
    function test_P1_NoDilution_OtherHoldersEntitlementIsUnchanged() public {
        address bob = _addBobAndRebalanceToFifty();

        uint256 bobShares = vault.balanceOf(bob);
        uint256 bobBefore = vault.previewRedeem(bobShares);

        // Read maxWithdraw BEFORE pranking: an argument that is itself a call
        // consumes the prank, which would leave the withdraw call itself
        // running as this test contract rather than as alice.
        uint256 aliceMaxWithdraw = vault.maxWithdraw(alice);
        vm.prank(alice);
        vault.withdraw(aliceMaxWithdraw, alice, alice);

        uint256 bobAfter = vault.previewRedeem(bobShares);

        console2.log("bob previewRedeem before  ", bobBefore);
        console2.log("bob previewRedeem after   ", bobAfter);
        console2.log("pre-fix reference (HEAD)  ", uint256(974762626260775861));

        assertGe(bobAfter, bobBefore - 2, "bob must never be diluted by alice's exit, up to a wei or two of rounding");
        // previewRedeem must still never pay out more than the un-haircut
        // conversion, even for bob's own share of the windfall above -- the
        // same invariant P2 and P3 exercise from the exiting holder's side.
        assertLe(bobAfter, vault.convertToAssets(bobShares), "previewRedeem must never exceed the un-haircut conversion");
    }

    /// P2. THE EXITER PAYS. In the same setup, alice must receive strictly
    /// less than the un-haircut NAV of her shares, and the shortfall she bears
    /// must match the closed-form conversion cost, `(net - bal) * h / (10000 - h)`.
    function test_P2_ExiterPaysHerOwnConversionCost() public {
        _addBobAndRebalanceToFifty();

        uint256 aliceShares = vault.balanceOf(alice);
        uint256 gross = vault.convertToAssets(aliceShares);
        uint256 bal = stock.balanceOf(address(vault));
        uint256 net = vault.previewRedeem(aliceShares);

        assertGt(gross, bal, "test must exercise the shortfall branch");
        assertLt(net, gross, "the exiting holder must receive strictly less than the un-haircut NAV");

        uint256 shortfall = gross - net;
        uint256 h = vault.maxSlippageBps();
        uint256 expectedCost = ((net - bal) * h) / (10000 - h);
        console2.log("gross (un-haircut NAV)", gross);
        console2.log("net (previewRedeem)   ", net);
        console2.log("shortfall alice bears ", shortfall);
        assertApproxEqAbs(shortfall, expectedCost, 2, "shortfall must match cost(net) = (net - bal) * h / (10000 - h)");

        vm.prank(alice);
        uint256 got = vault.redeem(aliceShares, alice, alice);
        assertEq(got, net, "redeem must deliver exactly previewRedeem's net figure");
    }

    /// P3. FREE WHEN NOTHING CONVERTS. Two shapes of "nothing to convert":
    /// a vault that is fully long (no cash leg at all), and a partial exit
    /// small enough that the asset leg covers it outright even though the
    /// vault overall is not fully long. Both must cost exactly nothing.
    function test_P3_FreeWhenNothingConverts_FullyLongVault() public {
        vm.prank(keeper);
        vault.rebalanceTo(10000);
        assertEq(cash.balanceOf(address(vault)), 0, "fixture must reach a zero cash leg");

        uint256 shares = vault.balanceOf(alice);
        assertEq(
            vault.previewRedeem(shares),
            vault.convertToAssets(shares),
            "a fully long vault converts nothing and so costs nothing"
        );
    }

    function test_P3_FreeWhenNothingConverts_SmallExitAssetLegCoversItOutright() public {
        vm.prank(keeper);
        vault.rebalanceTo(5000);

        uint256 want = vault.balanceOf(alice) / 10;
        uint256 gross = vault.convertToAssets(want);
        uint256 bal = stock.balanceOf(address(vault));
        assertLe(gross, bal, "test must exercise the no-conversion branch");

        assertEq(
            vault.previewRedeem(want), gross, "an exit the asset leg covers outright pays no conversion cost"
        );
    }

    /// P4. CAPACITY IS 100% AT EVERY POSITION. Replaces the old 98.99%-to-100%
    /// band documented before the conversion cost was charged to the
    /// withdrawer: inverting the payout formula at the maximum yields `gross`
    /// equal to the whole NAV, so a holder who absorbs their own conversion
    /// cost can always be served in full, regardless of position.
    function test_P4_CapacityIsFullAtEveryPosition() public {
        uint16[5] memory targets = [uint16(10000), 7500, 5000, 2500, 0];
        for (uint256 i = 0; i < targets.length; i++) {
            uint256 snap = vm.snapshotState();
            vm.prank(keeper);
            vault.rebalanceTo(targets[i]);

            uint256 held = vault.balanceOf(alice);
            uint256 mr = vault.maxRedeem(alice);
            assertEq(mr, held, "capacity must be exactly 100% of the holding at every position");

            uint256 expected = vault.previewRedeem(mr);
            vm.prank(alice);
            uint256 got = vault.redeem(mr, alice, alice);
            assertEq(got, expected, "the advertised maximum must deliver exactly previewRedeem of it");
            assertEq(vault.balanceOf(alice), 0, "and must exhaust the whole holding");

            console2.log("target", targets[i]);
            console2.log("   capacity bps", (mr * 10000) / held);
            vm.revertToState(snap);
        }
    }

    /// The bounded fuzz test the spec promised (docs/design/stock-vault-exit-paths.md,
    /// "The invariant that would have caught all three") and never got: any
    /// target weight, any redemption fraction of the advertised maxRedeem, and
    /// the redemption must deliver exactly what was previewed for it.
    ///
    /// Bounded with `bound`, not filtered with `vm.assume`: every input in
    /// range is a real trade the fuzzer must exercise rather than a candidate
    /// it can reject its way out of.
    function testFuzz_RedeemFractionOfMaxRedeemDeliversPreview(uint16 targetBps, uint256 pct) public {
        targetBps = uint16(bound(targetBps, 0, 10000));
        pct = bound(pct, 1, 100);

        vm.prank(keeper);
        vault.rebalanceTo(targetBps);

        uint256 mr = vault.maxRedeem(alice);
        assertGt(mr, 0, "a solvent single-holder vault must advertise some capacity at every target");

        uint256 want = (mr * pct) / 100;
        uint256 expected = vault.previewRedeem(want);
        uint256 before = stock.balanceOf(alice);

        vm.prank(alice);
        uint256 got = vault.redeem(want, alice, alice);

        assertEq(got, expected, "redeem must return exactly what was previewed for this fraction");
        assertEq(stock.balanceOf(alice) - before, expected, "and must deliver exactly that many assets");
    }
}

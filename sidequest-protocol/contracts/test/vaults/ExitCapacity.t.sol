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
            0, 100, 100, 0,
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
    /// Held at a 50/50 position (h = exitCostBps = 100 here), the wrong
    /// formula clears every fill up to 99bps and reverts at exactly 100bps:
    /// the breakeven is 10000h/(10000+h) = 99.0099bps, so 99 rounds down to
    /// "still clears" and 100 is the first integer past it.
    function test_MaxRedeemExecutesAsVenueFeeApproachesExitCost() public {
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

    /// The sweep above only ever approaches exitCostBps from below, so it
    /// never actually checks that the bound is honest ABOVE it. This sweeps
    /// the venue fee ACROSS a fixed, modest exitCostBps (25, so the sweep is
    /// cheap): at fee <= exitCostBps, redeem(maxRedeem(owner)) must still
    /// execute; above it, the venue's realised cost exceeds what maxRedeem
    /// priced in, and the fill cannot cover the shortfall -- the swap must
    /// revert instead of silently overcharging. The cliff sits exactly one
    /// basis point above exitCostBps, matching the rewritten comment on
    /// `_withdraw`'s gross-up in SpotVaultMinimal.sol.
    function test_MaxRedeemHonoursItsBoundAcrossTheExitCostCliff() public {
        uint16 fixedExitCostBps = 25;
        SpotVaultMinimal v = _freshVault(100, fixedExitCostBps);

        address holder = makeAddr("cliff-holder");
        stock.mint(holder, DEPOSIT);
        vm.startPrank(holder);
        stock.approve(address(v), DEPOSIT);
        v.deposit(DEPOSIT, holder);
        vm.stopPrank();

        vm.prank(keeper);
        v.rebalanceTo(5000);

        uint256[6] memory venueFeesBps = [uint256(23), 24, 25, 26, 27, 28];
        for (uint256 i = 0; i < venueFeesBps.length; i++) {
            uint256 snap = vm.snapshotState();
            venue.setFee(venueFeesBps[i]);

            uint256 mr = v.maxRedeem(holder);
            assertGt(mr, 0, "a solvent vault must advertise some capacity regardless of the real venue fee");

            vm.prank(holder);
            (bool ok,) = address(v).call(abi.encodeCall(v.redeem, (mr, holder, holder)));

            console2.log("venue fee bps", venueFeesBps[i]);
            console2.log("   executed  ", ok);

            if (venueFeesBps[i] <= fixedExitCostBps) {
                assertTrue(ok, "at or below exitCostBps, the advertised maximum must execute");
            } else {
                assertFalse(ok, "above exitCostBps, the realised cost exceeds what maxRedeem priced in");
            }
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
            0, 100, 100, 1000, // performanceFeeBps: the live figure, not the fixture's zero
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

    /// P1. THE GROSS CLAIM IS NEVER DILUTED. On this EXACT fixture (verified
    /// by temporarily running it against the pre-fix contract), the old code
    /// took bob's previewRedeem from 999750000000000000 to 974762626260775861:
    /// a 249bps loss, charged to a holder who did nothing, just for sharing a
    /// pool with someone who exited. After the fix, bob's GROSS claim --
    /// `convertToAssets`, the oracle-priced NAV of his shares with no exit
    /// haircut applied -- never falls.
    ///
    /// NOT asserted here: that bob's NET quote, `previewRedeem`, is unchanged
    /// or improved. It is neither, in general -- with two EQUAL holders it
    /// FALLS when the other exits first, because the asset leg `previewRedeem`
    /// prices against is finite and first-come-first-served. See
    /// docs/design/stock-vault-exit-paths.md, "The net quote is not held
    /// whole", and test_Q4_FirstMoverEdge_PinnedAtDeployedExitCost below.
    /// This fixture's 100:1 holder ratio happens to land on the OTHER side of
    /// that effect -- alice is charged the RESERVED exitCostBps (100bps)
    /// against a 5bps real venue fee, and that surplus dwarfs anything the
    /// shared-asset-leg mechanism could cost a holder as small as bob -- but
    /// that is a property of this fixture's ratio, not a guarantee, which is
    /// exactly why this test now checks the one thing that IS guaranteed.
    function test_P1_GrossClaimNeverDiluted_OtherHoldersEntitlementIsUnchanged() public {
        address bob = _addBobAndRebalanceToFifty();

        uint256 bobShares = vault.balanceOf(bob);
        uint256 bobGrossBefore = vault.convertToAssets(bobShares);

        // Read maxWithdraw BEFORE pranking: an argument that is itself a call
        // consumes the prank, which would leave the withdraw call itself
        // running as this test contract rather than as alice.
        uint256 aliceMaxWithdraw = vault.maxWithdraw(alice);
        vm.prank(alice);
        vault.withdraw(aliceMaxWithdraw, alice, alice);

        uint256 bobGrossAfter = vault.convertToAssets(bobShares);

        console2.log("bob convertToAssets before", bobGrossBefore);
        console2.log("bob convertToAssets after ", bobGrossAfter);

        assertGe(bobGrossAfter, bobGrossBefore, "bob's gross claim must never decrease when alice exits");
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
        uint256 h = vault.exitCostBps();
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

    // ─── Q1-Q4: exitCostBps split from maxSlippageBps ──────────────────────
    //
    // maxSlippageBps used to price exits AND bound rebalances, and those two
    // jobs want different values: a swap bound needs headroom for price
    // impact (Slice 1 measured a $50k trade cutting in-range liquidity 65%
    // on the live pool), while an exit price should track the realised cost,
    // near the 5bps fee tier. Measured at the live 100bps setting against a
    // 5bps venue, a stranger's exit made the remaining holder GAIN 4601bps;
    // at 25bps the gain is 964bps; at 6bps, 43bps. Q1-Q3 are the proof that
    // splitting the parameter fixes the mispricing without reopening the
    // dilution P1-P4 already closed. Q4 pins the first-mover effect that
    // splitting the parameter does NOT remove -- see docs/design/
    // stock-vault-exit-paths.md, "The net quote is not held whole".

    /// @dev A vault wired exactly like the one in `setUp`, but with its own
    ///      maxSlippageBps and exitCostBps, so Q1-Q4 can move either one
    ///      independently of the other.
    function _freshVault(uint16 maxSlippageBps_, uint16 exitCostBps_) internal returns (SpotVaultMinimal v) {
        v = new SpotVaultMinimal(
            address(stock), address(cash), address(oracle), 1 hours,
            "Zorpha NVDA Long/Flat", "zqNVDA",
            0, maxSlippageBps_, exitCostBps_, 0,
            address(this), address(this),
            0
        );
        v.setSwapAdapter(address(venue));
        v.grantRole(v.KEEPER_ROLE(), keeper);
    }

    /// Q1. THE TWO PARAMETERS ARE INDEPENDENT. A vault built with a HIGH
    /// maxSlippageBps (100) and a LOW exitCostBps (25) must let through a
    /// rebalance that a 25bps swap bound would refuse -- proven directly by
    /// an otherwise-identical vault held to that 25bps bound reverting on the
    /// exact same trade -- and must price an exit off the 25bps exitCostBps,
    /// never off the 100bps maxSlippageBps.
    function test_Q1_MaxSlippageAndExitCostAreIndependent() public {
        SpotVaultMinimal q1 = _freshVault(100, 25);
        SpotVaultMinimal tightRebalance = _freshVault(25, 25);

        address dave = makeAddr("q1-dave");
        stock.mint(dave, DEPOSIT);
        vm.startPrank(dave);
        stock.approve(address(q1), DEPOSIT);
        q1.deposit(DEPOSIT, dave);
        vm.stopPrank();

        address erin = makeAddr("q1-erin");
        stock.mint(erin, DEPOSIT);
        vm.startPrank(erin);
        stock.approve(address(tightRebalance), DEPOSIT);
        tightRebalance.deposit(DEPOSIT, erin);
        vm.stopPrank();

        // 50bps: clears a 100bps swap bound, breaches a 25bps one.
        venue.setFee(50);

        vm.prank(keeper);
        vm.expectRevert("venue: slippage");
        tightRebalance.rebalanceTo(5000);

        vm.prank(keeper);
        q1.rebalanceTo(5000);
        assertGt(cash.balanceOf(address(q1)), 0, "the 100bps-bound vault must have actually rebalanced");

        // The exit-pricing half: previewRedeem must charge dave off the
        // 25bps exitCostBps, never the 100bps maxSlippageBps.
        uint256 shares = q1.balanceOf(dave);
        uint256 gross = q1.convertToAssets(shares);
        uint256 bal = stock.balanceOf(address(q1));
        assertGt(gross, bal, "test must exercise the shortfall branch");

        uint256 net = q1.previewRedeem(shares);
        uint256 charged = gross - net;
        uint256 expected = ((net - bal) * 25) / (10000 - 25);
        console2.log("Q1 charged  (exitCostBps=25)", charged);
        console2.log("Q1 expected (exitCostBps=25)", expected);
        assertApproxEqAbs(charged, expected, 2, "the exit must be priced off exitCostBps, not maxSlippageBps");
    }

    /// @dev Shared fixture for Q2 and Q3: a fresh vault at the given
    ///      exitCostBps (maxSlippageBps fixed at 100 throughout, so only
    ///      exitCostBps moves), seeded like `_addBobAndRebalanceToFifty`
    ///      (100e18 against 1e18, rebalanced to 50/50), with the big holder
    ///      then exiting its maxWithdraw. Returns the small holder's NET quote
    ///      (`previewRedeem`) and GROSS claim (`convertToAssets`) immediately
    ///      before and after -- Q2 uses the gross pair, Q3 the net pair. They
    ///      are not interchangeable: see docs/design/stock-vault-exit-paths.md,
    ///      "The net quote is not held whole".
    function _exitAndMeasureStayer(uint16 exitCostBps_)
        internal
        returns (uint256 stayerNetBefore, uint256 stayerNetAfter, uint256 stayerGrossBefore, uint256 stayerGrossAfter)
    {
        SpotVaultMinimal v = _freshVault(100, exitCostBps_);

        address bigHolder = makeAddr("q23-big");
        address smallHolder = makeAddr("q23-small");

        stock.mint(bigHolder, DEPOSIT);
        vm.startPrank(bigHolder);
        stock.approve(address(v), DEPOSIT);
        v.deposit(DEPOSIT, bigHolder);
        vm.stopPrank();

        stock.mint(smallHolder, 1e18);
        vm.startPrank(smallHolder);
        stock.approve(address(v), 1e18);
        v.deposit(1e18, smallHolder);
        vm.stopPrank();

        vm.prank(keeper);
        v.rebalanceTo(5000);

        uint256 smallShares = v.balanceOf(smallHolder);
        stayerNetBefore = v.previewRedeem(smallShares);
        stayerGrossBefore = v.convertToAssets(smallShares);

        uint256 mw = v.maxWithdraw(bigHolder);
        vm.prank(bigHolder);
        v.withdraw(mw, bigHolder, bigHolder);

        stayerNetAfter = v.previewRedeem(smallShares);
        stayerGrossAfter = v.convertToAssets(smallShares);
    }

    /// Q2. THE GROSS CLAIM IS STILL NEVER DILUTED, at exitCostBps far below
    /// the live maxSlippageBps setting -- the same property P1 proves at 100,
    /// re-proven here at the two values Q3 measures next.
    ///
    /// This checks `convertToAssets`, the gross claim, not `previewRedeem`.
    /// The NET quote does not get the same guarantee -- see
    /// docs/design/stock-vault-exit-paths.md, "The net quote is not held
    /// whole" -- which is exactly what made the old version of this test
    /// (asserting previewRedeem instead, with a wei-or-two tolerance) true
    /// only by accident of this fixture's 100:1 holder ratio.
    function test_Q2_GrossClaimNeverDiluted_AtLowExitCost() public {
        (,, uint256 grossBefore25, uint256 grossAfter25) = _exitAndMeasureStayer(25);
        assertGe(grossAfter25, grossBefore25, "stayer's gross claim must never decrease, exitCostBps 25");

        (,, uint256 grossBefore6, uint256 grossAfter6) = _exitAndMeasureStayer(6);
        assertGe(grossAfter6, grossBefore6, "stayer's gross claim must never decrease, exitCostBps 6");
    }

    /// Q3. A LOWER exitCostBps SHRINKS THE TRANSFER TO WHOEVER STAYS. Same
    /// two-holder fixture as Q2; the stayer's gain must strictly shrink going
    /// from 100 (the live maxSlippageBps setting, before this split existed)
    /// to 25 (script/DeployStockVault.s.sol's new EXIT_COST_BPS) -- the same
    /// direction measured in the incidence notes (4601bps at 100, 964bps at
    /// 25). This is the NET quote, deliberately: it is the windfall side of
    /// the same mechanism Q4 pins the cost side of.
    function test_Q3_LowerExitCostShrinksTheStayerGain() public {
        (uint256 before100, uint256 after100,,) = _exitAndMeasureStayer(100);
        (uint256 before25, uint256 after25,,) = _exitAndMeasureStayer(25);

        uint256 gainBpsAt100 = ((after100 - before100) * 10000) / before100;
        uint256 gainBpsAt25 = ((after25 - before25) * 10000) / before25;

        console2.log("Q3 stayer gain bps, exitCostBps 100", gainBpsAt100);
        console2.log("Q3 stayer gain bps, exitCostBps  25", gainBpsAt25);
        assertLt(gainBpsAt25, gainBpsAt100, "a lower exitCostBps must shrink the stayer's windfall");
    }

    /// Q4. THE FIRST-MOVER EDGE, PINNED. Two EQUAL holders, exitCostBps at the
    /// deployed value (250) -- a fixture no other test in this file uses. The
    /// mechanism behind P1 and Q2's caveats and docs/design/
    /// stock-vault-exit-paths.md's "The net quote is not held whole": the
    /// asset leg `previewRedeem` prices against is finite and
    /// first-come-first-served, so whichever of two EQUAL holders redeems
    /// FIRST clears for free while the other's own NET quote falls, even
    /// though neither holder did anything to the other.
    ///
    /// Pinned so the edge cannot drift silently if the formula ever changes:
    /// measured at 249bps falling / 256bps first-mover edge for exitCostBps
    /// 250.
    function test_Q4_FirstMoverEdge_PinnedAtDeployedExitCost() public {
        uint16 deployedExitCostBps = 250;
        SpotVaultMinimal v = _freshVault(100, deployedExitCostBps);

        address mover = makeAddr("q4-mover");
        address stayer = makeAddr("q4-stayer");

        stock.mint(mover, DEPOSIT);
        vm.startPrank(mover);
        stock.approve(address(v), DEPOSIT);
        v.deposit(DEPOSIT, mover);
        vm.stopPrank();

        stock.mint(stayer, DEPOSIT);
        vm.startPrank(stayer);
        stock.approve(address(v), DEPOSIT);
        v.deposit(DEPOSIT, stayer);
        vm.stopPrank();

        vm.prank(keeper);
        v.rebalanceTo(5000);

        uint256 stayerShares = v.balanceOf(stayer);
        uint256 before = v.previewRedeem(stayerShares);

        // The mover redeems its ENTIRE holding first, consuming the whole
        // asset leg (each holder's gross claim exactly matches it, at 50/50
        // with equal deposits) before the stayer prices anything.
        uint256 moverShares = v.balanceOf(mover);
        vm.prank(mover);
        v.redeem(moverShares, mover, mover);

        uint256 afterMoverExits = v.previewRedeem(stayerShares);
        assertLt(afterMoverExits, before, "test must exercise the first-mover effect, or the fixture has drifted");

        uint256 fallBps = ((before - afterMoverExits) * 10000) / before;
        uint256 firstMoverEdgeBps = ((before - afterMoverExits) * 10000) / afterMoverExits;

        console2.log("Q4 stayer previewRedeem before mover exits", before);
        console2.log("Q4 stayer previewRedeem after  mover exits", afterMoverExits);
        console2.log("Q4 stayer's net quote falls, bps          ", fallBps);
        console2.log("Q4 going first is worth, bps              ", firstMoverEdgeBps);

        assertApproxEqAbs(
            firstMoverEdgeBps, 256, 2, "the first-mover edge must not drift silently from the measured 256bps"
        );
    }
}

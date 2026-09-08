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
}

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
    function test_ZeroCashLeg_IsFullyRedeemable() public {
        vm.prank(keeper);
        vault.rebalanceTo(10000);
        assertEq(cash.balanceOf(address(vault)), 0, "fixture must reach a zero cash leg");

        uint256 held = vault.balanceOf(alice);
        assertEq(vault.maxRedeem(alice), held, "a zero-cash vault must be fully redeemable");
        vm.prank(alice);
        vault.redeem(held, alice, alice);
        assertEq(vault.balanceOf(alice), 0, "and the exit must complete");
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
}

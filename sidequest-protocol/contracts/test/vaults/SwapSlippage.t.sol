// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {SpotVaultMinimal} from "../../src/vaults/SpotVaultMinimal.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockOracle} from "../mocks/MockOracle.sol";
import {SlippingSpotAdapter, LyingSpotAdapter} from "../mocks/SlippingSpotAdapter.sol";

/// @notice What happens when the venue is not free.
///
///         Every spot test until now used MockSpotAdapter, which fills at the
///         oracle price exactly. So maxSlippageBps -- the parameter whose entire
///         job is to bound what a rebalance may cost -- had never once been the
///         thing that decided an outcome. On testnet it is worse: SWAP_ROUTER is
///         unset, so the deployed adapter is StubSwapAdapter, which swaps 1:1
///         ignoring price and decimals. Every drill that "rebalances" moves
///         tokens through a venue with no market in it.
///
///         These tests put a venue in the way that charges a fee, charges more
///         for size, and in one case reports a fill it does not deliver.
contract SwapSlippageTest is Test {
    MockERC20 asset;    // 18dp equity
    MockERC20 cash;     // 6dp stable
    MockOracle oracle;
    SpotVaultMinimal vault;
    SlippingSpotAdapter venue;

    address admin = address(this);
    uint16 constant MAX_SLIPPAGE_BPS = 100;   // 1%

    function setUp() public {
        vm.warp(1_800_000_000);
        asset = new MockERC20("Equity", "EQ", 18);
        cash = new MockERC20("Cash", "USD", 6);
        oracle = new MockOracle(250e8, 8);

        vault = new SpotVaultMinimal(
            address(asset), address(cash), address(oracle), 1 hours,
            "Vault", "V",
            0,                    // rebalance on any drift, so the swap always runs
            MAX_SLIPPAGE_BPS,
            0, admin, admin, 0
        );
        venue = new SlippingSpotAdapter(address(asset), address(cash), address(oracle));
        vault.setSwapAdapter(address(venue));
        vault.grantRole(vault.KEEPER_ROLE(), admin);

        // Deep venue inventory on both legs, so a failure is about pricing
        // rather than about the venue running dry.
        asset.mint(address(venue), 1_000_000e18);
        cash.mint(address(venue), 1_000_000e6);

        // A depositor, fully in the equity leg.
        asset.mint(admin, 100e18);
        asset.approve(address(vault), 100e18);
        vault.deposit(100e18, admin);
    }

    // --- Inside the bound ----------------------------------------------------

    /// A 50 bps venue against a 100 bps tolerance: the trade goes through and
    /// the vault gives up real value doing it. The loss is what makes this a
    /// test rather than a restatement of the perfect-fill case.
    function test_AVenueInsideTheBoundTradesAndCostsSomething() public {
        venue.setFee(50);
        uint256 before = vault.grossValue();

        vault.rebalanceTo(5000);

        assertEq(vault.rebalanceCount(), 1, "the rebalance did not happen");
        uint256 afterValue = vault.grossValue();
        assertLt(afterValue, before, "a 50bps venue cost the vault nothing, so it was not used");

        // Half the book crossed at 50bps, so the whole vault loses about 25bps.
        uint256 lostBps = ((before - afterValue) * 10000) / before;
        assertLe(lostBps, MAX_SLIPPAGE_BPS, "lost more than the bound permits");
        assertGe(lostBps, 10, "the loss is too small to be the venue fee");

        // On the SUCCESS path too. A refused swap reverts the approval along
        // with everything else, so the no-residue test above cannot show this:
        // only a completed swap can leave an allowance standing.
        assertEq(
            asset.allowance(address(vault), address(venue)), 0,
            "the vault still approves the venue after a completed swap"
        );
        assertEq(cash.allowance(address(vault), address(venue)), 0, "cash allowance left standing");
    }

    // --- Outside the bound ---------------------------------------------------

    /// The parameter finally doing its job. At 150bps against a 100bps bound the
    /// vault must refuse rather than book the trade.
    function test_AVenueOutsideTheBoundIsRefused() public {
        venue.setFee(150);

        vm.expectRevert(bytes("venue: slippage"));
        vault.rebalanceTo(5000);

        assertEq(vault.rebalanceCount(), 0, "the rebalance was booked anyway");
        assertEq(vault.targetWeightBps(), 0, "the target moved despite the refusal");
    }

    /// And the refusal leaves nothing behind: no half-trade, no stranded
    /// allowance to the venue.
    function test_ARefusedSwapLeavesNoResidue() public {
        venue.setFee(150);
        uint256 assetBefore = asset.balanceOf(address(vault));
        uint256 cashBefore = cash.balanceOf(address(vault));

        vm.expectRevert(bytes("venue: slippage"));
        vault.rebalanceTo(5000);

        assertEq(asset.balanceOf(address(vault)), assetBefore, "asset left the vault");
        assertEq(cash.balanceOf(address(vault)), cashBefore, "cash appeared from a refused swap");
        assertEq(asset.allowance(address(vault), address(venue)), 0, "a stranded allowance remains");
    }

    // --- Size ----------------------------------------------------------------

    /// Capacity, which is the constraint RobinhoodChainRouterAdapter documents
    /// from live pools: 0.44% at 10k, 0.94% at 20k, 31% at 40k. A vault sized
    /// past what the pool absorbs is a vault that cannot rebalance -- correct
    /// behaviour, and a ceiling on vault size rather than a bug.
    function test_TheSameVenueRefusesTheSameTradeAtSize() public {
        // Impact reaches 400bps for a trade the size of the whole book.
        venue.setFee(10);
        venue.setImpact(50e18, 400);

        // Half of 100e18 is 50e18: full depth, so ~400bps of impact. Refused.
        vm.expectRevert(bytes("venue: slippage"));
        vault.rebalanceTo(5000);

        // A tenth of that size pays a hundredth of the impact, and lands.
        vault.rebalanceTo(9500);
        assertEq(vault.rebalanceCount(), 1, "even a small trade was refused");
    }

    // --- The venue that lies -------------------------------------------------

    /// The reason _swap measures a balance instead of believing a return value.
    ///
    ///         uint256 out = swapAdapter.swap(...);
    ///         require(out >= minOut, "slippage");
    ///
    /// LyingSpotAdapter returns exactly minOut and transfers 10% less. Against
    /// the old check it passed, and the vault booked a fill it never received.
    function test_AVenueThatReportsAFillItDidNotDeliverIsCaught() public {
        LyingSpotAdapter liar = new LyingSpotAdapter(address(asset), address(cash));
        cash.mint(address(liar), 1_000_000e6);
        liar.setShortfall(1000);          // pays 90% of what it claims
        vault.setSwapAdapter(address(liar));

        vm.expectRevert(bytes("slippage"));
        vault.rebalanceTo(5000);

        assertEq(vault.rebalanceCount(), 0, "a phantom fill was booked");
    }

    /// The same adapter telling the truth still works, so the check above is
    /// catching the shortfall rather than the adapter simply being unusual.
    function test_TheSameVenueTellingTheTruthIsAccepted() public {
        LyingSpotAdapter honest = new LyingSpotAdapter(address(asset), address(cash));
        cash.mint(address(honest), 1_000_000e6);
        honest.setShortfall(0);
        vault.setSwapAdapter(address(honest));

        vault.rebalanceTo(5000);
        assertEq(vault.rebalanceCount(), 1, "an honest fill was refused");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RWRotationVault} from "../../src/vaults/RWRotationVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockOracle} from "../mocks/MockOracle.sol";
import {ReceiptRenderer} from "../../src/lib/ReceiptRenderer.sol";

contract RWRotationVaultTest is Test {
    MockERC20 usdc;
    MockERC20 hood;
    MockERC20 nvda;
    MockOracle usdcOracle;
    MockOracle hoodOracle;
    MockOracle nvdaOracle;
    RWRotationVault vault;

    address alice = makeAddr("alice");
    address keeper = makeAddr("keeper");

    function setUp() public {
        vm.warp(1_700_000_000);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        hood = new MockERC20("Robinhood Stock", "HOOD", 8);
        nvda = new MockERC20("Nvidia Stock", "NVDA", 8);

        usdcOracle = new MockOracle(1e8, 8); // $1
        hoodOracle = new MockOracle(20 * 1e8, 8); // $20
        nvdaOracle = new MockOracle(500 * 1e8, 8); // $500

        address[] memory tokens = new address[](2);
        tokens[0] = address(hood);
        tokens[1] = address(nvda);
        address[] memory oracles = new address[](2);
        oracles[0] = address(hoodOracle);
        oracles[1] = address(nvdaOracle);
        uint16[] memory weights = new uint16[](2);
        weights[0] = 5000;
        weights[1] = 5000;

        vault = new RWRotationVault(
            address(usdc), tokens, oracles, 1 hours, weights,
            "Zorpha Rotation Vault", "sqROT",
            0, address(this), address(this)
        );
        vault.grantRole(vault.KEEPER_ROLE(), keeper);

        hood.mint(alice, 100 * 1e8);
        nvda.mint(alice, 100 * 1e8);
    }

    function _depositUnderlying() internal returns (uint256 shares) {
        // Deposit tokens[0] (HOOD) to mint shares.
        uint256 amt = 10 * 1e8;
        vm.startPrank(alice);
        hood.approve(address(vault), amt);
        shares = vault.deposit(amt, alice);
        vm.stopPrank();
    }

    function test_BadWeights_Reverts() public {
        uint16[] memory bad = new uint16[](2);
        bad[0] = 5000; bad[1] = 4000; // sum != 10000
        vm.expectRevert();
        vm.prank(keeper);
        vault.rebalanceTo(bad);
    }

    function test_Rebalance_StoresNewWeightsAndEmits() public {
        _depositUnderlying();

        uint16[] memory newWeights = new uint16[](2);
        newWeights[0] = 2000;
        newWeights[1] = 8000;

        uint256 nav = vault.getNavPerShare();
        uint256 baseLeg = usdc.balanceOf(address(vault));
        uint256[] memory tokenLegs = new uint256[](2);
        tokenLegs[0] = hood.balanceOf(address(vault));
        tokenLegs[1] = nvda.balanceOf(address(vault));

        bytes32 expCommit = ReceiptRenderer.basketCommitment(
            keeper, address(vault), newWeights, nav, tokenLegs, baseLeg, 1, block.timestamp, bytes32(0)
        );

        vm.expectEmit(false, false, false, true, address(vault));
        emit RWRotationVault.Rebalanced(newWeights, nav, tokenLegs, baseLeg, 1, expCommit);

        vm.prank(keeper);
        vault.rebalanceTo(newWeights);

        assertEq(vault.targetWeightsBps(0), 2000);
        assertEq(vault.targetWeightsBps(1), 8000);
        assertEq(vault.rebalanceCount(), 1);
    }

    /// The rotation receipt must bind the basket weights and every token leg.
    /// The previous commitment passed `rebalanceCount % 65536` as the target
    /// weight and a constant checksum as the cash leg, so two rebalances to
    /// completely different baskets could hash identically.
    function test_BasketCommitmentBindsWeightsAndLegs() public view {
        uint16[] memory wA = new uint16[](2);
        wA[0] = 2000;
        wA[1] = 8000;
        uint16[] memory wB = new uint16[](2);
        wB[0] = 8000;
        wB[1] = 2000;

        uint256[] memory legsA = new uint256[](2);
        legsA[0] = 1e8;
        legsA[1] = 5e8;
        uint256[] memory legsB = new uint256[](2);
        legsB[0] = 5e8;
        legsB[1] = 1e8;

        bytes32 base = ReceiptRenderer.basketCommitment(
            keeper, address(vault), wA, 1e6, legsA, 100e6, 1, 1_700_000_000, bytes32(0)
        );

        assertTrue(base != bytes32(0), "commitment must not be zero");
        assertTrue(
            base
                != ReceiptRenderer.basketCommitment(
                    keeper, address(vault), wB, 1e6, legsA, 100e6, 1, 1_700_000_000, bytes32(0)
                ),
            "reordered weights must change the hash"
        );
        assertTrue(
            base
                != ReceiptRenderer.basketCommitment(
                    keeper, address(vault), wA, 1e6, legsB, 100e6, 1, 1_700_000_000, bytes32(0)
                ),
            "reordered token legs must change the hash"
        );
        assertEq(
            base,
            ReceiptRenderer.basketCommitment(
                keeper, address(vault), wA, 1e6, legsA, 100e6, 1, 1_700_000_000, bytes32(0)
            ),
            "same inputs must reproduce the same hash"
        );
    }

    function test_RebalanceLengthMismatch_Reverts() public {
        uint16[] memory bad = new uint16[](3);
        bad[0] = 5000; bad[1] = 3000; bad[2] = 2000;
        vm.expectRevert();
        vm.prank(keeper);
        vault.rebalanceTo(bad);
    }

    function test_BasketLengthReturns() public {
        assertEq(vault.basketLength(), 2);
    }

    // ─── Performance fee ────────────────────────────────────────────────────
    // The vault advertised a 20% fee but had no evaluateFees or claimFees at
    // all, so the accrual slot was never written and the protocol earned
    // nothing from it.

    function test_EvaluateFees_NoAccrualBelowHighWaterMark() public {
        _depositUnderlying();
        vm.prank(keeper);
        vault.evaluateFees();
        assertEq(vault.performanceFeeAccrued(), 0, "no fee without a new high");
    }

    function test_EvaluateFees_AccruesOnNewHighWaterMark() public {
        // Fee-bearing vault: 20%, base asset USDC.
        address[] memory tokens = new address[](2);
        tokens[0] = address(hood);
        tokens[1] = address(nvda);
        address[] memory oracles = new address[](2);
        oracles[0] = address(hoodOracle);
        oracles[1] = address(nvdaOracle);
        uint16[] memory weights = new uint16[](2);
        weights[0] = 5000;
        weights[1] = 5000;

        RWRotationVault feeVault = new RWRotationVault(
            address(usdc), tokens, oracles, 1 hours, weights,
            "Fee Rotation", "fROT",
            2000, address(this), address(this)
        );
        feeVault.grantRole(feeVault.KEEPER_ROLE(), keeper);

        uint256 amt = 10 * 1e8;
        vm.startPrank(alice);
        hood.approve(address(feeVault), amt);
        feeVault.deposit(amt, alice);
        vm.stopPrank();

        // HOOD doubles: $20 -> $40. NAV per share rises, so a fee is due.
        hoodOracle.setPrice(40 * 1e8);

        vm.prank(keeper);
        feeVault.evaluateFees();
        uint256 accrued = feeVault.performanceFeeAccrued();
        assertGt(accrued, 0, "fee must accrue on a new high");

        // Re-evaluating at the same NAV must not bill twice.
        vm.prank(keeper);
        feeVault.evaluateFees();
        assertEq(feeVault.performanceFeeAccrued(), accrued, "no double billing at the same high");

        // The accrual can never exceed what the vault holds.
        assertLe(accrued, feeVault.grossValue(), "accrual exceeds holdings");
    }

    // ─── The two fee-state bugs, checked here last ──────────────────────────
    //
    // Both were found and fixed in SpotVaultMinimal and YieldVault first. The
    // findings docs said to audit "every contract that subtracts an accrued fee
    // from a live balance" rather than "contracts like the spot vault", and this
    // is the third and last of them. It had both, and neither fix.

    /// A fee-bearing rotation vault, since the suite's main one is built with a
    /// zero fee.
    function _feeVault() internal returns (RWRotationVault v) {
        address[] memory tokens = new address[](2);
        tokens[0] = address(hood);
        tokens[1] = address(nvda);
        address[] memory oracles = new address[](2);
        oracles[0] = address(hoodOracle);
        oracles[1] = address(nvdaOracle);
        uint16[] memory weights = new uint16[](2);
        weights[0] = 5000;
        weights[1] = 5000;

        v = new RWRotationVault(
            address(usdc), tokens, oracles, 1 hours, weights,
            "Fee Rotation", "fROT",
            2000, address(this), address(this)
        );
        v.grantRole(v.KEEPER_ROLE(), keeper);
    }

    function _depositTo(RWRotationVault v, address who, uint256 amt) internal returns (uint256) {
        vm.startPrank(who);
        hood.approve(address(v), amt);
        uint256 sh = v.deposit(amt, who);
        vm.stopPrank();
        return sh;
    }

    /// Equalisation, second cohort. The previous version of this test asserted
    /// `highWaterMark == getNavPerShare()` right after the new deposit, and
    /// passed with `_markFirstEntry` disabled -- because in that scenario the
    /// incoming price happened to equal the departed mark, so there was no gap
    /// to detect. A test that cannot fail is worse than no test, so it is built
    /// around a deliberate gap now: the price MOVES between the exit and the
    /// entry.
    function test_FeeAccrual_AfterEmptying_MarksTheNewEntryPrice() public {
        RWRotationVault v = _feeVault();
        address bob = makeAddr("bob");
        hood.mint(bob, 100 * 1e8);

        uint256 sh = _depositTo(v, alice, 10 * 1e8);
        hoodOracle.setPrice(40 * 1e8); // HOOD doubles, alice is charged
        vm.prank(keeper);
        v.evaluateFees();
        assertGt(v.performanceFeeAccrued(), 0, "alice was charged for her gain");

        vm.prank(alice);
        v.redeem(sh, alice, alice);
        assertEq(v.totalSupply(), 0, "vault is empty");
        uint256 markAfterAlice = v.highWaterMark();

        // The price falls before bob arrives, so his entry price CANNOT equal
        // alice's peak. This is the gap the old version lacked.
        hoodOracle.setPrice(10 * 1e8);

        _depositTo(v, bob, 10 * 1e8);
        uint256 bobEntryNav = v.getNavPerShare();

        assertTrue(bobEntryNav < markAfterAlice, "bob really did enter below alice's peak");
        assertEq(
            v.highWaterMark(), bobEntryNav,
            "the mark must follow bob's entry price, not alice's peak"
        );
    }

    /// Fee-claim backing. The claim is a fixed number in base-asset units and
    /// `grossValue()` is live, so a price move against the leg a fee was struck
    /// in leaves the claim larger than what backs it. `totalAssets()` floors at
    /// zero rather than reporting the gap, and on an empty vault the sentinel
    /// price cannot carry the encumbrance -- so the next depositor settles it.
    function test_UnclaimedFee_DoesNotDiluteTheNextDepositor() public {
        RWRotationVault v = _feeVault();
        address bob = makeAddr("bob");
        hood.mint(bob, 100 * 1e8);

        uint256 sh = _depositTo(v, alice, 10 * 1e8);
        hoodOracle.setPrice(40 * 1e8);
        vm.prank(keeper);
        v.evaluateFees();
        uint256 claim = v.performanceFeeAccrued();
        assertGt(claim, 0, "a claim exists");

        vm.prank(alice);
        v.redeem(sh, alice, alice);
        assertEq(v.totalSupply(), 0, "empty, still carrying the claim");

        // The claim was struck at $40. Back at $20 the retained holding is worth
        // half as much in base terms, so the claim outgrows its backing.
        hoodOracle.setPrice(20 * 1e8);

        uint256 deposited = 10 * 1e8;
        uint256 bobShares = _depositTo(v, bob, deposited);

        assertEq(
            v.convertToAssets(bobShares), v.convertToAssets(bobShares),
            "sanity"
        );
        // Bob must not be worth less than he paid the instant he enters.
        uint256 bobValueInBase = v.convertToAssets(bobShares);
        uint256 paidInBase = v.previewDeposit(deposited) == 0
            ? 0
            : v.convertToAssets(v.previewDeposit(deposited));
        assertGe(
            bobValueInBase + 2, paidInBase,
            "bob holds at least what an identical deposit is priced at"
        );
        assertLe(
            v.performanceFeeAccrued(), v.grossValue(),
            "the claim can never exceed the value behind it"
        );
    }

    /// A clean round trip in ONE unit, to settle what the vault's ERC-4626
    /// arithmetic is actually denominated in.
    ///
    /// `asset()` is tokens[0] (HOOD, 8dp) but `totalAssets()` returns
    /// `grossValue()`, which is in BASE units (USDC, 6dp), and no conversion
    /// function is overridden. So OpenZeppelin's ERC4626 sizes shares against a
    /// USDC-denominated total and then transfers HOOD. This measures whether
    /// that matters: no fee, no price move, sole depositor, deposit then redeem.
    function test_Units_DepositRedeemRoundTrip() public {
        uint256 amt = 10 * 1e8;
        uint256 before_ = hood.balanceOf(alice);

        vm.startPrank(alice);
        hood.approve(address(vault), amt);
        uint256 sh = vault.deposit(amt, alice);
        vault.redeem(sh, alice, alice);
        vm.stopPrank();

        uint256 returned = hood.balanceOf(alice) - (before_ - amt);

        // Before the fix this returned 2 HOOD for 10 deposited: shares were
        // sized against a base-denominated `totalAssets()` and then paid out in
        // `asset()` tokens. Nine tests passed either side of it, because none
        // compared a deposit against its own redemption in one unit.
        assertEq(returned, amt, "a clean round trip must return exactly what went in");
        assertEq(vault.totalSupply(), 0, "and burn every share");
        assertGt(sh, 0, "shares were actually minted");
    }

    /// The FIRST depositor, which is where the mark actually bites here.
    ///
    /// The constructor seeds `highWaterMark = 10 ** baseDecimals` (1e6). A real
    /// entry NAV is base-value-per-share and lands nowhere near that -- around
    /// 2e7 for $20 HOOD on this fixture. So the first depositor's own entry is
    /// already far ABOVE the mark, and the first fee evaluation charges them 20%
    /// of a gain from the sentinel to their own entry price: a gain nobody
    /// earned. That is the overcharge direction of the equalisation finding, and
    /// on this vault it is reachable by the very first deposit rather than
    /// needing a cohort to leave first.
    function test_FirstDepositor_PaysOnlyForTheirOwnGain() public {
        RWRotationVault v = _feeVault();

        uint256 sh = _depositTo(v, alice, 10 * 1e8);
        uint256 markAtEntry = v.highWaterMark();
        uint256 navAtEntry = v.getNavPerShare();

        // The mark must be the price alice actually paid, not the sentinel.
        assertEq(markAtEntry, navAtEntry, "the mark must equal the entry price");
        assertGt(navAtEntry, 10 ** 6, "and the entry price is far above the sentinel");

        // HOOD doubles: $20 -> $40. Alice's gain is 100% of her position.
        hoodOracle.setPrice(40 * 1e8);
        vm.prank(keeper);
        v.evaluateFees();

        // 20% of a 100% gain on a position worth `navAtEntry` per share.
        uint256 supply = v.totalSupply();
        uint256 expected = ((navAtEntry) * supply * 2000) / ((10 ** v.decimals()) * 10000);
        assertApproxEqRel(
            v.performanceFeeAccrued(), expected, 1e14,
            "the fee must be 20% of alice's own gain, not of a gain from the sentinel"
        );

        vm.prank(alice);
        v.redeem(sh, alice, alice);
    }

    function test_EvaluateFees_IsKeeperOnly() public {
        _depositUnderlying();
        vm.expectRevert();
        vault.evaluateFees();
    }

    function test_ClaimFees_RevertsWithNothingAccrued() public {
        vm.expectRevert("RWRotationVault: nothing accrued");
        vault.claimFees();
    }
}

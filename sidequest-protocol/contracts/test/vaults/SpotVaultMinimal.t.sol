// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SpotVaultMinimal} from "../../src/vaults/SpotVaultMinimal.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockOracle} from "../mocks/MockOracle.sol";
import {MockSpotAdapter} from "../mocks/MockSpotAdapter.sol";
import {ReceiptRenderer} from "../../src/lib/ReceiptRenderer.sol";

contract SpotVaultMinimalTest is Test {
    MockERC20 wbtc;
    MockERC20 usdc;
    MockOracle oracle;
    MockSpotAdapter adapter;
    SpotVaultMinimal vault;

    address alice = makeAddr("alice");
    address keeper = makeAddr("keeper");

    int256 constant PRICE_50K = 50_000 * 1e8;
    int256 constant PRICE_25K = 25_000 * 1e8;
    uint256 constant TEN_BTC = 10 * 1e8;
    uint256 constant MAX_STALE = 1 hours;

    function setUp() public {
        vm.warp(1_700_000_000);
        wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        oracle = new MockOracle(PRICE_50K, 8);
        adapter = new MockSpotAdapter(address(wbtc), address(usdc), address(oracle));

        vault = new SpotVaultMinimal(
            address(wbtc), address(usdc), address(oracle), MAX_STALE,
            "Zorpha BTC Vault", "sqBTC",
            0, 100, 0,
            address(this), address(this),
            1 hours
        );
        vault.setSwapAdapter(address(adapter));
        vault.grantRole(vault.KEEPER_ROLE(), keeper);
        // The risk-council path was previously untested because setUp never
        // granted the role, so `setCircuitBreaker` reverted with
        // AccessControlUnauthorizedAccount before reaching any assertion
        // (audit finding V-04).
        //
        // KEEPER_ROLE is deliberately NOT granted here: `test_KeeperOnly_Rebalance`
        // depends on this contract being unauthorised. Keeper-gated calls prank
        // as `keeper` instead.
        vault.grantRole(vault.RISK_COUNCIL_ROLE(), address(this));

        wbtc.mint(address(adapter), 1_000 * 1e8);
        usdc.mint(address(adapter), 100_000_000 * 1e6);
        wbtc.mint(alice, TEN_BTC);
    }

    function _deposit() internal returns (uint256 shares) {
        vm.startPrank(alice);
        wbtc.approve(address(vault), TEN_BTC);
        shares = vault.deposit(TEN_BTC, alice);
        vm.stopPrank();
    }

    function test_LongFlat_NAVTracksPnL() public {
        uint256 shares = _deposit();
        assertApproxEqRel(vault.convertToAssets(shares), TEN_BTC, 1e12, "start = 10 BTC");

        vm.prank(keeper);
        vault.rebalanceTo(0);
        assertApproxEqRel(vault.totalAssets(), TEN_BTC, 1e12, "flat preserves BTC value");

        oracle.setPrice(PRICE_25K);
        assertApproxEqRel(vault.totalAssets(), 2 * TEN_BTC, 1e12, "flat through 50% drop = 2x BTC");

        vm.prank(keeper);
        vault.rebalanceTo(10000);
        assertApproxEqRel(wbtc.balanceOf(address(vault)), 2 * TEN_BTC, 1e12, "long: 20 BTC");

        vm.prank(alice);
        uint256 received = vault.redeem(shares, alice, alice);
        assertGt(received, TEN_BTC, "depositor beats HOLD in underlying");
    }

    /// The commitment is a keccak256 over every field of the receipt, so
    /// asserting it as bytes32(0) — as this test previously did — could never
    /// pass. Recomputing it from the library is the assertion that actually
    /// matters: it proves the emitted hash binds the values the vault reported,
    /// which is the whole basis of a verifiable track record.
    function test_RebalanceEmitsEvent_WithCommitment() public {
        _deposit();

        uint16 target = 0;
        uint256 expAssetLeg = 0;
        uint256 expCashLeg = 500_000 * 1e6;
        uint256 expNav = 1e8;
        bytes32 expCommit = ReceiptRenderer.commitment(
            keeper,
            address(vault),
            target,
            expNav,
            expAssetLeg,
            expCashLeg,
            1,
            block.timestamp,
            bytes32(0)
        );

        vm.expectEmit(true, true, true, true, address(vault));
        emit SpotVaultMinimal.Rebalanced(target, expAssetLeg, expCashLeg, expNav, 1, expCommit);
        vm.prank(keeper);
        vault.rebalanceTo(target);

        assertEq(vault.rebalanceCount(), 1, "rebalance count incremented");
    }

    /// A receipt is only useful if the same inputs reproduce the same hash and
    /// different inputs do not. Guards the commitment against becoming a
    /// constant or dropping a field.
    function test_CommitmentIsSensitiveToEveryField() public view {
        bytes32 base = ReceiptRenderer.commitment(
            keeper, address(vault), 5000, 1e8, 1e8, 1e6, 1, 1_700_000_000, bytes32(0)
        );
        assertTrue(base != bytes32(0), "commitment must not be zero");
        assertEq(
            base,
            ReceiptRenderer.commitment(
                keeper, address(vault), 5000, 1e8, 1e8, 1e6, 1, 1_700_000_000, bytes32(0)
            ),
            "same inputs must reproduce the same hash"
        );
        assertTrue(
            base
                != ReceiptRenderer.commitment(
                    keeper, address(vault), 5001, 1e8, 1e8, 1e6, 1, 1_700_000_000, bytes32(0)
                ),
            "target weight must be bound"
        );
        assertTrue(
            base
                != ReceiptRenderer.commitment(
                    keeper, address(vault), 5000, 1e8, 1e8, 1e6, 2, 1_700_000_000, bytes32(0)
                ),
            "nonce must be bound"
        );
        assertTrue(
            base
                != ReceiptRenderer.commitment(
                    alice, address(vault), 5000, 1e8, 1e8, 1e6, 1, 1_700_000_000, bytes32(0)
                ),
            "manager must be bound"
        );
    }

    function test_CircuitBreaker_BlocksDepositsAndRebalance() public {
        _deposit();
        vault.setCircuitBreaker(true);
        assertEq(vault.maxDeposit(alice), 0, "deposits blocked");
        vm.expectRevert(SpotVaultMinimal.CircuitBreakerActive.selector);
        vm.prank(keeper);
        vault.rebalanceTo(10000);
        vault.setCircuitBreaker(false);
        assertEq(vault.maxDeposit(alice), type(uint256).max, "deposits reopen");
    }

    function test_KeeperOnly_Rebalance() public {
        _deposit();
        vm.expectRevert();
        vault.rebalanceTo(0);
        vm.prank(keeper);
        vault.rebalanceTo(0); // should succeed
    }

    function test_RebalanceCountIncrements_AcrossManyRebalances() public {
        _deposit();
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(keeper);
            vault.rebalanceTo(uint16(i * 2000));
        }
        assertEq(vault.rebalanceCount(), 5);
    }

    function test_EmergencyRedeem_HaircutOnZeroNAV() public {
        _deposit();
        oracle.setPrice(0);
        // Stale-oracle path would revert on rebalance; emergency path skips oracle.
        // We simulate a "depositor trapped by zero nav" state by burning cash + transferring out the underlying.
        // This is a smoke test that emergencyRedeem reverts on the empty-vault edge case.
        vm.expectRevert();
        vault.redeemEmergency(1, alice, alice);
    }

    function test_FeeAccrual_BelowHWM_NoAccrual() public {
        _deposit();
        // First rebalance at HWM = 1.0 underlying; nav below should not accrue.
        vm.prank(keeper);
        vault.rebalanceTo(0);
        vm.prank(keeper);
        vault.evaluateFees();
        assertEq(vault.performanceFeeAccrued(), 0, "no fee below HWM");
    }

    function test_BadWeight_Reverts() public {
        _deposit();
        vm.prank(keeper);
        vm.expectRevert(SpotVaultMinimal.BadWeight.selector);
        vault.rebalanceTo(10001);
    }

    function test_StaleOracle_Reverts() public {
        _deposit();
        oracle.setUpdatedAt(block.timestamp - MAX_STALE - 1);
        vm.expectRevert();
        vm.prank(keeper);
        vault.rebalanceTo(0);
    }

    // --- The escape hatch --------------------------------------------------
    //
    // redeemEmergency is the depositor's last resort: it pays a pro-rata share
    // of the ASSET leg only, touching neither the swap venue nor the oracle,
    // and charges the cash leg as a haircut. That independence is the whole
    // point -- a depositor must be able to leave when the market is dry or the
    // price feed is dead, which are exactly the moments they most want to.
    //
    // It had one line of coverage before this: a test named
    // test_EmergencyRedeem_HaircutOnZeroNAV which asserted no haircut, set an
    // oracle price the function never reads, and expected an unspecified
    // revert. Its own comment called it a smoke test. So the last-resort exit
    // for depositor funds was, in practice, untested.

    /// A venue with no depth. Normal redemption has to buy the asset leg back
    /// through it and cannot; the emergency path never asks.
    function test_EmergencyRedeem_WorksWhenTheVenueIsDry() public {
        uint256 shares = _deposit();
        vm.prank(keeper);
        vault.rebalanceTo(5000); // half the book into cash

        uint256 cashLeg = usdc.balanceOf(address(vault));
        assertGt(cashLeg, 0, "the rebalance must have left a cash leg to strand");

        // Repoint at an unfunded venue: a real market that has gone illiquid.
        MockSpotAdapter dry = new MockSpotAdapter(address(wbtc), address(usdc), address(oracle));
        vault.setSwapAdapter(address(dry));

        vm.prank(alice);
        vm.expectRevert();
        vault.redeem(shares, alice, alice);

        uint256 assetLeg = wbtc.balanceOf(address(vault));
        vm.prank(alice);
        uint256 paid = vault.redeemEmergency(shares, alice, alice);

        assertEq(paid, assetLeg, "pays the entire asset leg when sole holder");
        assertEq(vault.totalSupply(), 0, "the position is fully closed");
        assertEq(wbtc.balanceOf(alice), paid, "and the depositor actually has it");
    }

    /// A dead price feed. Rebalancing and normal redemption both read it; the
    /// emergency path does not, and must still pay.
    function test_EmergencyRedeem_WorksWhenTheOracleIsDead() public {
        uint256 shares = _deposit();
        vm.prank(keeper);
        vault.rebalanceTo(5000);

        oracle.setAnswer(0); // InvalidOraclePrice for anything that reads it

        vm.prank(keeper);
        vm.expectRevert();
        vault.rebalanceTo(7000);

        vm.prank(alice);
        vm.expectRevert();
        vault.redeem(shares, alice, alice);

        uint256 assetLeg = wbtc.balanceOf(address(vault));
        vm.prank(alice);
        uint256 paid = vault.redeemEmergency(shares, alice, alice);
        assertEq(paid, assetLeg, "the escape hatch does not need a price");
        assertGt(paid, 0);
    }

    /// The haircut is the cash leg, and it is reported rather than hidden.
    function test_EmergencyRedeem_HaircutIsTheStrandedCashLeg() public {
        uint256 shares = _deposit();
        vm.prank(keeper);
        vault.rebalanceTo(5000);

        uint256 cashLeg = usdc.balanceOf(address(vault));
        uint256 assetLeg = wbtc.balanceOf(address(vault));
        assertGt(cashLeg, 0);

        vm.prank(alice);
        vault.redeemEmergency(shares, alice, alice);

        // The cash never moves. That is the cost of leaving this way, and it
        // stays in the vault rather than being burned or swept.
        assertEq(usdc.balanceOf(address(vault)), cashLeg, "cash leg is stranded, not paid");
        assertEq(usdc.balanceOf(alice), 0, "the depositor gets none of it");
        assertEq(wbtc.balanceOf(alice), assetLeg, "only the asset leg is paid");
    }

    /// Half out, half in: the remaining holder must not be diluted by the
    /// first one's haircut, and must still own their share of what is left.
    function test_EmergencyRedeem_PartialLeavesTheRestIntact() public {
        uint256 shares = _deposit();
        vm.prank(keeper);
        vault.rebalanceTo(5000);

        uint256 assetLegBefore = wbtc.balanceOf(address(vault));
        uint256 half = shares / 2;

        vm.prank(alice);
        uint256 paid = vault.redeemEmergency(half, alice, alice);

        assertApproxEqAbs(paid, assetLegBefore / 2, 1, "pays half the asset leg");
        assertEq(vault.totalSupply(), shares - half, "the rest of the position survives");
        assertApproxEqAbs(
            wbtc.balanceOf(address(vault)), assetLegBefore - paid, 1,
            "the vault keeps exactly what was not paid out"
        );
    }

    /// The cooldown exists so the hatch cannot be used to drain the asset leg
    /// in a loop while the cash leg is stuck.
    function test_EmergencyRedeem_CooldownBlocksAnImmediateSecondExit() public {
        uint256 shares = _deposit();
        vm.prank(keeper);
        vault.rebalanceTo(5000);

        uint256 cooldown = vault.emergencyRedeemCooldown();
        vm.assume(cooldown > 0);

        vm.prank(alice);
        vault.redeemEmergency(shares / 4, alice, alice);

        vm.prank(alice);
        vm.expectRevert();
        vault.redeemEmergency(shares / 4, alice, alice);

        vm.warp(block.timestamp + cooldown + 1);
        vm.prank(alice);
        vault.redeemEmergency(shares / 4, alice, alice);
    }

    /// PINS A DEFECT, and will break when it is fixed. That is the intent.
    ///
    /// `haircut` in EmergencyRedeem is computed as grossOwed - paid, where
    /// grossOwed comes from the ASSET balance alone. So it can only ever equal
    /// the fee share, and the cash leg -- the thing actually forfeited -- never
    /// enters the arithmetic. A depositor who gives up half their position sees
    /// haircut = 0, which is not an omission but an affirmative claim that
    /// nothing was lost.
    ///
    /// Observed on testnet 46630 in tx 0x2baa8c11...0406: 50e18 of asset paid,
    /// 50e18 raw of the cash leg forfeited, haircut emitted as 0.
    ///
    /// See docs/FINDINGS-EMERGENCY-EXIT.md. When option 1 or 3 there is taken,
    /// this test should fail and be rewritten to assert the correct figure.
    function test_EmergencyRedeem_HaircutUnderReportsTheStrandedCash() public {
        uint256 shares = _deposit();
        vm.prank(keeper);
        vault.rebalanceTo(5000);

        uint256 cashForfeited = usdc.balanceOf(address(vault));
        assertGt(cashForfeited, 0, "the rebalance must leave a cash leg to forfeit");
        assertEq(vault.performanceFeeAccrued(), 0, "no fee, so any haircut can only be the cash");

        vm.recordLogs();
        vm.prank(alice);
        vault.redeemEmergency(shares, alice, alice);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 reportedHaircut = type(uint256).max;
        bytes32 sig = keccak256("EmergencyRedeem(address,address,address,uint256,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) {
                (, , reportedHaircut) = abi.decode(logs[i].data, (uint256, uint256, uint256));
            }
        }
        assertTrue(reportedHaircut != type(uint256).max, "EmergencyRedeem was not emitted");

        assertEq(reportedHaircut, 0, "today it reports zero -- this is the defect");
        assertEq(
            usdc.balanceOf(address(vault)), cashForfeited,
            "while this much cash is stranded in the vault, owned by nobody"
        );
    }

    /// The stranded cash has no way out. Confirms there is no rescue path, so
    /// the forfeited balance is orphaned rather than merely mis-reported.
    function test_EmergencyRedeem_StrandedCashCannotBeRecovered() public {
        uint256 shares = _deposit();
        vm.prank(keeper);
        vault.rebalanceTo(5000);
        uint256 stranded = usdc.balanceOf(address(vault));

        vm.prank(alice);
        vault.redeemEmergency(shares, alice, alice);

        assertEq(vault.totalSupply(), 0, "no shares remain");
        assertEq(usdc.balanceOf(address(vault)), stranded, "the cash remains");

        // claimFees is the only admin path that moves value out of this vault,
        // and it refuses outright when nothing has accrued -- so it is not even
        // a no-op that could be pointed at the cash. There is no path.
        assertEq(vault.performanceFeeAccrued(), 0);
        vm.expectRevert("SpotVaultMinimal: nothing accrued");
        vault.claimFees();
        assertEq(usdc.balanceOf(address(vault)), stranded, "still stranded, permanently");
    }
}

/// @notice The performance fee, which had no real coverage.
///
///         The suite's main vault is built with `performanceFeeBps = 0`, so
///         every existing fee assertion is vacuous: `test_FeeAccrual_BelowHWM_NoAccrual`
///         asserts zero accrual on a vault that cannot accrue. Nothing proved the
///         fee is ever charged, and nothing proved what happens to the mark when
///         the vault empties.
contract SpotVaultFeeTest is Test {
    MockERC20 wbtc;
    MockERC20 usdc;
    MockOracle oracle;
    MockSpotAdapter adapter;
    SpotVaultMinimal vault;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address keeper = makeAddr("keeper");

    int256 constant PRICE_50K = 50_000 * 1e8;
    int256 constant PRICE_25K = 25_000 * 1e8;
    uint256 constant TEN_BTC = 10 * 1e8;

    function setUp() public {
        vm.warp(1_700_000_000);
        wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        oracle = new MockOracle(PRICE_50K, 8);
        adapter = new MockSpotAdapter(address(wbtc), address(usdc), address(oracle));

        vault = new SpotVaultMinimal(
            address(wbtc), address(usdc), address(oracle), 1 hours,
            "Zorpha BTC Vault", "sqBTC",
            0, 100, 2000,                       // 20% performance fee, unlike the main suite
            address(this), address(this),
            1 hours
        );
        vault.setSwapAdapter(address(adapter));
        vault.grantRole(vault.KEEPER_ROLE(), keeper);

        wbtc.mint(address(adapter), 1_000 * 1e8);
        usdc.mint(address(adapter), 100_000_000 * 1e6);
        wbtc.mint(alice, TEN_BTC);
        wbtc.mint(bob, TEN_BTC);
    }

    function _depositFrom(address who) internal returns (uint256 shares) {
        vm.startPrank(who);
        wbtc.approve(address(vault), TEN_BTC);
        shares = vault.deposit(TEN_BTC, who);
        vm.stopPrank();
    }

    /// @dev Sitting in cash through a 50% price fall doubles the BTC-denominated
    ///      NAV, which is the only way to manufacture a gain here without
    ///      touching the vault's own accounting.
    function _doubleTheNav() internal {
        vm.prank(keeper);
        vault.rebalanceTo(0);
        oracle.setPrice(PRICE_25K);
        vm.prank(keeper);
        vault.evaluateFees();
    }

    /// The baseline the suite never had: a gain is actually charged for.
    function test_FeeAccrual_AboveHWM_Charges() public {
        _depositFrom(alice);
        assertEq(vault.performanceFeeAccrued(), 0, "nothing owed before the gain");

        _doubleTheNav();

        // 100% gain on 10 BTC, 20% of it = 2 BTC.
        assertApproxEqRel(vault.performanceFeeAccrued(), 2 * 1e8, 1e12, "20% of a 10 BTC gain");
        assertApproxEqRel(vault.highWaterMark(), 2 * 1e8, 1e12, "mark ratcheted to the new NAV");
    }

    /// The bug. Once the vault empties, the mark is left at the departed
    /// depositor's high point, and the next depositor rides free all the way
    /// back up to it.
    function test_FeeAccrual_AfterEmptying_ChargesTheNextDepositor() public {
        uint256 aliceShares = _depositFrom(alice);
        _doubleTheNav();
        uint256 chargedToAlice = vault.performanceFeeAccrued();
        assertGt(chargedToAlice, 0, "alice was charged for her gain");

        vm.prank(alice);
        vault.redeem(aliceShares, alice, alice);
        assertEq(vault.totalSupply(), 0, "vault is empty");

        // Bob enters the empty vault. Whatever the mark says, he is buying in at
        // the sentinel price, so his first basis point of gain is his own.
        oracle.setPrice(PRICE_50K);
        _depositFrom(bob);
        assertApproxEqRel(
            vault.highWaterMark(), vault.getNavPerShare(), 1e12,
            "the mark must follow the price bob actually paid, not alice's high point"
        );

        uint256 before = vault.performanceFeeAccrued();
        _doubleTheNav();
        assertGt(
            vault.performanceFeeAccrued(), before,
            "bob doubled his money; the vault must charge him for it"
        );
    }

    /// A separate defect, surfaced by the test above and NOT fixed by the
    /// first-entry mark: an unclaimed performance fee is a claim denominated in
    /// asset units, but it is backed by whichever leg the vault happens to hold.
    /// Let the price move against that leg and the claim outgrows its backing,
    /// and the shortfall is charged to whoever deposits next.
    function test_UnclaimedFee_DilutesTheNextDepositor() public {
        uint256 aliceShares = _depositFrom(alice);
        _doubleTheNav();                       // fee accrues in BTC terms, at 25k
        uint256 claim = vault.performanceFeeAccrued();

        vm.prank(alice);
        vault.redeem(aliceShares, alice, alice);
        assertEq(vault.totalSupply(), 0, "empty, but still carrying the fee claim");

        // The claim was struck at 25k and is held as cash. Back at 50k that cash
        // buys half as much of the asset, so the claim now exceeds what backs it.
        oracle.setPrice(PRICE_50K);
        uint256 backing = vault.grossValue();
        assertLt(backing, claim, "the fee claim now outgrows the value behind it");
        assertEq(vault.totalAssets(), 0, "and totalAssets floors at zero, hiding it");

        // Bob deposits into that. Nothing warns him.
        uint256 bobShares = _depositFrom(bob);
        uint256 bobValue = vault.convertToAssets(bobShares);
        assertLt(bobValue, TEN_BTC, "bob is worth less than he paid the instant he entered");

        // The loss is exactly the uncovered part of somebody else's fee.
        assertApproxEqAbs(
            TEN_BTC - bobValue, claim - backing, 2,
            "bob's loss is the shortfall on alice's unclaimed fee"
        );
        assertApproxEqRel(bobValue, 9 * 1e8, 1e12, "10 BTC in, 9 BTC held: a 10% haircut on entry");
    }
}

/// The fee write-down is the only lever that can reconcile a claim which has
/// outgrown its backing (docs/FINDINGS-FEE-CLAIM-BACKING.md), and it used to
/// emit nothing at all.
contract SpotVaultWriteDownTest is Test {
    MockERC20 wbtc;
    MockERC20 usdc;
    MockOracle oracle;
    MockSpotAdapter adapter;
    SpotVaultMinimal vault;

    address alice = makeAddr("alice");
    address keeper = makeAddr("keeper");

    event AccruedFeesWrittenDown(uint256 amount, uint256 remaining);

    function setUp() public {
        vm.warp(1_700_000_000);
        wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        oracle = new MockOracle(50_000 * 1e8, 8);
        adapter = new MockSpotAdapter(address(wbtc), address(usdc), address(oracle));
        vault = new SpotVaultMinimal(
            address(wbtc), address(usdc), address(oracle), 1 hours,
            "Zorpha BTC Vault", "sqBTC", 0, 100, 2000,
            address(this), address(this), 1 hours
        );
        vault.setSwapAdapter(address(adapter));
        vault.grantRole(vault.KEEPER_ROLE(), keeper);
        wbtc.mint(address(adapter), 1_000 * 1e8);
        usdc.mint(address(adapter), 100_000_000 * 1e6);
        wbtc.mint(alice, 10 * 1e8);
    }

    function _accrueAFee() internal returns (uint256) {
        vm.startPrank(alice);
        wbtc.approve(address(vault), 10 * 1e8);
        vault.deposit(10 * 1e8, alice);
        vm.stopPrank();
        vm.prank(keeper);
        vault.rebalanceTo(0);
        oracle.setPrice(25_000 * 1e8);
        vm.prank(keeper);
        vault.evaluateFees();
        return vault.performanceFeeAccrued();
    }

    function test_WriteDown_IsObservable() public {
        uint256 accrued = _accrueAFee();
        assertGt(accrued, 0, "a fee to write down");

        uint256 amount = accrued / 4;
        vm.expectEmit(true, true, true, true);
        emit AccruedFeesWrittenDown(amount, accrued - amount);
        vault.writeDownAccruedFees(amount);

        assertEq(vault.performanceFeeAccrued(), accrued - amount, "claim reduced");
    }

    function test_WriteDown_RejectsZeroAndOvershoot() public {
        uint256 accrued = _accrueAFee();
        vm.expectRevert("SpotVaultMinimal: bad write-down");
        vault.writeDownAccruedFees(0);
        vm.expectRevert("SpotVaultMinimal: bad write-down");
        vault.writeDownAccruedFees(accrued + 1);
    }

    function test_WriteDown_AdminOnly() public {
        _accrueAFee();
        vm.prank(alice);
        vm.expectRevert();
        vault.writeDownAccruedFees(1);
    }
}

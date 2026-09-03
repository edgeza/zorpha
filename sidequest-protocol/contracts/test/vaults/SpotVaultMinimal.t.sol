// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SpotVaultMinimal} from "../../src/vaults/SpotVaultMinimal.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockOracle} from "../mocks/MockOracle.sol";
import {MockSpotAdapter} from "../mocks/MockSpotAdapter.sol";
import {ReceiptRenderer} from "../../src/lib/ReceiptRenderer.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

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
        // This contract was never granted KEEPER_ROLE. Named so the test cannot
        // pass on a bad weight or a stale oracle instead of the role check.
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), vault.KEEPER_ROLE()
            )
        );
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

    /// A vault holding NOTHING while shares are still outstanding.
    ///
    /// This test used to be vacuous, and its own comments described setup it
    /// did not perform: "we simulate a depositor trapped by zero nav by
    /// burning cash + transferring out the underlying" -- it did neither -- and
    /// "a smoke test that emergencyRedeem reverts on the empty-vault edge
    /// case", against a vault alice had just funded.
    ///
    /// What it actually asserted was ERC20InsufficientAllowance(testContract,
    /// 0, 1): it called redeemEmergency with no prank, so it proved only that
    /// a stranger cannot redeem alice's shares. True, unrelated to the name,
    /// and already guaranteed by ERC-4626. A bare `vm.expectRevert()` let it
    /// sit there passing.
    ///
    /// The state it MEANT to describe is real and worth covering -- it is what
    /// the original spot vault ended up in and was written off for, after the
    /// 1:1 stub adapter corrupted its cash leg. So this now actually drains the
    /// vault and asserts what the emergency exit does about it.
    function test_EmergencyRedeem_OnADrainedVault() public {
        uint256 shares = _deposit();

        // Drain both legs. MockERC20.burn is permissionless, which is the only
        // way to reach a state the vault cannot reach by itself.
        wbtc.burn(address(vault), wbtc.balanceOf(address(vault)));
        usdc.burn(address(vault), usdc.balanceOf(address(vault)));
        assertEq(vault.grossValue(), 0, "setup: the vault must hold nothing");
        assertGt(vault.totalSupply(), 0, "setup: but shares must remain outstanding");

        // Emergency exit pays in kind and pro-rata, so with nothing to pay it
        // pays nothing -- and must NOT revert, or the depositor is trapped
        // holding shares in a vault that cannot even acknowledge them.
        vm.prank(alice);
        (uint256 paid, uint256 paidCash) = vault.redeemEmergency(shares, alice, alice);

        assertEq(paid, 0, "nothing to pay from an empty vault");
        assertEq(paidCash, 0, "and nothing on the cash leg either");
        assertEq(vault.balanceOf(alice), 0, "but the shares must still be burned");
        assertEq(vault.totalSupply(), 0, "so the vault is left clean rather than stuck");
    }

    /// The assertion that would have caught the worst bug in this codebase on
    /// day one: put N of `asset()` in, take every share back out, count N of
    /// `asset()` returned.
    ///
    /// `RWRotationVault` returned 2 HOOD for 10 deposited, because its
    /// `totalAssets()` was denominated in a different token from `asset()` and
    /// no conversion was overridden. Nine of its tests passed either side of
    /// that, all of them internally consistent in either base units or shares.
    /// Only a single-unit round trip shows it. See
    /// docs/FINDINGS-ROTATION-UNITS.md.
    ///
    /// This vault is believed consistent. Nothing pinned it.
    function test_Units_DepositRedeemRoundTrip() public {
        uint256 before_ = wbtc.balanceOf(alice);
        uint256 shares = _deposit();
        vm.prank(alice);
        vault.redeem(shares, alice, alice);

        assertEq(
            wbtc.balanceOf(alice), before_,
            "a clean round trip must return exactly what went in"
        );
        assertEq(vault.totalSupply(), 0, "and burn every share");
        assertGt(shares, 0, "shares were actually minted");
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
        vm.expectRevert(
            abi.encodeWithSelector(
                SpotVaultMinimal.StaleOracle.selector,
                block.timestamp - MAX_STALE - 1,
                block.timestamp
            )
        );
        vm.prank(keeper);
        vault.rebalanceTo(0);
    }

    // --- The escape hatch --------------------------------------------------
    //
    // redeemEmergency is the depositor's last resort: it pays a pro-rata share
    // of BOTH legs in kind, touching neither the swap venue nor the oracle.
    // That independence is the whole point -- a depositor must be able to leave
    // when the market is dry or the price feed is dead, which are exactly the
    // moments they most want to.
    //
    // It used to pay the asset leg only and forfeit the cash. See
    // docs/FINDINGS-EMERGENCY-EXIT.md: the forfeited cash was permanently
    // stranded (no sweep exists on this contract), it went on inflating
    // totalAssets() and so mispriced the next depositor, and the receipt
    // reported a haircut of zero on a total forfeiture. Paying in kind needs no
    // oracle and no venue either, so the independence that justified the
    // forfeiture never actually required it.
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
        // The fresh adapter holds neither leg, so the ordinary redeem cannot
        // settle its swap -- which is the precondition for the emergency exit
        // exercised below, not an incidental failure.
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(dry), 0, 500_000_000
            )
        );
        vault.redeem(shares, alice, alice);

        uint256 assetLeg = wbtc.balanceOf(address(vault));
        vm.prank(alice);
        (uint256 paid, uint256 paidCash) = vault.redeemEmergency(shares, alice, alice);

        assertEq(paid, assetLeg, "pays the entire asset leg when sole holder");
        assertEq(paidCash, cashLeg, "and the entire cash leg, in kind");
        assertEq(vault.totalSupply(), 0, "the position is fully closed");
        assertEq(wbtc.balanceOf(alice), paid, "and the depositor actually has it");
        assertEq(usdc.balanceOf(alice), paidCash, "both legs really arrived");
        assertEq(usdc.balanceOf(address(vault)), 0, "nothing is left stranded");
    }

    /// A dead price feed. Rebalancing and normal redemption both read it; the
    /// emergency path does not, and must still pay.
    function test_EmergencyRedeem_WorksWhenTheOracleIsDead() public {
        uint256 shares = _deposit();
        vm.prank(keeper);
        vault.rebalanceTo(5000);

        oracle.setAnswer(0); // InvalidOraclePrice for anything that reads it

        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(SpotVaultMinimal.InvalidOraclePrice.selector, int256(0))
        );
        vault.rebalanceTo(7000);

        vm.prank(alice);
        // redeem reads the oracle to price the cash leg, so a zero answer stops
        // the ordinary exit too -- which is the whole reason redeemEmergency
        // exists and is exercised immediately below.
        vm.expectRevert(
            abi.encodeWithSelector(SpotVaultMinimal.InvalidOraclePrice.selector, int256(0))
        );
        vault.redeem(shares, alice, alice);

        uint256 assetLeg = wbtc.balanceOf(address(vault));
        uint256 cashLeg = usdc.balanceOf(address(vault));
        vm.prank(alice);
        (uint256 paid, uint256 paidCash) = vault.redeemEmergency(shares, alice, alice);
        assertEq(paid, assetLeg, "the escape hatch does not need a price");
        assertEq(paidCash, cashLeg, "and pays the cash leg without one either");
        assertGt(paid, 0);
        assertGt(paidCash, 0);
    }

    /// Nothing is stranded, and nothing is confiscated. This test asserted the
    /// opposite until the forfeiture was removed: it required the cash leg to
    /// stay in the vault and the depositor to receive none of it.
    function test_EmergencyRedeem_PaysBothLegsAndStrandsNothing() public {
        uint256 shares = _deposit();
        vm.prank(keeper);
        vault.rebalanceTo(5000);

        uint256 cashLeg = usdc.balanceOf(address(vault));
        uint256 assetLeg = wbtc.balanceOf(address(vault));
        assertGt(cashLeg, 0, "there must be a cash leg for this to be a test");

        vm.prank(alice);
        vault.redeemEmergency(shares, alice, alice);

        assertEq(usdc.balanceOf(alice), cashLeg, "the depositor receives the cash leg");
        assertEq(wbtc.balanceOf(alice), assetLeg, "and the asset leg");
        assertEq(usdc.balanceOf(address(vault)), 0, "the vault keeps no orphaned cash");
        assertEq(wbtc.balanceOf(address(vault)), 0, "nor any orphaned asset");

        // The residue used to price the next depositor's entry off a balance
        // nobody owned. There is no residue now.
        assertEq(vault.grossValue(), 0, "and so cannot misprice whoever comes next");
    }

    /// The receipt's haircut field read zero on a total forfeiture, which was an
    /// affirmative claim that nothing had been given up. With both legs paid it
    /// can only be the fee, so it means what it says.
    function test_EmergencyRedeem_ReceiptReportsOnlyTheFee() public {
        uint256 shares = _deposit();
        vm.prank(keeper);
        vault.rebalanceTo(5000);

        vm.recordLogs();
        vm.prank(alice);
        (uint256 paid, uint256 paidCash) = vault.redeemEmergency(shares, alice, alice);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != keccak256(
                "EmergencyRedeem(address,address,address,uint256,uint256,uint256,uint256)"
            )) continue;
            (uint256 burned, uint256 ePaid, uint256 ePaidCash, uint256 haircut) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
            assertEq(burned, shares, "shares burned");
            assertEq(ePaid, paid, "asset leg matches the return value");
            assertEq(ePaidCash, paidCash, "cash leg is in the receipt at all");
            // performanceFee is 0 on this vault, so there is nothing to withhold.
            assertEq(haircut, 0, "no fee accrued, so nothing withheld -- and nothing hidden");
            found = true;
        }
        assertTrue(found, "the receipt must be emitted");
    }

    /// Half out, half in: the remaining holder must not be diluted by the
    /// first one's haircut, and must still own their share of what is left.
    function test_EmergencyRedeem_PartialLeavesTheRestIntact() public {
        uint256 shares = _deposit();
        vm.prank(keeper);
        vault.rebalanceTo(5000);

        uint256 assetLegBefore = wbtc.balanceOf(address(vault));
        uint256 half = shares / 2;

        uint256 cashLegBefore = usdc.balanceOf(address(vault));
        vm.prank(alice);
        (uint256 paid, uint256 paidCash) = vault.redeemEmergency(half, alice, alice);

        assertApproxEqAbs(paid, assetLegBefore / 2, 1, "pays half the asset leg");
        assertApproxEqAbs(paidCash, cashLegBefore / 2, 1, "and half the cash leg");
        assertApproxEqAbs(
            usdc.balanceOf(address(vault)), cashLegBefore - paidCash, 1,
            "the remaining holder keeps their share of the cash, undiluted"
        );
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

        // The cooldown, not the oracle. nextAllowed is derived from the vault's
        // own state rather than recomputed from constants, so a change to the
        // cooldown does not silently make this pass against the wrong number.
        //
        // And read BEFORE the prank. I put these two lines AFTER it first time,
        // in the same edit as a comment warning not to -- both are external
        // calls, so they consumed the prank and the call under test ran as this
        // contract. It still passed, because the cooldown is keyed on `owner`
        // rather than msg.sender, which is exactly the kind of accident that
        // makes a consumed prank hard to notice.
        uint256 nextAllowed =
            vault.lastEmergencyRedeemAt(alice) + vault.emergencyRedeemCooldown();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                SpotVaultMinimal.EmergencyCooldownActive.selector, nextAllowed
            )
        );
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
    /// This test used to assert the defect: a reported haircut of zero while the
    /// entire cash leg sat forfeited in the vault. Now that both legs are paid,
    /// a haircut of zero is a true statement, and the assertion is that the cash
    /// went to the depositor rather than nowhere.
    function test_EmergencyRedeem_HaircutOfZeroIsNowTrue() public {
        uint256 shares = _deposit();
        vm.prank(keeper);
        vault.rebalanceTo(5000);

        uint256 cashLeg = usdc.balanceOf(address(vault));
        assertGt(cashLeg, 0, "the rebalance must leave a cash leg");
        assertEq(vault.performanceFeeAccrued(), 0, "no fee, so any haircut can only be the cash");

        vm.recordLogs();
        vm.prank(alice);
        vault.redeemEmergency(shares, alice, alice);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 reportedHaircut = type(uint256).max;
        uint256 reportedCash;
        bytes32 sig = keccak256(
            "EmergencyRedeem(address,address,address,uint256,uint256,uint256,uint256)"
        );
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) {
                (, , reportedCash, reportedHaircut) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
            }
        }
        assertTrue(reportedHaircut != type(uint256).max, "EmergencyRedeem was not emitted");

        // Zero, and now truthfully so: nothing was withheld because nothing was.
        assertEq(reportedHaircut, 0, "no fee accrued, so nothing withheld");
        assertEq(reportedCash, cashLeg, "and the receipt names the cash leg it paid");
        assertEq(usdc.balanceOf(alice), cashLeg, "which the depositor received");
        assertEq(usdc.balanceOf(address(vault)), 0, "leaving nothing owned by nobody");
    }

    /// This test used to prove the forfeited cash was orphaned: no sweep, no
    /// rescue, and claimFees refusing outright, so the balance was stuck for the
    /// life of the contract. The absence of a rescue path is still true and still
    /// worth pinning -- what changed is that there is no longer anything for it
    /// to rescue.
    function test_EmergencyRedeem_LeavesNothingNeedingRescue() public {
        uint256 shares = _deposit();
        vm.prank(keeper);
        vault.rebalanceTo(5000);
        uint256 cashLeg = usdc.balanceOf(address(vault));
        assertGt(cashLeg, 0, "there must be a cash leg for this to mean anything");

        vm.prank(alice);
        vault.redeemEmergency(shares, alice, alice);

        assertEq(vault.totalSupply(), 0, "no shares remain");
        assertEq(usdc.balanceOf(address(vault)), 0, "and no cash remains either");
        assertEq(wbtc.balanceOf(address(vault)), 0, "nor any asset");

        // There is still no rescue path, deliberately: claimFees is the only
        // admin route value can leave by and it refuses when nothing accrued. An
        // empty vault needing no rescue is a better outcome than a rescue
        // function nobody audited.
        assertEq(vault.performanceFeeAccrued(), 0);
        vm.expectRevert("SpotVaultMinimal: nothing accrued");
        vault.claimFees();
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

    /// A separate defect from the mark, surfaced by the test above: an unclaimed
    /// performance fee is a claim denominated in asset units, backed by whichever
    /// leg the vault happens to hold. Let the price move against that leg and the
    /// claim outgrows its backing.
    ///
    /// It used to cost the next depositor 10% of their deposit, silently.
    /// `_reconcileFeeClaimWhenEmpty` caps the claim at its backing while the
    /// vault is empty, which is the only window where the harm is possible --
    /// with shareholders present the gap is priced into the share they buy.
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

        // Bob deposits into that. The claim is reconciled first, so he is whole.
        uint256 bobShares = _depositFrom(bob);
        uint256 bobValue = vault.convertToAssets(bobShares);

        assertEq(bobValue, TEN_BTC, "bob holds exactly what he paid");
        assertLe(
            vault.performanceFeeAccrued(), backing,
            "the claim was capped at what actually backed it"
        );

        // And the write-down is observable rather than silent.
        assertEq(
            vault.performanceFeeAccrued(), backing,
            "capped to the backing exactly, not to zero: the covered part survives"
        );
    }

    /// The cap must not fire while shareholders exist. There the divergence is
    /// already priced into the share, and writing the claim down would hand the
    /// fee recipient's money to whoever happens to be holding.
    function test_UnclaimedFee_CapDoesNotFireWhileHeld() public {
        _depositFrom(alice);
        _doubleTheNav();
        uint256 claim = vault.performanceFeeAccrued();
        assertGt(claim, 0, "a claim exists");

        // Move the price against the leg the fee was struck in, without emptying.
        oracle.setPrice(PRICE_50K);
        vm.prank(keeper);
        vault.evaluateFees();

        assertEq(
            vault.performanceFeeAccrued(), claim,
            "claim untouched while alice still holds: the cap is empty-vault only"
        );
        assertGt(vault.totalSupply(), 0, "and she does still hold");
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
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, bytes32(0)
            )
        );
        vault.writeDownAccruedFees(1);
    }
}

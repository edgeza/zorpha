// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
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
}

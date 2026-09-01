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

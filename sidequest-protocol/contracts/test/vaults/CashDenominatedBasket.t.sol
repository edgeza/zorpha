// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {RWRotationVault} from "../../src/vaults/RWRotationVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockOracle} from "../mocks/MockOracle.sol";

/// @notice A basket may hold the base asset itself, and that member is worth
///         exactly itself.
///
///         This is the shape a multi-asset fund wants: `asset()` is `tokens[0]`,
///         so a basket whose first member IS the base asset is denominated in
///         the stablecoin. Depositors pay in and are redeemed in dollars, and
///         the manager allocates across cash plus risk assets. Nothing in the
///         constructor forbids it, which is why it is worth pinning.
///
///         The bug this guards is quiet. `tokenToBase` marks every holding at
///         its USD price, so a cash sleeve priced through a USDG/USD feed is
///         marked at whatever that feed says while NAV is denominated in USDG.
///         The feed carries a 0.5% deviation threshold, so the unit of account
///         could sit half a percent away from itself and every deposit and
///         redemption would clear at the wrong price -- with nothing reverting.
contract CashDenominatedBasketTest is Test {
    MockERC20 cash;
    MockERC20 equity;
    MockOracle cashFeed;
    MockOracle equityFeed;
    RWRotationVault vault;

    function setUp() public {
        cash = new MockERC20("Global Dollar", "USDG", 6);
        equity = new MockERC20("Apple", "AAPL", 18);

        // Deliberately OFF peg, and inside the feed's own 0.5% deviation band,
        // so it is a price the real feed could legitimately be reporting.
        cashFeed = new MockOracle(int256(99_500_000), 8); // $0.995
        equityFeed = new MockOracle(int256(250 * 1e8), 8);

        address[] memory tokens = new address[](2);
        tokens[0] = address(cash);
        tokens[1] = address(equity);

        address[] memory oracles = new address[](2);
        oracles[0] = address(cashFeed);
        oracles[1] = address(equityFeed);

        uint16[] memory weights = new uint16[](2);
        weights[0] = 5000;
        weights[1] = 5000;

        vault = new RWRotationVault(
            address(cash), tokens, oracles, 1 hours, weights,
            "Zorpha Fund", "zqFUND", 0, address(this), address(this)
        );
    }

    function test_TheVaultIsDenominatedInCash() public view {
        assertEq(vault.asset(), address(cash), "asset() should be the stablecoin");
    }

    /// The whole point: a dollar is one dollar measured in dollars, whatever a
    /// feed says about it in USD.
    function test_CashConvertsOneForOneRegardlessOfItsFeed() public view {
        assertEq(vault.tokenToBase(0, 1_000_000), 1_000_000);
        assertEq(vault.baseToToken(0, 1_000_000), 1_000_000);
    }

    /// Pinned against the pre-fix behaviour, which would have marked 1,000 USDG
    /// at 995 and shorted every depositor by 0.5%.
    function test_ItDoesNotMarkCashThroughItsUsdFeed() public view {
        uint256 mismarked = (1_000_000 * (10 ** 6) * 99_500_000) / ((10 ** 6) * (10 ** 8));
        assertEq(mismarked, 995_000, "the old formula is what this test is about");
        assertTrue(vault.tokenToBase(0, 1_000_000) != mismarked, "cash is still mismarked");
    }

    /// A moving cash feed must not move NAV. If it can, the vault is repricing
    /// its own unit of account.
    function test_ADriftingCashFeedDoesNotMoveTheCashLeg() public {
        uint256 before_ = vault.tokenToBase(0, 5_000_000);
        cashFeed.setPrice(int256(100_400_000)); // $1.004, the other side of the band
        assertEq(vault.tokenToBase(0, 5_000_000), before_, "NAV moved with the cash feed");
    }

    /// The risk sleeve must still be priced. A blanket short circuit would have
    /// broken the thing the basket exists for.
    function test_TheRiskLegIsStillPricedByItsOracle() public view {
        // 1 AAPL (18dp) at $250 -> 250 USDG (6dp)
        assertEq(vault.tokenToBase(1, 1e18), 250 * 1e6);
    }

    function test_AStaleCashFeedDoesNotHaltTheCashLeg() public {
        // Cash needs no price, so its feed ageing out must not matter.
        cashFeed.setUpdatedAt(1);
        vm.warp(block.timestamp + 30 days);
        assertEq(vault.tokenToBase(0, 1_000_000), 1_000_000);
    }
}

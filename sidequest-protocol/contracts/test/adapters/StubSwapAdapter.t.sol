// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StubSwapAdapter} from "../../src/adapters/RobinhoodChainRouterAdapter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockOracle} from "../mocks/MockOracle.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// The testnet swap stub, which used to corrupt every vault it touched.
///
/// It returned `amountIn` unchanged -- 1:1 on RAW units, ignoring decimals and
/// price. Selling 50e18 of an 18dp equity paid back 50e18 raw units of a 6dp
/// stable: fifty trillion nominal dollars. SpotVaultMinimal.grossValue()
/// denominates both legs in asset units, so on testnet 46630 a single rebalance
/// took grossValue from 1e20 to 2e29 and the vault could afterwards be neither
/// rebalanced nor emptied.
///
/// Nothing tested it. The unit suite used test/mocks/MockSpotAdapter.sol, which
/// had the correct oracle-priced maths all along -- so the tests were green
/// against a faithful double while the deploy default destroyed vaults. These
/// tests exist so the fixture is held to the same standard as its mock.
contract StubSwapAdapterTest is Test {
    MockERC20 equity;   // 18 decimals
    MockERC20 stable;   // 6 decimals
    MockOracle oracle;  // 8 decimals
    StubSwapAdapter adapter;

    uint256 constant PRICE_USD = 250;

    function setUp() public {
        equity = new MockERC20("Test Apple", "tAAPL", 18);
        stable = new MockERC20("Test Global Dollar", "tUSDG", 6);
        // MockOracle takes (answer, decimals) in that order.
        oracle = new MockOracle(int256(PRICE_USD * 1e8), 8);
        adapter = new StubSwapAdapter(address(equity), address(stable), address(oracle), address(this));
        adapter.grantRole(adapter.VAULT_ROLE(), address(this));

        // Pays out of its own balance, so it needs both legs.
        equity.mint(address(adapter), 1_000_000e18);
        stable.mint(address(adapter), 1_000_000_000e6);
    }

    /// The regression. 1 equity at $250 must return 250 stable, not 1e18 of it.
    function test_SellEquity_PaysStableAtOraclePrice() public {
        equity.mint(address(this), 1e18);
        equity.approve(address(adapter), 1e18);

        uint256 out = adapter.swap(address(equity), address(stable), 1e18, 0);

        assertEq(out, PRICE_USD * 1e6, "1 equity at $250 must be 250 stable, 6dp");
        assertEq(stable.balanceOf(address(this)), PRICE_USD * 1e6);
    }

    /// The exact trade that bricked the testnet vault: 50 equity for 12,500
    /// stable. The old stub returned 5e19 -- fifty trillion nominal dollars.
    function test_TheTradeThatBrickedTheTestnetVault() public {
        equity.mint(address(this), 50e18);
        equity.approve(address(adapter), 50e18);

        uint256 out = adapter.swap(address(equity), address(stable), 50e18, 0);

        assertEq(out, 12_500e6, "50 equity at $250 is 12,500 stable");
        assertLt(out, 50e18, "the old stub returned 50e18 here, 4e12 times too much");
    }

    function test_BuyEquity_CostsStableAtOraclePrice() public {
        stable.mint(address(this), PRICE_USD * 1e6);
        stable.approve(address(adapter), PRICE_USD * 1e6);

        uint256 out = adapter.swap(address(stable), address(equity), PRICE_USD * 1e6, 0);

        assertEq(out, 1e18, "$250 of stable must buy 1 whole equity");
    }

    /// A round trip must not manufacture or destroy value beyond rounding.
    /// The old stub turned one equity into 1e18 stable and back into 1e18
    /// equity -- a 1e18x gain per lap, mintable indefinitely.
    function testFuzz_RoundTripIsValuePreserving(uint96 amount) public {
        vm.assume(amount > 1e12 && amount < 100_000e18);
        equity.mint(address(this), amount);

        equity.approve(address(adapter), amount);
        uint256 cashOut = adapter.swap(address(equity), address(stable), amount, 0);

        stable.approve(address(adapter), cashOut);
        uint256 back = adapter.swap(address(stable), address(equity), cashOut, 0);

        assertLe(back, amount, "a round trip must never return more than it took");
        // The stable leg has 6 decimals against the equity's 18, so the trip
        // loses whatever the coarser leg cannot represent. That floor is the
        // decimal gap, not a bug: 1e18 / (1e6/250) per unit of price.
        uint256 floorLoss = 1e12 * PRICE_USD;
        assertGe(back + floorLoss, amount, "lost more than the decimal gap explains");
    }

    function test_UnsupportedPairReverts() public {
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        vm.expectRevert(
            abi.encodeWithSelector(
                StubSwapAdapter.UnsupportedPair.selector, address(other), address(stable)
            )
        );
        adapter.swap(address(other), address(stable), 1e18, 0);
    }

    /// Refuse rather than under-deliver, and name the adapter while doing it.
    function test_UnderMinOutReverts() public {
        equity.mint(address(this), 1e18);
        equity.approve(address(adapter), 1e18);
        uint256 impossible = PRICE_USD * 1e6 + 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                StubSwapAdapter.StubSlippage.selector, PRICE_USD * 1e6, impossible
            )
        );
        adapter.swap(address(equity), address(stable), 1e18, impossible);
    }

    function test_NonZeroPriceRequired() public {
        oracle.setAnswer(0);
        equity.mint(address(this), 1e18);
        equity.approve(address(adapter), 1e18);

        vm.expectRevert(abi.encodeWithSelector(StubSwapAdapter.BadOraclePrice.selector, int256(0)));
        adapter.swap(address(equity), address(stable), 1e18, 0);
    }

    /// Only the vault may trade. Without this the adapter is a free faucet for
    /// anyone willing to send one leg.
    function test_OnlyVaultRoleCanSwap() public {
        address stranger = makeAddr("stranger");
        equity.mint(stranger, 1e18);
        vm.startPrank(stranger);
        equity.approve(address(adapter), 1e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                stranger,
                keccak256("VAULT_ROLE")
            )
        );
        adapter.swap(address(equity), address(stable), 1e18, 0);
        vm.stopPrank();
    }
}

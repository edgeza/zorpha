// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {YieldVault} from "../../src/vaults/YieldVault.sol";
import {StubYieldAdapter} from "../../src/adapters/StubYieldAdapter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {ReceiptRenderer} from "../../src/lib/ReceiptRenderer.sol";

contract YieldVaultTest is Test {
    MockERC20 usdc;
    StubYieldAdapter adapter;
    YieldVault vault;

    address alice = makeAddr("alice");
    address keeper = makeAddr("keeper");

    function setUp() public {
        vm.warp(1_700_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        adapter = new StubYieldAdapter(address(usdc), address(this));
        vault = new YieldVault(
            address(usdc), address(adapter),
            "Zorpha Yield Vault", "sqYIELD",
            0, address(this), address(this)
        );
        vault.grantRole(vault.KEEPER_ROLE(), keeper);

        usdc.mint(alice, 1_000_000 * 1e6);
    }

    function _deposit(uint256 amount) internal returns (uint256 shares) {
        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        shares = vault.deposit(amount, alice);
        vm.stopPrank();
    }

    function test_Deposit_RoutesThroughAdapter() public {
        uint256 shares = _deposit(100_000 * 1e6);
        assertGt(shares, 0);
        // Adapter now holds the deposit.
        assertEq(adapter.totalAssets(), 100_000 * 1e6);
        assertEq(usdc.balanceOf(address(vault)), 0, "vault balance zero after deposit");
    }

    function test_Rebalance_EmitsReceipt_AndIncrementsCount() public {
        _deposit(100_000 * 1e6);

        uint256 nav = vault.getNavPerShare();
        uint256 ta = vault.totalAssets();
        uint256 adapterBal = usdc.balanceOf(address(adapter));
        assertEq(adapterBal, 100_000 * 1e6, "deposit must be held by the adapter");

        // Recompute the commitment rather than asserting bytes32(0), which
        // could never match a keccak256 over live values.
        bytes32 expCommit = ReceiptRenderer.commitment(
            keeper, address(vault), 0, nav, ta, adapterBal, 1, block.timestamp, bytes32(0)
        );

        vm.expectEmit(false, false, false, true, address(vault));
        emit YieldVault.Rebalanced(nav, ta, adapterBal, 1, expCommit);

        vm.prank(keeper);
        vault.rebalanceTo();

        assertEq(vault.rebalanceCount(), 1);
    }

    /// AUDIT V-01. The accounting invariant the vault must hold at all times:
    /// everything `totalAssets()` counts is actually held where it is counted.
    function _assertAdapterHoldsEverything(string memory ctx) internal view {
        assertEq(
            adapter.totalAssets(),
            vault.totalAssets() + vault.performanceFeeAccrued(),
            ctx
        );
    }

    function test_AdapterHoldsEverythingAcrossDepositAndWithdraw() public {
        _assertAdapterHoldsEverything("empty");

        uint256 shares = _deposit(250_000 * 1e6);
        _assertAdapterHoldsEverything("after deposit");
        assertEq(usdc.balanceOf(address(vault)), 0, "vault must not sit on idle capital");

        // startPrank, and share balances read OUTSIDE the argument list: an
        // external call inside the arguments consumes a single-shot vm.prank,
        // so `redeem` would execute as the test contract and fail on allowance.
        vm.startPrank(alice);
        vault.redeem(shares / 2, alice, alice);
        vm.stopPrank();
        _assertAdapterHoldsEverything("after partial redeem");

        uint256 remaining = vault.balanceOf(alice);
        vm.startPrank(alice);
        vault.redeem(remaining, alice, alice);
        vm.stopPrank();
        _assertAdapterHoldsEverything("after full redeem");
        assertEq(vault.totalSupply(), 0, "all shares burned");
    }

    /// A depositor must be able to get out for what they put in. This is the
    /// exact scenario that previously returned zero.
    function testFuzz_DepositThenRedeemIsWhole(uint96 amount) public {
        uint256 amt = bound(uint256(amount), 1e6, 1_000_000 * 1e6);
        usdc.mint(alice, amt);

        uint256 before = usdc.balanceOf(alice);
        vm.startPrank(alice);
        usdc.approve(address(vault), amt);
        uint256 shares = vault.deposit(amt, alice);
        uint256 back = vault.redeem(shares, alice, alice);
        vm.stopPrank();

        assertGt(back, 0, "redeeming must return assets");
        // ERC-4626 rounds in the vault's favour by at most 1 wei per operation.
        assertApproxEqAbs(back, amt, 2, "round trip must be whole");
        assertApproxEqAbs(usdc.balanceOf(alice), before, 2, "balance restored");
    }

    /// Swapping the yield source must move the position with it, or the new
    /// adapter reports zero and every share reprices to nothing.
    function test_SetAdapter_MigratesThePosition() public {
        _deposit(100_000 * 1e6);
        assertEq(adapter.totalAssets(), 100_000 * 1e6);

        StubYieldAdapter next = new StubYieldAdapter(address(usdc), address(this));
        vault.grantRole(vault.ADAPTER_SETTER_ROLE(), address(this));
        vault.setAdapter(address(next));

        assertEq(adapter.totalAssets(), 0, "old adapter drained");
        assertEq(next.totalAssets(), 100_000 * 1e6, "new adapter holds the position");
        assertEq(vault.totalAssets(), 100_000 * 1e6, "NAV survives the migration");

        uint256 held = vault.balanceOf(alice);
        vm.startPrank(alice);
        uint256 back = vault.redeem(held, alice, alice);
        vm.stopPrank();
        assertApproxEqAbs(back, 100_000 * 1e6, 2, "still redeemable after migration");
    }

    function test_SetAdapter_NewAdapterWired() public {
        // A second stub adapter
        StubYieldAdapter newAdapter = new StubYieldAdapter(address(usdc), address(this));
        vault.grantRole(vault.ADAPTER_SETTER_ROLE(), address(this));
        vault.setAdapter(address(newAdapter));
        assertEq(address(vault.adapter()), address(newAdapter));
    }

    function test_Withdraw_ReturnsFunds() public {
        uint256 shares = _deposit(100_000 * 1e6);
        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(shares, alice, alice);
        assertEq(usdc.balanceOf(alice), balBefore + 100_000 * 1e6);
    }
}

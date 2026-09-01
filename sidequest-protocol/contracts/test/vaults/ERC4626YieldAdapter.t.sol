// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {ERC4626YieldAdapter} from "../../src/adapters/ERC4626YieldAdapter.sol";
import {YieldVault} from "../../src/vaults/YieldVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockERC4626} from "../mocks/MockERC4626.sol";

/// @notice Covers the adapter that replaces `StubYieldAdapter`, whose own
///         comment concedes it earns nothing. The cases that matter are the
///         ones the stub never had: real yield reaching depositors, the
///         full-exit rounding trap that adapter migration walks into, and what
///         happens when the target vault cannot pay.
contract ERC4626YieldAdapterTest is Test {
    MockERC20 usdg;
    MockERC4626 target;
    ERC4626YieldAdapter adapter;
    YieldVault vault;

    address admin = address(0xA11CE);
    address treasury = address(0x7EA5);
    address alice = address(0xA1);
    address bob = address(0xB0B);

    uint256 constant ONE = 1e6; // USDG is 6dp, like the real thing

    function setUp() public {
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        target = new MockERC4626(IERC20(address(usdg)), "Steakhouse USDG", "steakUSDG");

        vault = new YieldVault(
            address(usdg),
            address(0), // adapter installed below, once it knows the vault
            "Zorpha USDG Yield Vault",
            "zqUSD",
            1000, // 10% performance fee
            treasury,
            address(this)
        );

        adapter = new ERC4626YieldAdapter(address(usdg), address(target), address(this));
        adapter.grantRole(adapter.VAULT_ROLE(), address(vault));

        vault.grantRole(vault.ADAPTER_SETTER_ROLE(), address(this));
        vault.setAdapter(address(adapter));

        usdg.mint(alice, 1_000_000 * ONE);
        usdg.mint(bob, 1_000_000 * ONE);
    }

    function _deposit(address who, uint256 amount) internal returns (uint256 shares) {
        vm.startPrank(who);
        usdg.approve(address(vault), amount);
        shares = vault.deposit(amount, who);
        vm.stopPrank();
    }

    // ─── Wiring ──────────────────────────────────────────────────────────────

    function test_DepositReachesTheTargetVault() public {
        _deposit(alice, 10_000 * ONE);

        // The money is in the curated vault, not sitting idle anywhere.
        assertEq(usdg.balanceOf(address(vault)), 0, "vault holds idle cash");
        assertEq(usdg.balanceOf(address(adapter)), 0, "adapter holds idle cash");
        assertEq(target.totalAssets(), 10_000 * ONE, "target did not receive it");
        assertEq(adapter.totalAssets(), 10_000 * ONE, "adapter misreports position");
    }

    function test_ConstructorRejectsAssetMismatch() public {
        MockERC20 other = new MockERC20("Other", "OTH", 6);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626YieldAdapter.AssetMismatch.selector, address(other), address(usdg)
            )
        );
        new ERC4626YieldAdapter(address(other), address(target), address(this));
    }

    function test_OnlyVaultCanMoveFunds() public {
        // Read the role BEFORE pranking. A call in the argument list consumes
        // the prank, so the revert would name this test contract, not bob.
        bytes32 role = adapter.VAULT_ROLE();
        bytes memory denied = abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, bob, role
        );

        vm.prank(bob);
        vm.expectRevert(denied);
        adapter.deposit(1);

        vm.prank(bob);
        vm.expectRevert(denied);
        adapter.withdraw(1);
    }

    // ─── The point of the whole exercise ─────────────────────────────────────

    function test_YieldActuallyReachesDepositors() public {
        _deposit(alice, 10_000 * ONE);

        // 5% earned by the curated vault.
        target.accrue(500 * ONE);

        // Rounds down by design: convertToAssets floors. Tolerance, not equality.
        assertApproxEqAbs(adapter.totalAssets(), 10_500 * ONE, 2, "yield not visible to adapter");

        uint256 before = usdg.balanceOf(alice);
        vm.startPrank(alice);
        uint256 shares = vault.balanceOf(alice);
        vault.redeem(shares, alice, alice);
        vm.stopPrank();

        uint256 gained = usdg.balanceOf(alice) - before;

        // 10% performance fee on the 500 of gain, so ~10,450 back.
        //
        // Tolerance is 0.01 USDG rather than a couple of units: the fee is
        // derived from a share price, and the high-water mark is set to the
        // pre-fee NAV, so a sub-cent residual is arithmetic, not slippage.
        assertGt(gained, 10_000 * ONE, "depositor earned nothing");
        assertLt(gained, 10_500 * ONE, "no performance fee was charged");
        assertApproxEqAbs(gained, 10_450 * ONE, ONE / 100, "unexpected net of fee");
    }

    function test_StubComparison_ZeroYieldIsNoLongerTheCase() public {
        _deposit(alice, 10_000 * ONE);
        uint256 startNav = vault.totalAssets();
        target.accrue(300 * ONE);
        assertGt(vault.totalAssets(), startNav, "NAV flat despite target yield");
    }

    /// @dev Regression. `getNavPerShare()` answers `10 ** decimals()` for an
    ///      empty vault, and share decimals carry a 6-place offset over the
    ///      asset, so that sentinel is a million times any NAV a funded vault
    ///      reports. Marking fees against it once, before the first deposit,
    ///      ratcheted the high-water mark somewhere the vault could never
    ///      reach and disabled performance fees permanently — and with them
    ///      half the buyback. Anyone able to touch an empty vault could do it,
    ///      including a keeper being diligent.
    function test_EmptyVaultMarkDoesNotDisableFeesForever() public {
        vault.grantRole(vault.KEEPER_ROLE(), address(this));
        vault.evaluateFees(); // on a vault with zero supply

        _deposit(alice, 10_000 * ONE);
        target.accrue(500 * ONE);

        uint256 before = usdg.balanceOf(alice);
        vm.startPrank(alice);
        vault.redeem(vault.balanceOf(alice), alice, alice);
        vm.stopPrank();

        uint256 gained = usdg.balanceOf(alice) - before;
        assertLt(gained, 10_500 * ONE, "fees were permanently disabled");
        assertApproxEqAbs(gained, 10_450 * ONE, ONE / 100, "wrong fee after empty mark");
    }

    /// @dev The fee must not depend on a keeper being punctual: nothing calls
    ///      `evaluateFees()` anywhere in this test.
    function test_FeeAccruesWithoutAnyKeeperCall() public {
        _deposit(alice, 10_000 * ONE);
        target.accrue(1_000 * ONE);

        vm.startPrank(alice);
        vault.redeem(vault.balanceOf(alice), alice, alice);
        vm.stopPrank();

        assertGt(vault.performanceFeeAccrued(), 0, "no fee accrued without a keeper");
    }

    // ─── Withdrawal paths ────────────────────────────────────────────────────

    function test_PartialWithdrawPullsOnlyWhatIsNeeded() public {
        _deposit(alice, 10_000 * ONE);

        vm.startPrank(alice);
        vault.withdraw(4_000 * ONE, alice, alice);
        vm.stopPrank();

        assertApproxEqAbs(adapter.totalAssets(), 6_000 * ONE, 2, "wrong residual position");
        assertGt(target.balanceOf(address(adapter)), 0, "adapter exited entirely");
    }

    /// @dev The trap migration walks into. `YieldVault.setAdapter` calls
    ///      `withdraw(totalAssets())`, and asking an ERC-4626 for an exact asset
    ///      amount rounds the share cost UP — which can demand one more share
    ///      than exists and revert. If that happens there is no way off the
    ///      adapter, ever.
    function test_FullExitSurvivesShareRounding() public {
        _deposit(alice, 7_777_777);
        target.accrue(1_234_567); // deliberately awkward, forces a non-round price

        uint256 position = adapter.totalAssets();
        assertGt(position, 0);

        MockERC4626 replacement =
            new MockERC4626(IERC20(address(usdg)), "Replacement", "rUSDG");
        ERC4626YieldAdapter next =
            new ERC4626YieldAdapter(address(usdg), address(replacement), address(this));
        next.grantRole(next.VAULT_ROLE(), address(vault));

        vault.setAdapter(address(next)); // must not revert

        assertEq(target.balanceOf(address(adapter)), 0, "old adapter kept shares");
        assertApproxEqAbs(next.totalAssets(), position, 2, "position lost in migration");
    }

    function test_MigrationMovesEveryLastUnit() public {
        _deposit(alice, 10_000 * ONE);
        _deposit(bob, 3_333 * ONE);
        target.accrue(777 * ONE);

        uint256 navBefore = vault.totalAssets();

        MockERC4626 replacement =
            new MockERC4626(IERC20(address(usdg)), "Replacement", "rUSDG");
        ERC4626YieldAdapter next =
            new ERC4626YieldAdapter(address(usdg), address(replacement), address(this));
        next.grantRole(next.VAULT_ROLE(), address(vault));
        vault.setAdapter(address(next));

        assertApproxEqAbs(vault.totalAssets(), navBefore, 2, "NAV moved during migration");
        assertEq(adapter.totalAssets(), 0, "old adapter still holds value");
    }

    // ─── When the target cannot pay ──────────────────────────────────────────

    function test_IlliquidTargetIsVisibleBeforeItBites() public {
        _deposit(alice, 10_000 * ONE);
        target.setLiquidityCap(2_000 * ONE);

        // The position is still worth the full amount...
        assertEq(adapter.totalAssets(), 10_000 * ONE, "NAV should not mark down on illiquidity");
        // ...but only part of it can be realised, and that is queryable.
        assertEq(adapter.maxWithdrawable(), 2_000 * ONE, "liquidity not reported");
    }

    /// @dev A short recall must not silently pay a depositor out of assets that
    ///      were never recovered. The vault holds the line: it tries to transfer
    ///      the full redemption from its own balance and reverts.
    function test_ShortfallFailsTheRedemptionRatherThanUnderpaying() public {
        _deposit(alice, 10_000 * ONE);
        target.setLiquidityCap(1_000 * ONE);

        uint256 aliceBefore = usdg.balanceOf(alice);

        vm.startPrank(alice);
        vm.expectRevert();
        vault.withdraw(9_000 * ONE, alice, alice);
        vm.stopPrank();

        assertEq(usdg.balanceOf(alice), aliceBefore, "depositor was paid on a shortfall");
    }

    function test_WithdrawWithinLiquidityStillWorks() public {
        _deposit(alice, 10_000 * ONE);
        target.setLiquidityCap(3_000 * ONE);

        vm.startPrank(alice);
        vault.withdraw(2_500 * ONE, alice, alice);
        vm.stopPrank();

        assertApproxEqAbs(adapter.totalAssets(), 7_500 * ONE, 2, "wrong residual");
    }

    // ─── Losses ──────────────────────────────────────────────────────────────

    function test_TargetLossFlowsThroughHonestly() public {
        _deposit(alice, 10_000 * ONE);
        target.slash(1_000 * ONE); // curator took a hit

        assertApproxEqAbs(adapter.totalAssets(), 9_000 * ONE, 2, "loss not reflected");
        assertApproxEqAbs(vault.totalAssets(), 9_000 * ONE, 2, "vault NAV hid the loss");
    }

    // ─── Round trip ──────────────────────────────────────────────────────────

    function testFuzz_DepositRedeemRoundTripIsWhole(uint96 raw) public {
        uint256 amount = uint256(raw) % (500_000 * ONE) + ONE;
        usdg.mint(alice, amount);

        uint256 before = usdg.balanceOf(alice);
        uint256 shares = _deposit(alice, amount);

        vm.startPrank(alice);
        vault.redeem(shares, alice, alice);
        vm.stopPrank();

        uint256 after_ = usdg.balanceOf(alice);
        assertLe(after_, before, "depositor gained value from nothing");
        assertApproxEqAbs(after_, before, 2, "round trip lost more than rounding");
    }
}

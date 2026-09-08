// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, StdInvariant, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SpotVaultMinimal} from "../../src/vaults/SpotVaultMinimal.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockOracle} from "../mocks/MockOracle.sol";
import {SlippingSpotAdapter} from "../mocks/SlippingSpotAdapter.sol";

/// @notice Drives the vault through positions, flows and oracle failures.
contract ExitHandler is Test {
    SpotVaultMinimal public vault;
    MockERC20 public stock;
    MockERC20 public cash;
    MockOracle public oracle;
    address public alice;
    address public keeper;

    uint256 public rebalances;
    uint256 public deposits;

    constructor(
        SpotVaultMinimal v, MockERC20 s, MockERC20 c, MockOracle o,
        address alice_, address keeper_
    ) {
        vault = v; stock = s; cash = c; oracle = o;
        alice = alice_; keeper = keeper_;
    }

    function rebalance(uint16 target) external {
        target = uint16(bound(target, 0, 10000));
        vm.prank(keeper);
        try vault.rebalanceTo(target) { rebalances++; } catch {}
    }

    function deposit(uint96 amount) external {
        uint256 amt = bound(amount, 1e15, 50e18);
        stock.mint(alice, amt);
        vm.startPrank(alice);
        stock.approve(address(vault), amt);
        try vault.deposit(amt, alice) { deposits++; } catch {}
        vm.stopPrank();
    }

    /// Withdraw a fraction of what the vault SAYS is available. Every one of
    /// these must succeed, which is the whole point.
    function withdrawSome(uint8 pct) external {
        uint256 mr = vault.maxRedeem(alice);
        if (mr == 0) return;
        uint256 want = (mr * bound(pct, 1, 100)) / 100;
        if (want == 0) return;
        vm.prank(alice);
        vault.redeem(want, alice, alice);
    }

    function breakOracle(bool broken) external {
        oracle.setRevertOnRead(broken);
    }

    function movePrice(uint96 p) external {
        if (oracle.revertOnRead()) return;
        oracle.setPrice(int256(uint256(bound(p, 50e8, 900e8))));
    }
}

/// @notice The advertised maximums must be executable, always.
///
/// Nothing asserted this before, which is how a maxRedeem that returned
/// balanceOf(owner) unconditionally survived a suite of 403 tests while the
/// standard withdrawal path was broken above 40% of a 50/50 position.
contract ExitInvariantsTest is StdInvariant, Test {
    SpotVaultMinimal vault;
    MockERC20 stock;
    MockERC20 cash;
    MockOracle oracle;
    SlippingSpotAdapter venue;
    ExitHandler handler;

    address alice = makeAddr("alice");
    address keeper = makeAddr("keeper");

    function setUp() public {
        vm.warp(1_700_000_000);
        stock = new MockERC20("Tokenised NVDA", "NVDA", 18);
        cash = new MockERC20("Global Dollar", "USDG", 6);
        oracle = new MockOracle(232 * 1e8, 8);
        venue = new SlippingSpotAdapter(address(stock), address(cash), address(oracle));
        venue.setFee(5);

        vault = new SpotVaultMinimal(
            address(stock), address(cash), address(oracle), 365 days,
            "Zorpha NVDA Long/Flat", "zqNVDA",
            0, 100, 0,
            address(this), address(this),
            0
        );
        vault.setSwapAdapter(address(venue));
        vault.grantRole(vault.KEEPER_ROLE(), keeper);

        stock.mint(address(venue), 100_000_000e18);
        cash.mint(address(venue), 100_000_000_000e6);
        stock.mint(alice, 100e18);
        vm.startPrank(alice);
        stock.approve(address(vault), 100e18);
        vault.deposit(100e18, alice);
        vm.stopPrank();

        handler = new ExitHandler(vault, stock, cash, oracle, alice, keeper);
        targetContract(address(handler));
    }

    /// Staleness is set to 365 days above on purpose: this suite is about
    /// whether the advertised bound is executable, and a staleness revert would
    /// close the path for an unrelated reason and make the invariant vacuous.

    /// The headline. Whatever the vault says is redeemable must redeem.
    function invariant_MaxRedeemIsExecutable() public {
        uint256 mr = vault.maxRedeem(alice);
        if (mr == 0) return;
        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        vault.redeem(mr, alice, alice);
        vm.revertToState(snap);
    }

    /// And the same on the asset-denominated side.
    function invariant_MaxWithdrawIsExecutable() public {
        uint256 mw = vault.maxWithdraw(alice);
        if (mw == 0) return;
        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        vault.withdraw(mw, alice, alice);
        vm.revertToState(snap);
    }

    /// The in-kind exit needs no oracle and no venue, so it must work in every
    /// state the handler can reach, including a refusing oracle.
    function invariant_InKindExitAlwaysWorks() public {
        uint256 held = vault.balanceOf(alice);
        if (held == 0) return;
        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        vault.redeemEmergency(held, alice, alice);
        vm.revertToState(snap);
    }

    /// The bound must never exceed the holding, or it is not a bound.
    function invariant_MaxRedeemNeverExceedsHolding() public view {
        assertLe(vault.maxRedeem(alice), vault.balanceOf(alice));
    }

    /// Coverage floor. An invariant suite where the handler never lands is
    /// green and worthless, which is a mistake this repo has made before.
    function afterInvariant() public view {
        assertGt(handler.rebalances(), 0, "no rebalance ever succeeded: suite is vacuous");
    }
}

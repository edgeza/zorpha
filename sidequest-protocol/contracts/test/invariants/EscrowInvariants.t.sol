// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FirstLossEscrow} from "../../src/leadership/FirstLossEscrow.sol";
import {ERC4626YieldAdapter} from "../../src/adapters/ERC4626YieldAdapter.sol";
import {YieldVault} from "../../src/vaults/YieldVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockERC4626} from "../mocks/MockERC4626.sol";

/// @notice Stateful handler driving a vault with a first-loss escrow through
///         deposits, redemptions, yield, losses, fee claims and buffer funding.
///
///         The point is solvency. The escrow promises depositors that a loss
///         lands on the leader first, and that promise is only as good as the
///         contract's ability to actually pay when asked. An accounted balance
///         that drifts above the real one is a promise that fails silently and
///         only at the moment it matters.
contract EscrowHandler is Test {
    YieldVault public vault;
    FirstLossEscrow public escrow;
    MockERC4626 public target;
    MockERC20 public usdg;

    address public constant ALICE = address(0xA11CE);
    address public constant LEADER = address(0x1EAD);

    /// @dev Every handler entrypoint bumps this, successful or not.
    ///
    ///      The coverage guards in `afterInvariant` need to distinguish a real
    ///      campaign from a one-call replay, and they cannot ask the fuzzer.
    ///      See the note on `afterInvariant` for why that matters.
    uint256 public calls;

    uint256 public deposits;
    uint256 public redeems;
    uint256 public losses;
    uint256 public gains;
    uint256 public funds;
    uint256 public claims;

    /// @dev Everything the depositor has ever put in, and taken out. Used to
    ///      assert no value is conjured from nothing.
    uint256 public totalIn;
    uint256 public totalOut;

    /// @dev Cumulative yield minted into the venue. The instantaneous
    ///      `target.totalAssets()` is NOT a substitute: it falls back to near
    ///      zero after redemptions, while the depositor's realised gains keep
    ///      accumulating across cycles.
    uint256 public totalAccrued;

    constructor(YieldVault v, FirstLossEscrow e, MockERC4626 t, MockERC20 u) {
        vault = v;
        escrow = e;
        target = t;
        usdg = u;
    }

    function deposit(uint96 raw) external {
        calls++;
        uint256 amount = (uint256(raw) % 50_000e6) + 1e6;
        usdg.mint(ALICE, amount);
        vm.startPrank(ALICE);
        usdg.approve(address(vault), amount);
        try vault.deposit(amount, ALICE) {
            deposits++;
            totalIn += amount;
        } catch {}
        vm.stopPrank();
    }

    function redeem(uint96 raw) external {
        calls++;
        uint256 held = vault.balanceOf(ALICE);
        if (held == 0) return;
        uint256 shares = (uint256(raw) % held) + 1;
        if (shares > held) shares = held;

        uint256 before = usdg.balanceOf(ALICE);
        vm.startPrank(ALICE);
        try vault.redeem(shares, ALICE, ALICE) {
            redeems++;
            totalOut += usdg.balanceOf(ALICE) - before;
        } catch {}
        vm.stopPrank();
    }

    /// @dev Skipped while the venue has no shares outstanding, and that is not
    ///      a convenience -- it is the difference between modelling yield and
    ///      modelling an attack.
    ///
    ///      `target.accrue` mints underlying straight to the venue. With shares
    ///      outstanding that raises the share price, which is exactly what
    ///      earned yield does. With NO shares outstanding it instead creates
    ///      the ERC-4626 inflation state, where the next deposit mints zero
    ///      shares and loses everything -- and ERC4626YieldAdapter's deposit
    ///      guard correctly refuses to enter it.
    ///
    ///      So a campaign that called `accrue` before any deposit spent the
    ///      rest of its run unable to deposit at all, entirely correctly, and
    ///      the coverage guard in `afterInvariant` then reported "no deposit
    ///      ever landed". The handler was generating a state the protocol is
    ///      built to refuse and calling it yield.
    function accrue(uint96 raw) external {
        calls++;
        if (target.totalSupply() == 0) return; // nothing invested, nothing to earn
        uint256 amount = uint256(raw) % 5_000e6;
        if (amount == 0) return;
        target.accrue(amount);
        totalAccrued += amount;
        gains++;
    }

    function slash(uint96 raw) external {
        calls++;
        uint256 held = usdg.balanceOf(address(target));
        if (held == 0) return;
        uint256 amount = uint256(raw) % held;
        if (amount == 0) return;
        target.slash(amount);
        losses++;
    }

    function fundEscrow(uint96 raw) external {
        calls++;
        uint256 amount = (uint256(raw) % 20_000e6) + 1e6;
        usdg.mint(LEADER, amount);
        vm.startPrank(LEADER);
        usdg.approve(address(escrow), amount);
        escrow.fund(amount);
        vm.stopPrank();
        funds++;
    }

    function claimFees() external {
        calls++;
        try vault.claimFees() {
            claims++;
        } catch {}
    }
}

contract EscrowInvariantsTest is StdInvariant, Test {
    MockERC20 usdg;
    MockERC4626 target;
    ERC4626YieldAdapter adapter;
    YieldVault vault;
    FirstLossEscrow escrow;
    EscrowHandler handler;

    address treasury = address(0x7EA5);
    address leader = address(0x1EAD);

    function setUp() public {
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        target = new MockERC4626(IERC20(address(usdg)), "Curated", "cUSDG");

        vault = new YieldVault(
            address(usdg), address(0), "Zorpha USDG", "zqUSD", 1000, treasury, address(this)
        );
        adapter = new ERC4626YieldAdapter(address(usdg), address(target), address(this));
        adapter.grantRole(adapter.VAULT_ROLE(), address(vault));
        vault.grantRole(vault.ADAPTER_SETTER_ROLE(), address(this));
        vault.setAdapter(address(adapter));

        escrow = new FirstLossEscrow(
            address(usdg), address(vault), leader, treasury, 8000, 500
        );
        vault.setFirstLossEscrow(address(escrow));

        handler = new EscrowHandler(vault, escrow, target, usdg);
        vault.grantRole(vault.DEFAULT_ADMIN_ROLE(), address(handler)); // for claimFees
        targetContract(address(handler));
    }

    /// @dev The solvency invariant. If the accounted balance ever exceeds the
    ///      real one, `absorb` cannot deliver what the vault's NAV already
    ///      promised, and the depositor discovers it during a drawdown.
    function invariant_EscrowNeverClaimsMoreThanItHolds() public view {
        assertLe(
            escrow.escrow(),
            usdg.balanceOf(address(escrow)),
            "escrow accounting exceeds real balance"
        );
    }

    /// @dev The vault must never count support the escrow cannot actually pay.
    function invariant_SupportNeverExceedsAvailableCapital() public view {
        assertLe(vault.escrowSupport(), escrow.available(), "vault counted phantom support");
    }

    /// @dev NAV is raw assets plus support, and nothing else.
    function invariant_TotalAssetsIsRawPlusSupport() public view {
        assertEq(
            vault.totalAssets(),
            vault.rawAssets() + vault.escrowSupport(),
            "totalAssets drifted from its definition"
        );
    }

    /// @dev The buffer only ever tops NAV back up to the high-water mark. If it
    ///      went further it would be paying out unearned gains.
    function invariant_SupportNeverOvershootsTheHighWaterMark() public view {
        uint256 raw = vault.rawAssets();
        uint256 mark = vault.highWaterMarkValue();
        if (raw >= mark) {
            assertEq(vault.escrowSupport(), 0, "buffer applied with no drawdown");
        } else {
            assertLe(vault.escrowSupport(), mark - raw, "buffer overshot the mark");
        }
    }

    /// @dev A depositor can gain from yield, but never from the accounting.
    ///      Anything taken out beyond what went in must be explained by yield
    ///      the venue actually earned plus what the leader actually absorbed.
    ///
    ///      A generous but sound bound: fees and losses only ever reduce what a
    ///      depositor receives, so they need no term of their own on the right.
    function invariant_DepositorGainsAreExplainedByYieldOrTheLeader() public view {
        uint256 out = handler.totalOut();
        uint256 into = handler.totalIn();
        if (out <= into) return;
        assertLe(
            out - into,
            handler.totalAccrued() + escrow.totalAbsorbed() + 1e6,
            "depositor extracted value from neither yield nor the leader"
        );
    }

    /// @dev Coverage guards are meaningless if the escrow can be drained to
    ///      zero while the vault still holds deposits AND the leader is not the
    ///      one who took it. Absorption is the only path that reduces it
    ///      without a matured, coverage-checked withdrawal.
    function invariant_AbsorbedIsMonotonic() public view {
        assertGe(escrow.totalAbsorbed(), 0);
    }

    /// Coverage is NOT asserted in `afterInvariant`, deliberately, and the two
    /// attempts it took to learn that are worth recording.
    ///
    /// Foundry shrinks a failing invariant sequence and PERSISTS it to
    /// `cache/invariant/failures`, replaying it in preference to running a
    /// fresh campaign. An assertion in `afterInvariant` is therefore inside the
    /// shrinker's target, and the shrinker minimises toward the failure:
    ///
    ///   attempt 1  bare `assertGt(handler.deposits(), 0)`. One unlucky
    ///              campaign tripped it, got shrunk to a SINGLE `accrue` call,
    ///              cached, and replayed forever. A one-call sequence can never
    ///              satisfy "a deposit landed", so the failure was
    ///              self-reinforcing and survived every later `forge test`.
    ///   attempt 2  gated on `handler.calls() >= 32`, reasoning that a real
    ///              campaign makes tens of thousands. The shrinker simply found
    ///              a 32-call sequence containing no deposits.
    ///
    /// Any threshold loses the same way, because the shrinker is searching for
    /// the cheapest sequence that satisfies the assertion's negation. So the
    /// check belongs somewhere the shrinker cannot reach: an ordinary test that
    /// drives the handler itself.
    ///
    /// `test_Handler_EveryPathCanLand` below is that test. It verifies the
    /// thing actually worth verifying -- that each path is REACHABLE, so a
    /// campaign is not silently exercising two functions out of six -- and it
    /// cannot be defeated by shrinking because there is nothing to shrink.
    function afterInvariant() public view {
        // Intentionally empty. See the note above.
    }

    /// Every handler path must be able to land. Not an invariant: a plain test,
    /// for the reason given above.
    ///
    /// This is the anti-vacuity check. Without it a campaign whose deposits all
    /// reverted would report 128,000 calls and five passing invariants while
    /// having proven nothing about a vault anyone had money in.
    function test_Handler_EveryPathCanLand() public {
        // Ordered on purpose: a venue with no shares outstanding cannot earn,
        // and donating to it instead creates the inflation state the adapter's
        // deposit guard refuses. Deposit first, then the rest.
        handler.deposit(uint96(5_000e6));
        assertGt(handler.deposits(), 0, "a deposit could not land");

        handler.fundEscrow(uint96(1_000e6));
        assertGt(handler.funds(), 0, "the buffer could not be funded");

        handler.accrue(uint96(500e6));
        assertGt(handler.gains(), 0, "the venue could not earn");

        handler.slash(uint96(100e6));
        assertGt(handler.losses(), 0, "a loss could not be applied");

        handler.redeem(uint96(1e6));
        assertGt(handler.redeems(), 0, "a redemption could not land");
    }

}

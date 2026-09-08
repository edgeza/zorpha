// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, StdInvariant} from "forge-std/Test.sol";
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
    address public riskCouncil;

    uint256 public rebalances;
    uint256 public deposits;

    // Exits that actually landed: withdrawSome/withdrawAssetsSome read the
    // live advertised bound and, if it is nonzero, execute a slice of it with
    // no try/catch, so reaching the increment means the call did not revert.
    // See the `forge-config` line on ExitInvariantsTest below for why that is
    // now actually enforced rather than merely read that way. These live
    // here, not on the invariant test contract, and are written only from
    // these handler actions, never from an invariant_* function:
    // forge's invariant runner wraps every invariant_* call in its own outer
    // snapshot/revert and discards ALL of that call's side effects once it
    // returns, regardless of what the function does internally or in what
    // order. Confirmed empirically (see task-7-report.md): a counter written
    // inside an invariant_* function, whether it lives on this contract or is
    // reached via an external call to the handler, and whether the write
    // happens before or after a manual vm.revertToState, never survives to be
    // read afterwards. Only state written during a genuine handler action
    // that the fuzzer calls directly (a real sequence step, like this one)
    // persists.
    uint256 public redeemsLanded;
    uint256 public withdrawsLanded;

    constructor(
        SpotVaultMinimal v, MockERC20 s, MockERC20 c, MockOracle o,
        address alice_, address keeper_, address riskCouncil_
    ) {
        vault = v; stock = s; cash = c; oracle = o;
        alice = alice_; keeper = keeper_; riskCouncil = riskCouncil_;
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
    /// these must succeed, which is the whole point. No try/catch: reaching
    /// the increment means vault.redeem did not revert, so this is the ghost
    /// counter that proves maxRedeem was actually nonzero and exercised.
    function withdrawSome(uint8 pct) external {
        uint256 mr = vault.maxRedeem(alice);
        if (mr == 0) return;
        uint256 want = (mr * bound(pct, 1, 100)) / 100;
        if (want == 0) return;
        vm.prank(alice);
        vault.redeem(want, alice, alice);
        redeemsLanded++;
    }

    /// Same property as withdrawSome, on the asset-denominated entrypoint.
    function withdrawAssetsSome(uint8 pct) external {
        uint256 mw = vault.maxWithdraw(alice);
        if (mw == 0) return;
        uint256 want = (mw * bound(pct, 1, 100)) / 100;
        if (want == 0) return;
        vm.prank(alice);
        vault.withdraw(want, alice, alice);
        withdrawsLanded++;
    }

    function breakOracle(bool broken) external {
        oracle.setRevertOnRead(broken);
    }

    function movePrice(uint96 p) external {
        if (oracle.revertOnRead()) return;
        oracle.setPrice(int256(uint256(bound(p, 50e8, 900e8))));
    }

    /// Toggle the risk council's circuit breaker, so the suite actually
    /// visits a halted state instead of running all 128,000 calls with the
    /// breaker permanently off.
    function setBreaker(bool on) external {
        vm.prank(riskCouncil);
        vault.setCircuitBreaker(on);
    }

    /// Advance time, so a real staleness window gets exercised instead of a
    /// frozen block.timestamp making every staleness value behave the same.
    function passTime(uint32 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 30 days));
    }
}

/// @notice The advertised maximums must be executable, always.
///
/// Nothing asserted this before, which is how a maxRedeem that returned
/// balanceOf(owner) unconditionally survived a suite of 403 tests while the
/// standard withdrawal path was broken above 40% of a 50/50 position.
///
/// There is no `[invariant]` section in foundry.toml, so `fail_on_revert`
/// defaults to false: a revert inside withdrawSome or withdrawAssetsSome --
/// from vault.redeem or vault.withdraw, not from the handler itself -- is a
/// reverting call from the fuzzer's own driver into the handler, which is
/// exactly what that default is built to swallow. It would not fail the run;
/// it would be discarded, silently, one fuzzed call at a time, which is
/// indistinguishable from the property holding unless the revert happens to
/// be so total that `afterInvariant`'s coverage floor catches it too. A bug
/// that reverts some but not most of the time -- the realistic case -- would
/// sail through: measured, wrapping the redeem/withdraw calls above in an
/// explicit `assertTrue` on success does NOT close this gap either, because
/// forge-std's assertion cheatcode still reverts the handler call it fires
/// in, so it is swallowed the same way. The config below is the only thing
/// that actually enforces this file's headline property.
///
/// Scoped to this contract, not set globally in foundry.toml: VaultHandler
/// and EscrowHandler (the other two files under test/invariants/) call
/// several of their own target functions with no try/catch and DO revert
/// under ordinary fuzzing -- measured, clean runs of VaultInvariantsTest log
/// on the order of a thousand reverts in rebalanceTo alone (996 to 1160
/// across repeated runs, fuzz seed unpinned), all currently tolerated on
/// purpose. A global fail_on_revert=true would fail both of those suites for
/// behaviour they already accept as normal, so the override lives here, on
/// the one contract whose handler actions are actually meant to never
/// revert.
/// forge-config: default.invariant.fail-on-revert = true
contract ExitInvariantsTest is StdInvariant, Test {
    SpotVaultMinimal vault;
    MockERC20 stock;
    MockERC20 cash;
    MockOracle oracle;
    SlippingSpotAdapter venue;
    ExitHandler handler;

    address alice = makeAddr("alice");
    address keeper = makeAddr("keeper");
    address riskCouncil = makeAddr("riskCouncil");

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
        vault.grantRole(vault.RISK_COUNCIL_ROLE(), riskCouncil);

        stock.mint(address(venue), 100_000_000e18);
        cash.mint(address(venue), 100_000_000_000e6);
        stock.mint(alice, 100e18);
        vm.startPrank(alice);
        stock.approve(address(vault), 100e18);
        vault.deposit(100e18, alice);
        vm.stopPrank();

        handler = new ExitHandler(vault, stock, cash, oracle, alice, keeper, riskCouncil);
        targetContract(address(handler));
    }

    /// Staleness is set to 365 days above on purpose: the handler advances
    /// time via passTime (up to 30 days per call), and a staleness revert
    /// would close the withdrawal path for a reason unrelated to what this
    /// suite tests, which would make the invariant vacuous.

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
    /// state the handler can reach, including a refusing oracle and the
    /// circuit breaker turned on.
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
    /// green and worthless, which is a mistake this repo has made before. The
    /// two "landed" asserts below are the same guard applied to the property
    /// this file exists for: a maxRedeem/maxWithdraw that is zero for the
    /// whole run makes invariant_MaxRedeemIsExecutable and
    /// invariant_MaxWithdrawIsExecutable early-return on every single call,
    /// which is indistinguishable from 4/4 passing while asserting nothing.
    /// The counters are read off the handler rather than tracked locally: see
    /// the comment on ExitHandler.redeemsLanded for why an invariant_*
    /// function cannot hold this state itself.
    function afterInvariant() public view {
        assertGt(handler.rebalances(), 0, "no rebalance ever succeeded: suite is vacuous");
        assertGt(handler.redeemsLanded(), 0, "maxRedeem was zero for the entire run: the bound was never exercised");
        assertGt(handler.withdrawsLanded(), 0, "maxWithdraw was zero for the entire run: the bound was never exercised");
    }
}

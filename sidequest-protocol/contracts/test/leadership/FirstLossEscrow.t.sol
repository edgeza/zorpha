// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FirstLossEscrow} from "../../src/leadership/FirstLossEscrow.sol";
import {ERC4626YieldAdapter} from "../../src/adapters/ERC4626YieldAdapter.sol";
import {YieldVault} from "../../src/vaults/YieldVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockERC4626} from "../mocks/MockERC4626.sol";

/// @notice The claim being tested is "the manager loses first". That is a
///         statement about money, so these tests are about money: who is out of
///         pocket, by how much, and in what order.
contract FirstLossEscrowTest is Test {
    MockERC20 usdg;
    MockERC4626 target;
    ERC4626YieldAdapter adapter;
    YieldVault vault;
    FirstLossEscrow escrow;

    address leader = address(0x1EAD);
    address treasury = address(0x7EA5);
    address alice = address(0xA1);
    address bob = address(0xB0B);

    uint256 constant ONE = 1e6; // 6dp, like USDG
    uint16 constant LEADER_FEE_SHARE = 8000; // 80% of the fee to the leader
    uint16 constant MIN_COVERAGE = 500; // 5%, matching Hyperliquid's floor

    function setUp() public {
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        target = new MockERC4626(IERC20(address(usdg)), "Curated USDG", "cUSDG");

        vault = new YieldVault(
            address(usdg), address(0), "Zorpha USDG Yield", "zqUSD", 1000, treasury, address(this)
        );

        adapter = new ERC4626YieldAdapter(address(usdg), address(target), address(this));
        adapter.grantRole(adapter.VAULT_ROLE(), address(vault));
        vault.grantRole(vault.ADAPTER_SETTER_ROLE(), address(this));
        vault.setAdapter(address(adapter));

        escrow = new FirstLossEscrow(
            address(usdg), address(vault), leader, treasury, LEADER_FEE_SHARE, MIN_COVERAGE
        );
        vault.setFirstLossEscrow(address(escrow));

        usdg.mint(alice, 1_000_000 * ONE);
        usdg.mint(bob, 1_000_000 * ONE);
        usdg.mint(leader, 1_000_000 * ONE);
    }

    function _deposit(address who, uint256 amount) internal returns (uint256) {
        vm.startPrank(who);
        usdg.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, who);
        vm.stopPrank();
        return shares;
    }

    function _fund(uint256 amount) internal {
        vm.startPrank(leader);
        usdg.approve(address(escrow), amount);
        escrow.fund(amount);
        vm.stopPrank();
    }

    // ─── The buffer must not be sold to depositors ───────────────────────────

    /// @dev If the escrow counted toward NAV unconditionally, a depositor would
    ///      buy shares priced to include the leader's own capital. They would
    ///      be paying for protection they already own.
    function test_BufferIsNotPartOfNavInNormalTimes() public {
        _fund(1_000 * ONE);

        assertEq(vault.escrowSupport(), 0, "buffer counted with no drawdown");
        assertEq(vault.totalAssets(), 0, "empty vault is not empty");

        uint256 shares = _deposit(alice, 10_000 * ONE);
        assertApproxEqAbs(vault.totalAssets(), 10_000 * ONE, 2, "depositor bought the buffer");

        // And she gets back exactly what she put in, not a share of the leader's.
        vm.startPrank(alice);
        vault.redeem(shares, alice, alice);
        vm.stopPrank();
        assertApproxEqAbs(usdg.balanceOf(alice), 1_000_000 * ONE, 2, "depositor drew on the buffer");
    }

    // ─── The claim itself ────────────────────────────────────────────────────

    function test_ManagerLosesFirst() public {
        _fund(1_000 * ONE);
        uint256 shares = _deposit(alice, 10_000 * ONE);

        // The position loses 800. Less than the buffer, so Alice should be whole.
        target.slash(800 * ONE);

        assertEq(vault.rawAssets(), 9_200 * ONE, "raw assets wrong");
        assertApproxEqAbs(vault.totalAssets(), 10_000 * ONE, 2, "depositor was not protected");

        uint256 before = usdg.balanceOf(alice);
        vm.startPrank(alice);
        vault.redeem(shares, alice, alice);
        vm.stopPrank();

        assertApproxEqAbs(usdg.balanceOf(alice) - before, 10_000 * ONE, 2, "depositor took a loss");
        assertApproxEqAbs(escrow.escrow(), 200 * ONE, 2, "leader did not pay");
        assertApproxEqAbs(escrow.totalAbsorbed(), 800 * ONE, 2, "absorption not recorded");
    }

    function test_DepositorTakesTheLossOnlyAfterTheBufferIsGone() public {
        _fund(500 * ONE);
        uint256 shares = _deposit(alice, 10_000 * ONE);

        target.slash(1_500 * ONE); // 1,000 more than the buffer can cover

        // 8,500 raw, plus the whole 500 buffer, is 9,000. The depositor wears
        // the 1,000 the buffer could not reach — and only that.
        assertApproxEqAbs(vault.totalAssets(), 9_000 * ONE, 2, "buffer not fully applied");

        uint256 before = usdg.balanceOf(alice);
        vm.startPrank(alice);
        vault.redeem(shares, alice, alice);
        vm.stopPrank();

        assertApproxEqAbs(usdg.balanceOf(alice) - before, 9_000 * ONE, 2, "wrong loss to depositor");
        assertEq(escrow.escrow(), 0, "buffer should be exhausted");
    }

    /// @dev The property that stops the buffer being a run incentive. If it
    ///      paid out first-come-first-served, Alice exiting during a drawdown
    ///      would take all of it and Bob would get nothing.
    function test_BufferIsSharedProRataNotFirstComeFirstServed() public {
        _fund(1_000 * ONE);
        uint256 aliceShares = _deposit(alice, 10_000 * ONE);
        uint256 bobShares = _deposit(bob, 10_000 * ONE);

        target.slash(800 * ONE);

        uint256 aliceBefore = usdg.balanceOf(alice);
        vm.startPrank(alice);
        vault.redeem(aliceShares, alice, alice);
        vm.stopPrank();
        uint256 aliceGot = usdg.balanceOf(alice) - aliceBefore;

        uint256 bobBefore = usdg.balanceOf(bob);
        vm.startPrank(bob);
        vault.redeem(bobShares, bob, bob);
        vm.stopPrank();
        uint256 bobGot = usdg.balanceOf(bob) - bobBefore;

        // Both whole, and neither advantaged by exiting first.
        assertApproxEqAbs(aliceGot, 10_000 * ONE, 10, "first out was shortchanged");
        assertApproxEqAbs(bobGot, aliceGot, 10, "exiting first paid better than exiting second");
    }

    /// @dev Adversarial. The buffer is a fixed pot shared across shares, so a
    ///      large deposit arriving mid-drawdown could in principle dilute the
    ///      protection of people already in. It must not.
    function test_LateDepositDoesNotDiluteExistingProtection() public {
        _fund(1_000 * ONE);
        uint256 aliceShares = _deposit(alice, 10_000 * ONE);

        target.slash(800 * ONE); // inside the buffer; alice should be whole

        // A whale arrives while the vault is underwater.
        usdg.mint(bob, 1_000_000 * ONE);
        _deposit(bob, 1_000_000 * ONE);

        uint256 before = usdg.balanceOf(alice);
        vm.startPrank(alice);
        vault.redeem(aliceShares, alice, alice);
        vm.stopPrank();

        assertApproxEqAbs(
            usdg.balanceOf(alice) - before,
            10_000 * ONE,
            20,
            "a late deposit diluted an existing depositor's protection"
        );
    }

    /// @dev The mirror case: someone must not be able to deposit during a
    ///      drawdown and immediately extract a slice of the leader's buffer.
    function test_DepositingIntoADrawdownIsNotFreeMoney() public {
        _fund(1_000 * ONE);
        _deposit(alice, 10_000 * ONE);
        target.slash(800 * ONE);

        uint256 before = usdg.balanceOf(bob);
        uint256 shares = _deposit(bob, 5_000 * ONE);
        vm.startPrank(bob);
        vault.redeem(shares, bob, bob);
        vm.stopPrank();

        assertLe(usdg.balanceOf(bob), before + 2, "in-and-out during a drawdown paid a profit");
    }

    // ─── Coverage ────────────────────────────────────────────────────────────

    function test_CoverageRatioIsMeasuredAgainstRawAssets() public {
        _fund(500 * ONE);
        _deposit(alice, 10_000 * ONE);

        assertEq(escrow.coverageRatioBps(), 500, "expected exactly 5%");
        assertTrue(escrow.isAdequatelyCovered(), "5% should clear a 5% minimum");
        assertEq(escrow.coverageShortfall(), 0, "no shortfall expected");

        _deposit(bob, 10_000 * ONE); // vault doubles, coverage halves
        assertEq(escrow.coverageRatioBps(), 250, "coverage did not fall as the vault grew");
        assertEq(escrow.coverageShortfall(), 500 * ONE, "shortfall wrong");
    }

    // ─── Fees ────────────────────────────────────────────────────────────────

    function test_FeesSplitBetweenLeaderAndProtocol() public {
        _fund(1_000 * ONE);
        _deposit(alice, 10_000 * ONE);
        target.accrue(1_000 * ONE);

        vm.prank(alice);
        vault.withdraw(1 * ONE, alice, alice); // touch the vault to mark fees

        uint256 accrued = vault.performanceFeeAccrued();
        assertGt(accrued, 0, "no fee accrued");

        uint256 leaderBefore = usdg.balanceOf(leader);
        uint256 treasuryBefore = usdg.balanceOf(treasury);
        vault.claimFees();

        uint256 toLeader = usdg.balanceOf(leader) - leaderBefore;
        uint256 toTreasury = usdg.balanceOf(treasury) - treasuryBefore;

        assertApproxEqAbs(toLeader, (accrued * 8000) / 10_000, 2, "leader share wrong");
        assertApproxEqAbs(toTreasury, accrued - toLeader, 2, "protocol share wrong");
    }

    /// @dev A leader who has taken a drawdown rebuilds the protection out of
    ///      their own fee share before they earn again. The protocol's share is
    ///      untouched: one leader's drawdown is not everyone else's problem.
    function test_UndercoveredLeaderRebuildsTheBufferFromTheirOwnShare() public {
        _fund(100 * ONE); // deliberately thin
        _deposit(alice, 10_000 * ONE);

        assertGt(escrow.coverageShortfall(), 0, "should start undercovered");

        target.accrue(2_000 * ONE);
        vm.prank(alice);
        vault.withdraw(1 * ONE, alice, alice);

        uint256 accrued = vault.performanceFeeAccrued();
        uint256 escrowBefore = escrow.escrow();
        uint256 leaderBefore = usdg.balanceOf(leader);
        uint256 treasuryBefore = usdg.balanceOf(treasury);

        vault.claimFees();

        assertGt(escrow.escrow(), escrowBefore, "buffer was not rebuilt");
        assertGt(
            usdg.balanceOf(treasury) - treasuryBefore, 0, "protocol share was diverted"
        );
        // The leader is paid less than a fully-covered leader would have been.
        assertLt(
            usdg.balanceOf(leader) - leaderBefore,
            (accrued * 8000) / 10_000,
            "undercovered leader was paid in full"
        );
    }

    /// @dev The protocol's share must be exactly its share of the WHOLE fee,
    ///      whatever the leader's coverage looks like. Retention comes out of
    ///      the leader's cut alone; diverting the protocol's cut would make one
    ///      leader's drawdown suppress the buyback for everybody.
    function test_ProtocolShareIsNotDilutedByBufferRebuilding() public {
        _fund(1 * ONE); // deeply undercovered, so retention is maximal
        _deposit(alice, 100_000 * ONE);

        target.accrue(10_000 * ONE);
        vm.prank(alice);
        vault.withdraw(1 * ONE, alice, alice);

        uint256 accrued = vault.performanceFeeAccrued();
        assertGt(accrued, 0, "no fee accrued");

        uint256 treasuryBefore = usdg.balanceOf(treasury);
        vault.claimFees();
        uint256 toTreasury = usdg.balanceOf(treasury) - treasuryBefore;

        // 20% of the whole fee, not 20% of whatever survived retention.
        uint256 expected = (accrued * (10_000 - LEADER_FEE_SHARE)) / 10_000;
        assertApproxEqAbs(toTreasury, expected, 2, "protocol share was diluted");
    }

    /// @dev And the three destinations must account for every unit taken.
    function test_FeeSplitConservesTheWholeAmount() public {
        _fund(1 * ONE);
        _deposit(alice, 50_000 * ONE);
        target.accrue(5_000 * ONE);
        vm.prank(alice);
        vault.withdraw(1 * ONE, alice, alice);

        uint256 accrued = vault.performanceFeeAccrued();
        uint256 leaderBefore = usdg.balanceOf(leader);
        uint256 treasuryBefore = usdg.balanceOf(treasury);
        uint256 escrowBefore = escrow.escrow();

        vault.claimFees();

        uint256 moved = (usdg.balanceOf(leader) - leaderBefore)
            + (usdg.balanceOf(treasury) - treasuryBefore)
            + (escrow.escrow() - escrowBefore);

        assertApproxEqAbs(moved, accrued, 2, "fee units went missing");
    }

    // ─── Withdrawal ──────────────────────────────────────────────────────────

    function test_WithdrawalIsTimelocked() public {
        _fund(1_000 * ONE);

        vm.prank(leader);
        escrow.requestWithdrawal(500 * ONE);

        // Read BEFORE the prank. `escrow.withdrawalReadyAt()` is an external
        // call, and evaluating it inside a pranked call's arguments consumes
        // the prank -- the call under test then runs as this contract and
        // reverts NotLeader(). Which incidentally proves the point of naming
        // the error: the bare `vm.expectRevert()` this replaces was equally
        // satisfied by NotLeader() as by the delay it was meant to be testing.
        uint256 readyAt = escrow.withdrawalReadyAt();

        vm.prank(leader);
        vm.expectRevert(abi.encodeWithSelector(FirstLossEscrow.TooEarly.selector, readyAt));
        escrow.executeWithdrawal();

        vm.warp(block.timestamp + 7 days);
        uint256 before = usdg.balanceOf(leader);
        vm.prank(leader);
        escrow.executeWithdrawal();

        assertEq(usdg.balanceOf(leader) - before, 500 * ONE, "leader was not paid");
        assertEq(escrow.escrow(), 500 * ONE, "escrow balance wrong");
    }

    /// The seven-day delay at its boundary, and by reason.
    ///
    /// `test_WithdrawalIsTimelocked` above already covers the delay, so this is
    /// not new ground -- but it covered it with a bare `vm.expectRevert()`,
    /// which accepts ANY revert. That assertion passes if the call fails for a
    /// missing role, an empty pending amount, or a coverage breach, none of
    /// which is the delay. It is now given the error to expect.
    ///
    /// What this test adds is the boundary and the constant: one second short
    /// must fail with `TooEarly(readyAt)`, exactly on time must succeed, and
    /// the delay must actually be seven days. A delay silently shortened to
    /// zero would still satisfy a warp-then-succeed test.
    ///
    /// Found while writing the on-chain drill: `executeWithdrawal` checks
    /// `TooEarly` BEFORE the coverage floor, so the drill can never reach
    /// `WouldBreachMinimum` in a single run.
    function test_WithdrawalCannotBeExecutedBeforeTheDelay() public {
        _fund(1_000 * ONE);
        _deposit(alice, 10_000 * ONE);

        vm.prank(leader);
        escrow.requestWithdrawal(100 * ONE); // well inside the coverage floor

        uint256 readyAt = escrow.withdrawalReadyAt();
        assertEq(readyAt, block.timestamp + 7 days, "the delay should be seven days");

        // One second short.
        vm.warp(readyAt - 1);
        vm.prank(leader);
        vm.expectRevert(abi.encodeWithSelector(FirstLossEscrow.TooEarly.selector, readyAt));
        escrow.executeWithdrawal();

        // And exactly on time it goes through, so the delay is a delay rather
        // than a block.
        vm.warp(readyAt);
        uint256 before = usdg.balanceOf(leader);
        vm.prank(leader);
        escrow.executeWithdrawal();
        assertEq(usdg.balanceOf(leader) - before, 100 * ONE, "the leader should be paid on time");
    }

    /// And the delay cannot be shortened by asking again. A leader who could
    /// re-request without resetting the clock would have a seven-day delay once
    /// and none afterwards.
    function test_RerequestingResetsTheClock() public {
        _fund(1_000 * ONE);
        _deposit(alice, 10_000 * ONE);

        vm.prank(leader);
        escrow.requestWithdrawal(100 * ONE);
        uint256 first = escrow.withdrawalReadyAt();

        vm.warp(block.timestamp + 6 days);
        vm.prank(leader);
        escrow.requestWithdrawal(100 * ONE);
        uint256 second = escrow.withdrawalReadyAt();

        assertGt(second, first, "a fresh request must push the ready time out");

        vm.warp(first);   // when the FIRST request would have matured
        vm.prank(leader);
        vm.expectRevert(abi.encodeWithSelector(FirstLossEscrow.TooEarly.selector, second));
        escrow.executeWithdrawal();
    }

    function test_WithdrawalCannotBreachTheMinimum() public {
        _fund(1_000 * ONE);
        _deposit(alice, 10_000 * ONE); // requires 500 at 5%

        vm.prank(leader);
        escrow.requestWithdrawal(900 * ONE); // would leave 100, i.e. 1%

        vm.warp(block.timestamp + 7 days);
        vm.prank(leader);
        vm.expectRevert(
            abi.encodeWithSelector(FirstLossEscrow.WouldBreachMinimum.selector, 100, MIN_COVERAGE)
        );
        escrow.executeWithdrawal();
    }

    /// @dev Coverage is checked at execution, not at request. Otherwise a
    ///      leader queues an exit while comfortably covered and takes it a week
    ///      later against a vault that has since doubled.
    function test_CoverageIsRecheckedAtExecutionNotAtRequest() public {
        _fund(1_000 * ONE);
        _deposit(alice, 10_000 * ONE);

        vm.prank(leader);
        escrow.requestWithdrawal(500 * ONE); // fine right now: leaves 500 on 10k

        _deposit(bob, 10_000 * ONE); // vault doubles while the request matures

        vm.warp(block.timestamp + 7 days);
        vm.prank(leader);
        // The whole point: the request was fine when made, and the vault doubling
        // in the meantime is what makes it fail now. WouldBreachMinimum is
        // therefore the assertion -- TooEarly would mean the warp did not work.
        vm.expectRevert(
            abi.encodeWithSelector(
                FirstLossEscrow.WouldBreachMinimum.selector, 250, MIN_COVERAGE
            )
        );
        escrow.executeWithdrawal();
    }

    /// @dev Announcing an exit must not switch the protection off. Until the
    ///      capital actually leaves it is still absorbing.
    function test_PendingWithdrawalStillAbsorbs() public {
        _fund(1_000 * ONE);
        uint256 shares = _deposit(alice, 10_000 * ONE);

        vm.prank(leader);
        escrow.requestWithdrawal(1_000 * ONE);

        target.slash(600 * ONE);
        assertApproxEqAbs(vault.totalAssets(), 10_000 * ONE, 2, "pending exit disabled the buffer");

        vm.startPrank(alice);
        vault.redeem(shares, alice, alice);
        vm.stopPrank();
        assertApproxEqAbs(usdg.balanceOf(alice), 1_000_000 * ONE, 2, "depositor took the loss");
    }

    function test_OnlyLeaderCanWithdraw() public {
        _fund(1_000 * ONE);
        vm.prank(bob);
        vm.expectRevert(FirstLossEscrow.NotLeader.selector);
        escrow.requestWithdrawal(1);
    }

    function test_OnlyVaultCanAbsorb() public {
        _fund(1_000 * ONE);
        vm.prank(bob);
        vm.expectRevert(FirstLossEscrow.NotVault.selector);
        escrow.absorb(1);
    }

    // ─── Installation ────────────────────────────────────────────────────────

    /// @dev A swappable escrow is a swappable promise: an admin could point the
    ///      vault at an empty contract the moment a drawdown started.
    function test_EscrowCanOnlyBeSetOnce() public {
        FirstLossEscrow other = new FirstLossEscrow(
            address(usdg), address(vault), leader, treasury, LEADER_FEE_SHARE, MIN_COVERAGE
        );
        vm.expectRevert("YieldVault: escrow already set");
        vault.setFirstLossEscrow(address(other));
    }

    function test_EscrowMustBeBoundToThisVault() public {
        YieldVault other = new YieldVault(
            address(usdg), address(0), "Other", "oth", 1000, treasury, address(this)
        );
        FirstLossEscrow foreign = new FirstLossEscrow(
            address(usdg), address(other), leader, treasury, LEADER_FEE_SHARE, MIN_COVERAGE
        );
        YieldVault fresh = new YieldVault(
            address(usdg), address(0), "Fresh", "frh", 1000, treasury, address(this)
        );
        vm.expectRevert("YieldVault: escrow vault mismatch");
        fresh.setFirstLossEscrow(address(foreign));
    }

    // ─── Round trip ──────────────────────────────────────────────────────────

    function testFuzz_DepositorNeverLosesMoreThanTheUncoveredShortfall(
        uint96 depositRaw,
        uint96 bufferRaw,
        uint96 lossRaw
    ) public {
        uint256 deposit = uint256(depositRaw) % (100_000 * ONE) + 100 * ONE;
        uint256 buffer = uint256(bufferRaw) % (10_000 * ONE);
        uint256 loss = uint256(lossRaw) % deposit;

        usdg.mint(leader, buffer);
        _fund(buffer);
        uint256 shares = _deposit(alice, deposit);

        if (loss > 0) target.slash(loss);

        uint256 before = usdg.balanceOf(alice);
        vm.startPrank(alice);
        vault.redeem(shares, alice, alice);
        vm.stopPrank();
        uint256 got = usdg.balanceOf(alice) - before;

        uint256 absorbed = loss < buffer ? loss : buffer;
        uint256 expectedLoss = loss - absorbed;

        // Never worse than the part the buffer could not cover.
        assertGe(got + expectedLoss + 10, deposit, "depositor lost more than uncovered shortfall");
        assertLe(got, deposit + 10, "depositor gained from a loss");
    }
}

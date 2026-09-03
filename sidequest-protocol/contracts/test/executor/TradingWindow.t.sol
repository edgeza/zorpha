// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {StrategyExecutor, ISpotRebalancer} from "../../src/executor/StrategyExecutor.sol";

contract WindowMockRebalancer is ISpotRebalancer {
    uint256 public callCount;
    function rebalanceTo(uint16) external { callCount += 1; }
}

/// @notice A rebalance must be refused while the vault's reference market is shut.
///
///         A tokenised equity trades 24/7 on this chain while its reference market
///         is closed sixteen hours a day and all weekend. Chainlink's deviation
///         trigger only guards against a stale price while there IS a live price
///         to deviate from; overnight the feed is frozen because the market is
///         shut. So a manager who knows the stock gapped after hours could sign a
///         rebalance against the previous close and pass every other check the
///         executor makes -- signature, nonce, expiry, weight, rate limit.
///
///         Times below are real UTC timestamps in September 2026, chosen so the
///         weekday arithmetic is exercised rather than assumed. The window used
///         throughout is 14:30-21:00 UTC Mon-Fri: US equity hours in winter.
contract TradingWindowTest is Test {
    StrategyExecutor executor;
    WindowMockRebalancer vault;
    uint256 signerPk = 0xA11CE;

    uint16 constant OPEN = 870;   // 14:30 UTC
    uint16 constant CLOSE = 1260; // 21:00 UTC
    uint8  constant MON_FRI = 0x3E;

    uint256 constant WED_1500 = 1788361200;
    uint256 constant WED_0200 = 1788314400;
    uint256 constant WED_1429 = 1788359340;
    uint256 constant WED_1430 = 1788359400;
    uint256 constant WED_2059 = 1788382740;
    uint256 constant WED_2100 = 1788382800;
    uint256 constant SAT_1500 = 1788620400;

    function setUp() public {
        executor = new StrategyExecutor(address(this));
        vault = new WindowMockRebalancer();
        executor.setAuthorizedSigner(vm.addr(signerPk));
        executor.grantRole(executor.KEEPER_ROLE(), address(this));
        executor.setTradingWindow(address(vault), OPEN, CLOSE, MON_FRI);
    }

    /// Signature and warp are done BEFORE any vm.expectRevert, deliberately.
    /// vm.expectRevert applies to the very next call, and a cheatcode counts:
    /// an earlier revision warped inside the helper, so every "must revert"
    /// test asserted that vm.warp reverts, which it does not. Six tests failed
    /// with "next call did not revert as expected" while the contract was
    /// behaving correctly.
    function _sig(address v, uint256 nonce, uint256 expiry) internal view returns (bytes memory) {
        bytes32 structHash =
            keccak256(abi.encode(executor.REBALANCE_TYPEHASH(), v, uint16(5000), nonce, expiry));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", executor.DOMAIN_SEPARATOR(), structHash));
        (uint8 sv, bytes32 r, bytes32 ss) = vm.sign(signerPk, digest);
        return abi.encodePacked(r, ss, sv);
    }

    /// Warps, signs, and executes. Only for calls expected to SUCCEED.
    function _rebalanceAt(uint256 ts, uint256 nonce) internal {
        vm.warp(ts);
        uint256 expiry = ts + 1 hours;
        executor.executeRebalance(address(vault), 5000, nonce, expiry, _sig(address(vault), nonce, expiry));
    }

    /// Warps and signs, then hands back exactly the arguments for the call, so
    /// the test can put vm.expectRevert immediately before it.
    function _armed(uint256 ts, uint256 nonce) internal returns (uint256 expiry, bytes memory sig) {
        vm.warp(ts);
        expiry = ts + 1 hours;
        sig = _sig(address(vault), nonce, expiry);
    }

    function test_MidSessionIsAllowed() public {
        _rebalanceAt(WED_1500, 1);
        assertEq(vault.callCount(), 1);
    }

    function test_OvernightIsRefused() public {
        (uint256 e, bytes memory sig) = _armed(WED_0200, 1);
        vm.expectRevert(
            abi.encodeWithSelector(StrategyExecutor.MarketClosed.selector, address(vault), uint256(120), uint256(3))
        );
        executor.executeRebalance(address(vault), 5000, 1, e, sig);
        assertEq(vault.callCount(), 0);
    }

    function test_WeekendIsRefused() public {
        (uint256 e, bytes memory sig) = _armed(SAT_1500, 1);
        vm.expectRevert(
            abi.encodeWithSelector(StrategyExecutor.MarketClosed.selector, address(vault), uint256(900), uint256(6))
        );
        executor.executeRebalance(address(vault), 5000, 1, e, sig);
    }

    /// The open edge is inclusive and the close edge exclusive. Pinned because
    /// an off-by-one here is an hour of the exact exposure this exists to stop.
    function test_TheEdgesAreWhereTheySay() public {
        (uint256 e1, bytes memory s1) = _armed(WED_1429, 1);
        vm.expectRevert();
        executor.executeRebalance(address(vault), 5000, 1, e1, s1);

        _rebalanceAt(WED_1430, 1);
        assertEq(vault.callCount(), 1);

        _rebalanceAt(WED_2059, 2);
        assertEq(vault.callCount(), 2);

        (uint256 e2, bytes memory s2) = _armed(WED_2100, 3);
        vm.expectRevert();
        executor.executeRebalance(address(vault), 5000, 3, e2, s2);
        assertEq(vault.callCount(), 2);
    }

    function test_HolidayOverrideBeatsAnOpenSession() public {
        uint64 until = uint64(WED_1500 + 1 days);
        executor.setClosedUntil(address(vault), until);
        (uint256 e, bytes memory sig) = _armed(WED_1500, 1);
        vm.expectRevert(
            abi.encodeWithSelector(StrategyExecutor.MarketHalted.selector, address(vault), until)
        );
        executor.executeRebalance(address(vault), 5000, 1, e, sig);
    }

    /// Unset means unrestricted: 24/7 assets, and every vault that predates this.
    function test_AVaultWithNoWindowIsUnrestricted() public {
        WindowMockRebalancer free = new WindowMockRebalancer();
        vm.warp(SAT_1500);
        uint256 expiry = SAT_1500 + 1 hours;
        executor.executeRebalance(address(free), 5000, 1, expiry, _sig(address(free), 1, expiry));
        assertEq(free.callCount(), 1);
    }

    function test_ClearingLiftsTheRestriction() public {
        executor.clearTradingWindow(address(vault));
        _rebalanceAt(SAT_1500, 1);
        assertEq(vault.callCount(), 1);
    }

    /// A closed market must not consume a rate-limit slot. Otherwise anyone with
    /// KEEPER_ROLE could drain the day's quota overnight and leave the vault
    /// unable to trade when the market actually opens.
    function test_ARefusalDoesNotBurnRateLimitBudget() public {
        executor.setDailyLimit(address(vault), 1);
        (uint256 e, bytes memory sig) = _armed(WED_0200, 1);
        vm.expectRevert();
        executor.executeRebalance(address(vault), 5000, 1, e, sig);

        _rebalanceAt(WED_1500, 1);
        assertEq(vault.callCount(), 1);
    }

    function test_RejectsScheduleThatCouldNeverOpen() public {
        vm.expectRevert(StrategyExecutor.BadTradingWindow.selector);
        executor.setTradingWindow(address(vault), OPEN, CLOSE, 0);

        vm.expectRevert(StrategyExecutor.BadTradingWindow.selector);
        executor.setTradingWindow(address(vault), 900, 900, MON_FRI);

        vm.expectRevert(StrategyExecutor.BadTradingWindow.selector);
        executor.setTradingWindow(address(vault), 1440, CLOSE, MON_FRI);
    }

    /// Some markets do straddle midnight UTC, so close < open must mean "wraps"
    /// rather than "never opens".
    function test_AWindowMayWrapMidnight() public {
        executor.setTradingWindow(address(vault), 1320, 240, 0x7F); // 22:00 -> 04:00, daily
        _rebalanceAt(WED_0200, 1);
        assertEq(vault.callCount(), 1);

        (uint256 e, bytes memory sig) = _armed(WED_1500, 2);
        vm.expectRevert();
        executor.executeRebalance(address(vault), 5000, 2, e, sig);
    }
}

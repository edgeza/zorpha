// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {MedianOracle} from "../../src/oracle/MedianOracle.sol";

/// @notice The price of everything, which had no tests.
///
///         test/oracle held two files and both were about the vault-to-oracle
///         WINDOW relationship. Ten test functions mentioned MedianOracle and
///         not one exercised the median: the single report() call in the whole
///         suite was a setup line. So _median, the function that decides what
///         every asset in the protocol is worth, was never run against an
///         assertion, and neither were the bounds check, the staleness filter,
///         the quorum boundary or the oldest-timestamp rule.
///
///         Nothing here is a bug report. It is the evidence that the oracle
///         does what the rest of the system assumes it does.
contract MedianOracleTest is Test {
    MedianOracle oracle;

    address admin = address(this);
    address a = address(0xA1);
    address b = address(0xB2);
    address c = address(0xC3);
    address d = address(0xD4);
    address stranger = address(0x5747);

    uint256 constant WINDOW = 3600;

    /// The base time, as a CONSTANT rather than a read of block.timestamp.
    ///
    /// This project compiles with via_ir and the optimizer on, and under those
    /// settings every block.timestamp read inside one function is the same
    /// expression and gets folded into a single TIMESTAMP opcode. A local
    /// captured "before" a vm.warp therefore holds the value from AFTER it, and
    /// a second `vm.warp(block.timestamp + x)` warps relative to the wrong base.
    ///
    /// It cost two confusing failures here, one of which read as the oracle
    /// returning the newest timestamp when it was returning the oldest
    /// correctly. Any test in this repo doing time arithmetic across a warp
    /// should derive every instant from a constant like this one.
    uint256 constant T0 = 1_800_000_000;
    int256 constant MIN_ANSWER = 1;
    int256 constant MAX_ANSWER = 1e12;

    function setUp() public {
        vm.warp(T0);
        oracle = new MedianOracle(8, WINDOW, MIN_ANSWER, MAX_ANSWER, 1, admin);
    }

    function _seat(address who) internal {
        oracle.addUpdater(who);
    }

    function _report(address who, int256 price) internal {
        vm.prank(who);
        oracle.report(price);
    }

    function _answer() internal view returns (int256) {
        (, int256 ans,,,) = oracle.latestRoundData();
        return ans;
    }

    function _updatedAt() internal view returns (uint256) {
        (,,, uint256 u,) = oracle.latestRoundData();
        return u;
    }

    // --- The median itself ---------------------------------------------------

    function test_OneReportIsItsOwnMedian() public {
        _seat(a);
        _report(a, 250e8);
        assertEq(_answer(), 250e8);
    }

    /// Odd count takes the middle element after sorting. The inputs are given
    /// out of order deliberately: the insertion sort is the thing under test.
    function test_AnOddCountTakesTheMiddleValue() public {
        _seat(a); _seat(b); _seat(c);
        _report(a, 300e8);
        _report(b, 100e8);
        _report(c, 200e8);
        assertEq(_answer(), 200e8, "not the middle of 100/200/300");
    }

    /// Even count averages the two middle values.
    function test_AnEvenCountAveragesTheTwoMiddleValues() public {
        _seat(a); _seat(b); _seat(c); _seat(d);
        _report(a, 400e8);
        _report(b, 100e8);
        _report(c, 300e8);
        _report(d, 200e8);
        assertEq(_answer(), 250e8, "not the average of the middle pair 200/300");
    }

    /// The entire reason for taking a median rather than a mean: one updater
    /// reporting nonsense moves the price by nothing at all.
    function test_ASingleOutlierDoesNotMoveThePrice() public {
        _seat(a); _seat(b); _seat(c);
        _report(a, 250e8);
        _report(b, 250e8);
        _report(c, 1e12);            // wildly wrong, still inside bounds

        assertEq(_answer(), 250e8, "an outlier moved the median");
    }

    /// And with a mean it would have. Stated as a number so the difference is
    /// not left to the reader.
    function test_AndAMeanWouldHaveMovedALot() public {
        _seat(a); _seat(b); _seat(c);
        _report(a, 250e8);
        _report(b, 250e8);
        _report(c, 1e12);

        int256 mean = (250e8 + 250e8 + int256(1e12)) / 3;
        assertGt(mean, _answer() * 10, "the outlier case is not extreme enough to be evidence");
    }

    // --- Bounds --------------------------------------------------------------

    function test_APriceBelowTheFloorIsRefused() public {
        _seat(a);
        vm.prank(a);
        vm.expectRevert(abi.encodeWithSelector(MedianOracle.OutOfBounds.selector, int256(0)));
        oracle.report(0);
    }

    function test_APriceAboveTheCeilingIsRefused() public {
        _seat(a);
        int256 tooHigh = MAX_ANSWER + 1;
        vm.prank(a);
        vm.expectRevert(abi.encodeWithSelector(MedianOracle.OutOfBounds.selector, tooHigh));
        oracle.report(tooHigh);
    }

    function test_TheBoundsThemselvesAreAccepted() public {
        _seat(a); _seat(b);
        _report(a, MIN_ANSWER);
        _report(b, MAX_ANSWER);
        // Both landed, so neither endpoint is off by one.
        assertEq(_answer(), (MIN_ANSWER + MAX_ANSWER) / 2);
    }

    // --- Staleness -----------------------------------------------------------

    /// A report outside the window stops contributing. Not merely deprioritised
    /// -- it is dropped from the set entirely, which is what makes quorum the
    /// operational constraint it is.
    function test_AStaleReportStopsContributing() public {
        _seat(a); _seat(b); _seat(c);
        _report(a, 100e8);
        _report(b, 200e8);
        _report(c, 300e8);
        assertEq(_answer(), 200e8);

        // Age a and b out, leave c fresh.
        vm.warp(T0 + WINDOW + 1);
        _report(c, 300e8);

        assertEq(_answer(), 300e8, "the stale reports still counted");
    }

    function test_TheWindowEdgeIsInclusive() public {
        _seat(a);
        _report(a, 250e8);

        vm.warp(T0 + WINDOW);                       // exactly at the edge
        assertEq(_answer(), 250e8, "a report exactly at maxStaleness was dropped");

        vm.warp(T0 + WINDOW + 1);                   // one second past
        vm.expectRevert(abi.encodeWithSelector(MedianOracle.InsufficientFreshReports.selector, 0, 1));
        oracle.latestRoundData();
    }

    /// The rule the whole quorum cost argument rests on, pinned as a unit test
    /// rather than only observed in a drill: the reported age is the age of the
    /// OLDEST contributing report, so the oracle is exactly as fresh as its
    /// slowest updater.
    function test_UpdatedAtIsTheOldestContributingReportNotTheNewest() public {
        _seat(a); _seat(b);

        // One read of block.timestamp, taken before any warp, and every later
        // time derived from it.
        //
        // Reading it on BOTH sides of a vm.warp does not work under via_ir with
        // the optimizer on: the two reads are the same expression, they get
        // folded into one, and the local captured "before" the warp ends up
        // holding the value from after it. This test failed exactly that way,
        // reporting the oracle had taken the newest timestamp when it had not.
        _report(a, 250e8);

        vm.warp(T0 + 600);
        _report(b, 250e8);

        assertEq(_updatedAt(), T0, "updatedAt is not the oldest contributor");
        assertLt(_updatedAt(), T0 + 600, "updatedAt took the newest report");
    }

    /// And once the laggard ages out, the reported age jumps FORWARD to the
    /// survivor. A consumer watching updatedAt sees freshness improve at the
    /// moment the set shrinks, which is counterintuitive and worth pinning.
    function test_WhenTheLaggardAgesOutTheReportedAgeImproves() public {
        _seat(a); _seat(b);
        _report(a, 250e8);
        vm.warp(T0 + 600);
        _report(b, 250e8);
        uint256 reportedBefore = _updatedAt();

        vm.warp(T0 + WINDOW + 1);              // a is out, b still in
        assertGt(_updatedAt(), reportedBefore, "the reported age did not move to the survivor");
    }

    // --- Quorum --------------------------------------------------------------

    function test_BelowQuorumTheOracleGoesDarkRatherThanGuessing() public {
        MedianOracle o = new MedianOracle(8, WINDOW, MIN_ANSWER, MAX_ANSWER, 2, admin);
        o.addUpdater(a);
        o.addUpdater(b);

        vm.prank(a);
        o.report(250e8);

        vm.expectRevert(abi.encodeWithSelector(MedianOracle.InsufficientFreshReports.selector, 1, 2));
        o.latestRoundData();

        vm.prank(b);
        o.report(250e8);
        (, int256 ans,,,) = o.latestRoundData();
        assertEq(ans, 250e8, "quorum was met and it still refused");
    }

    // --- The updater set -----------------------------------------------------

    function test_OnlyAnUpdaterCanReport() public {
        vm.prank(stranger);
        vm.expectRevert();
        oracle.report(250e8);
    }

    function test_OnlyAdminCanSeatAnUpdater() public {
        vm.prank(stranger);
        vm.expectRevert();
        oracle.addUpdater(stranger);
    }

    function test_TheSameUpdaterCannotBeSeatedTwice() public {
        _seat(a);
        vm.expectRevert(bytes("already updater"));
        oracle.addUpdater(a);
    }

    /// The structural trap behind the mainnet gate: removeUpdater refuses while
    /// the set is exactly the size of the quorum, and minQuorum is IMMUTABLE.
    /// Two updaters at quorum two is a configuration where a compromised key can
    /// never be evicted by anyone, ever, without redeploying the oracle.
    function test_AtQuorumSizeAnUpdaterCanNeverBeRemoved() public {
        MedianOracle o = new MedianOracle(8, WINDOW, MIN_ANSWER, MAX_ANSWER, 2, admin);
        o.addUpdater(a);
        o.addUpdater(b);

        vm.expectRevert(bytes("MedianOracle: would break quorum"));
        o.removeUpdater(a);

        // The only way out is to add a third first.
        o.addUpdater(c);
        o.removeUpdater(a);
        assertEq(o.updaterCount(), 2, "removal did not happen even with a spare");
    }

    function test_ARemovedUpdaterLosesItsReportAndItsRights() public {
        _seat(a); _seat(b);
        _report(a, 100e8);
        _report(b, 300e8);
        assertEq(_answer(), 200e8);

        oracle.removeUpdater(a);
        assertEq(_answer(), 300e8, "the removed report still contributed");

        vm.prank(a);
        vm.expectRevert();
        oracle.report(150e8);
    }

    // --- What the vault staleness check can and cannot see -------------------

    /// roundId and answeredInRound are the SAME counter, so the
    /// `answeredInRound < roundId` test that SpotVaultMinimal runs against a
    /// feed can never fire against this oracle. That is not a fault here -- the
    /// check exists for Chainlink aggregators, where the two can differ -- but
    /// it means the protection is inert on every vault backed by our own
    /// oracle, and that is worth knowing rather than assuming.
    function test_RoundIdAndAnsweredInRoundAreAlwaysEqualHere() public {
        _seat(a);
        _report(a, 250e8);
        (uint80 roundId,,,, uint80 answeredInRound) = oracle.latestRoundData();
        assertEq(roundId, answeredInRound, "the two counters diverged");

        _report(a, 251e8);
        (uint80 r2,,,, uint80 air2) = oracle.latestRoundData();
        assertEq(r2, air2);
        assertGt(r2, roundId, "the round counter did not advance on a new report");
    }
}

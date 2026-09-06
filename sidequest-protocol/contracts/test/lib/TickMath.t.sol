// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "../../src/lib/TickMath.sol";

/// @notice `getSqrtRatioAtTick` behind an external call, so `vm.expectRevert`
///         has something to intercept.
///
///         A library's internal function is inlined into its caller, so it
///         reverts inside the test frame itself rather than in a sub-call, and
///         `expectRevert` never sees it -- the test just fails with the
///         library's own error. Every revert case below goes through here; the
///         value cases call the library directly, which keeps them `pure`.
contract TickMathHarness {
    function getSqrtRatioAtTick(int24 tick) external pure returns (uint160) {
        return TickMath.getSqrtRatioAtTick(tick);
    }
}

/// @notice Known-answer tests for the vendored tick-to-ratio conversion.
///
///         Vendored code gets vendored wrong, and this is the shape it takes:
///         one mistyped digit in one of twenty magic constants is a price that
///         is exactly right at most ticks and subtly wrong at the ticks whose
///         bit pattern touches the bad constant. Nothing about the code looks
///         suspicious afterwards, and a round-trip test agrees with itself.
///
///         So every check below is against a value fixed by the Uniswap V3
///         specification -- 2^96 at tick zero, the two published ratio bounds,
///         the size of one tick -- rather than against this implementation's
///         own output. The fuzz test covers the whole domain for the property
///         that catches a constant which is wrong in the large: a ratio outside
///         the bounds.
contract TickMathTest is Test {
    TickMathHarness harness;

    function setUp() public {
        harness = new TickMathHarness();
    }

    /// Tick zero is a ratio of exactly one, so sqrtPriceX96 is exactly 2^96.
    function test_TickZeroIsQ96() public pure {
        assertEq(uint256(TickMath.getSqrtRatioAtTick(0)), 1 << 96);
    }

    function test_BoundsMatchTheSpecification() public pure {
        assertEq(
            uint256(TickMath.getSqrtRatioAtTick(TickMath.MIN_TICK)),
            uint256(TickMath.MIN_SQRT_RATIO),
            "MIN_TICK must produce MIN_SQRT_RATIO"
        );
        assertEq(
            uint256(TickMath.getSqrtRatioAtTick(TickMath.MAX_TICK)),
            uint256(TickMath.MAX_SQRT_RATIO),
            "MAX_TICK must produce MAX_SQRT_RATIO"
        );
    }

    /// One tick is one basis point of PRICE, so half a basis point of its
    /// square root. sqrt(1.0001) - 1 = 4.999875e-5, which is 4999 after
    /// truncation into 1e-8 units.
    function test_OneTickIsHalfABasisPointOfSqrtPrice() public pure {
        uint256 at0 = TickMath.getSqrtRatioAtTick(0);
        uint256 at1 = TickMath.getSqrtRatioAtTick(1);
        uint256 gainE8 = ((at1 - at0) * 1e8) / at0;
        assertApproxEqAbs(gainE8, 4999, 2, "one tick is not half a basis point of sqrt(price)");
    }

    function test_IsMonotonic() public pure {
        assertGt(
            TickMath.getSqrtRatioAtTick(221882),
            TickMath.getSqrtRatioAtTick(221881),
            "must increase with the tick"
        );
        assertLt(
            TickMath.getSqrtRatioAtTick(-221882),
            TickMath.getSqrtRatioAtTick(-221881),
            "must decrease below zero"
        );
    }

    /// The positive branch inverts the negative one, so a bug in the inversion
    /// shows here and nowhere else.
    function test_NegativeAndPositiveAreReciprocal() public pure {
        uint256 up = TickMath.getSqrtRatioAtTick(100000);
        uint256 down = TickMath.getSqrtRatioAtTick(-100000);
        // (2^96)^2 / up is what down must be, to within rounding.
        uint256 expected = ((1 << 96) * (1 << 96)) / up;
        assertApproxEqRel(down, expected, 1e12, "the two branches are not reciprocal"); // 1e-6
    }

    /// The live NVDA/USDG tick, cross-checked against the value the pool's own
    /// slot0 reports. 221,882 is 4.3225e9 in raw token1/token0 terms, which is
    /// a sqrtPriceX96 of about 5.209e33.
    function test_TheLivePoolTickProducesTheObservedRatio() public pure {
        uint256 r = uint256(TickMath.getSqrtRatioAtTick(221882));
        assertApproxEqRel(r, 5209002981863638722623952383317079, 1e14, "tick 221882"); // 1e-4
    }

    function test_RevertsAboveMaxTick() public {
        vm.expectRevert(abi.encodeWithSelector(TickMath.TickOutOfRange.selector, int24(887273)));
        harness.getSqrtRatioAtTick(int24(887273));
    }

    function test_RevertsBelowMinTick() public {
        vm.expectRevert(abi.encodeWithSelector(TickMath.TickOutOfRange.selector, int24(-887273)));
        harness.getSqrtRatioAtTick(int24(-887273));
    }

    function testFuzz_StaysInsideTheRatioBounds(int24 tick) public pure {
        tick = int24(bound(int256(tick), TickMath.MIN_TICK, TickMath.MAX_TICK));
        uint256 r = TickMath.getSqrtRatioAtTick(tick);
        assertGe(r, uint256(TickMath.MIN_SQRT_RATIO), "below MIN_SQRT_RATIO");
        assertLe(r, uint256(TickMath.MAX_SQRT_RATIO), "above MAX_SQRT_RATIO");
    }

    function testFuzz_IsMonotonicEverywhere(int24 tick) public pure {
        tick = int24(bound(int256(tick), TickMath.MIN_TICK, TickMath.MAX_TICK - 1));
        assertGt(
            TickMath.getSqrtRatioAtTick(tick + 1),
            TickMath.getSqrtRatioAtTick(tick),
            "a higher tick must never produce a lower ratio"
        );
    }
}

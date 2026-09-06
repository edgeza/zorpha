// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title TickMath
/// @notice Tick to sqrt-price conversion, vendored from Uniswap V3 core.
///
///         WHY VENDORED AND NOT IMPORTED
///
///         v3-core pins `pragma >=0.5.0 <0.8.0`, and not merely out of caution:
///         the algorithm below DEPENDS on multiplication wrapping, which 0.8.x
///         reverts on. Adding the dependency would mean either a second solc
///         version in this build or forking it anyway. This is the fork, kept
///         to the one function that is needed and wrapped in `unchecked` so the
///         wrapping the algorithm relies on still happens.
///
///         Only `getSqrtRatioAtTick` is here. The inverse,
///         `getTickAtSqrtRatio`, is not, because nothing in this protocol goes
///         that direction and unused vendored code is unreviewed vendored code.
///
///         HOW IT WORKS, SINCE THE CONSTANTS EXPLAIN NOTHING ON THEIR OWN
///
///         sqrt(1.0001^tick) is computed by binary decomposition of |tick|:
///         each constant is 1.0001^(-2^i / 2) in Q128.128, so multiplying
///         together the ones whose bit is set in |tick| gives 1.0001^(-|tick|/2).
///         That is why the table runs in the NEGATIVE direction and a positive
///         tick is handled by inverting at the end. The result is then narrowed
///         from Q128.128 to Q64.96, rounding up so that feeding it back through
///         Uniswap's `getTickAtSqrtRatio` returns the tick that was passed in.
library TickMath {
    error TickOutOfRange(int24 tick);

    /// @dev The minimum tick that may be passed to `getSqrtRatioAtTick`.
    int24 internal constant MIN_TICK = -887272;
    /// @dev The maximum tick that may be passed to `getSqrtRatioAtTick`.
    int24 internal constant MAX_TICK = 887272;

    /// @dev `getSqrtRatioAtTick(MIN_TICK)`.
    uint160 internal constant MIN_SQRT_RATIO = 4295128739;
    /// @dev `getSqrtRatioAtTick(MAX_TICK)`.
    uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    /// @notice Calculates sqrt(1.0001^tick) * 2^96.
    /// @param tick The input tick, within [MIN_TICK, MAX_TICK].
    /// @return sqrtPriceX96 The sqrt ratio as a Q64.96.
    function getSqrtRatioAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        unchecked {
            uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
            if (absTick > uint256(int256(MAX_TICK))) revert TickOutOfRange(tick);

            uint256 ratio = absTick & 0x1 != 0
                ? 0xfffcb933bd6fad37aa2d162d1a594001
                : 0x100000000000000000000000000000000;
            if (absTick & 0x2 != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
            if (absTick & 0x4 != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
            if (absTick & 0x8 != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
            if (absTick & 0x10 != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
            if (absTick & 0x20 != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
            if (absTick & 0x40 != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
            if (absTick & 0x80 != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
            if (absTick & 0x100 != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
            if (absTick & 0x200 != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
            if (absTick & 0x400 != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
            if (absTick & 0x800 != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
            if (absTick & 0x1000 != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
            if (absTick & 0x2000 != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
            if (absTick & 0x4000 != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
            if (absTick & 0x8000 != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
            if (absTick & 0x10000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
            if (absTick & 0x20000 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
            if (absTick & 0x40000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
            if (absTick & 0x80000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;

            // The table above computes the ratio for a NEGATIVE tick. A positive
            // one is its reciprocal.
            if (tick > 0) ratio = type(uint256).max / ratio;

            // Q128.128 down to Q64.96, rounding up. Truncating instead would put
            // some results one ULP below the value `getTickAtSqrtRatio` maps
            // back to this tick, which is the invariant the whole library is
            // built around even though nothing here calls the inverse.
            sqrtPriceX96 = uint160((ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1));
        }
    }
}

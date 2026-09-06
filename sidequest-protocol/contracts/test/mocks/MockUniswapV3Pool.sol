// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice A Uniswap V3 pool with every quantity the TWAP adapter guards on
///         made settable, so each guard can be triggered on its own.
///
///         WHY THIS EXISTS WHEN THERE IS A FORK TEST
///
///         A fork test cannot exercise the guards. The live NVDA/USDG pool is
///         deep, busy and well-observed -- which is the entire reason it was
///         chosen -- so on a fork the liquidity, cardinality and observation-age
///         checks are permanently satisfied and therefore permanently untested.
///         Draining a real pool's liquidity inside a test to prove a floor works
///         is not something a fork can do cheaply or repeatably.
///
///         So the division of labour is: this mock proves each guard fires on
///         its own trigger and only its own trigger, and the fork test proves
///         the happy path against a real pool with real depth. Neither is
///         sufficient alone.
contract MockUniswapV3Pool {
    address public immutable token0;
    address public immutable token1;

    int24 public tick;
    uint128 public liquidity = 50e18;
    uint16 public cardinality = 6000;
    uint16 public observationIndex = 1;
    /// @notice How far in the past the newest observation was written.
    uint32 public observationAge;
    bool public observeReverts;

    int56 private olderCumulative;
    int56 private newerCumulative;

    // Per-slot overrides, so code that computes WHICH slot to read can be
    // tested. Without these the ring is uniform and an index bug is invisible.
    mapping(uint256 => uint32) private ageAt;
    mapping(uint256 => bool) private ageSetAt;
    mapping(uint256 => bool) private uninitializedAt;

    // An explicit cumulative series, for callers that need a price that MOVES
    // across the span rather than a constant one.
    int56[] private series;
    bool private useSeries;

    constructor(address token0_, address token1_) {
        token0 = token0_;
        token1 = token1_;
    }

    /// @notice Override one slot's age, leaving every other slot on the global
    ///         `observationAge`.
    function setObservationAgeAt(uint256 index, uint32 age) external {
        ageAt[index] = age;
        ageSetAt[index] = true;
    }

    /// @notice Mark one slot as never written, which is what an unfilled ring
    ///         buffer looks like beyond its high-water mark.
    function setObservationUninitialized(uint256 index, bool v) external {
        uninitializedAt[index] = v;
    }

    /// @notice Return these cumulatives verbatim from `observe`, oldest first,
    ///         instead of interpolating between two endpoints.
    function setCumulativeSeries(int56[] calldata s) external {
        series = s;
        useSeries = true;
    }

    function clearCumulativeSeries() external { useSeries = false; }

    function setTick(int24 t) external { tick = t; }
    function setLiquidity(uint128 l) external { liquidity = l; }
    function setCardinality(uint16 c) external { cardinality = c; }
    function setObservationIndex(uint16 i) external { observationIndex = i; }
    function setObserveReverts(bool r) external { observeReverts = r; }

    /// @dev Callers must `vm.warp` past this value first. The subtraction in
    ///      `observations` is checked on purpose: forge starts at
    ///      `block.timestamp == 1`, so a test that forgets to warp would
    ///      otherwise get a silently wrong age instead of a loud revert.
    function setObservationAge(uint32 a) external { observationAge = a; }

    /// @notice Set the two tick cumulatives `observe` returns, oldest first.
    function setTickCumulatives(int56 older, int56 newer) external {
        olderCumulative = older;
        newerCumulative = newer;
    }

    /// @notice Set both cumulatives so the mean tick over `window` is exactly
    ///         `meanTick`.
    function setMeanTick(int24 meanTick, uint32 window) external {
        olderCumulative = 0;
        newerCumulative = int56(meanTick) * int56(uint56(window));
    }

    function slot0()
        external
        view
        returns (uint160, int24, uint16, uint16, uint16, uint8, bool)
    {
        // sqrtPriceX96 is deliberately zero. The adapter derives spot from the
        // TICK and must never read this field; returning a plausible-looking
        // value here would hide it if that ever changed.
        return (0, tick, observationIndex, cardinality, cardinality, 0, true);
    }

    /// @dev Slots read uniformly from `observationAge` unless one has been
    ///      overridden. The override exists so that code choosing WHICH slot to
    ///      read is actually tested: on a uniform ring, an off-by-one in
    ///      `(index + 1) % cardinality` returns the right answer for the wrong
    ///      reason and no test notices.
    function observations(uint256 index)
        external
        view
        returns (uint32 blockTimestamp, int56 tickCumulative, uint160 secondsPerLiquidityX128, bool initialized)
    {
        uint32 age = ageSetAt[index] ? ageAt[index] : observationAge;
        return (uint32(block.timestamp) - age, newerCumulative, 0, !uninitializedAt[index]);
    }

    /// @dev Interpolates linearly between the two configured cumulatives, which
    ///      is what a constant tick across the whole span produces. Assumes
    ///      `secondsAgos` is evenly spaced -- true of every caller here, and the
    ///      point of the mock is the guards, not reproducing Uniswap's
    ///      accumulator.
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityX128s)
    {
        if (observeReverts) revert("OLD");

        uint256 n = secondsAgos.length;
        tickCumulatives = new int56[](n);
        secondsPerLiquidityX128s = new uint160[](n);

        if (useSeries) {
            require(series.length == n, "MockUniswapV3Pool: series length");
            for (uint256 i = 0; i < n; i++) tickCumulatives[i] = series[i];
            return (tickCumulatives, secondsPerLiquidityX128s);
        }

        int56 span = newerCumulative - olderCumulative;
        for (uint256 i = 0; i < n; i++) {
            if (i == 0) tickCumulatives[i] = olderCumulative;
            else if (i == n - 1) tickCumulatives[i] = newerCumulative;
            else tickCumulatives[i] = olderCumulative + (span * int56(uint56(i))) / int56(uint56(n - 1));
        }
    }
}

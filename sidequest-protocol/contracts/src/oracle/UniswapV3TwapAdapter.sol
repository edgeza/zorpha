// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {AggregatorV3Interface} from "./MedianOracle.sol";
import {TickMath} from "../lib/TickMath.sol";

/// @notice The slice of a Uniswap V3 pool this adapter reads.
///
///         Declared here rather than imported for the same reason TickMath is
///         vendored: v3-core does not compile under 0.8.x. Only the six views
///         that are actually called are listed, so the interface cannot drift
///         into claiming the pool has functions nothing here has checked for.
interface IUniswapV3PoolMinimal {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function liquidity() external view returns (uint128);
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
    function observations(uint256 index)
        external
        view
        returns (
            uint32 blockTimestamp,
            int56 tickCumulative,
            uint160 secondsPerLiquidityCumulativeX128,
            bool initialized
        );
}

/// @title UniswapV3TwapAdapter
/// @notice A Chainlink-shaped price feed with no off-chain component: the
///         answer is a time-weighted average of a pool's own tick history.
///
///         WHY THIS AND NOT AN ORACLE
///
///         Robinhood Chain carries no price feed, and the two vaults that need
///         one were left off mainnet rather than staffed with a keeper holding
///         a live signing key forever. This removes the requirement instead of
///         meeting it.
///
///         The property that makes it BETTER than a feed here, rather than a
///         substitute for one: NAV reads the same pool the trades clear
///         against. A price move that fools the vault's accounting also gives
///         the attacker a bad fill, so the two halves of the classic oracle
///         exploit become the same action and cancel out. That is only
///         available because these equities trade on-chain with eight figures
///         of depth -- measured 6 September 2026, the NVDA/USDG 0.05% pool
///         moved 0.66% on a one-million-dollar single trade, and decayed the
///         moment it stopped.
///
///         WHAT IT DELIBERATELY DOES NOT HAVE
///
///         `maxStaleness()`. `OracleWindow.requireNotTighterThan` probes for it
///         by staticcall and treats its absence as "not one of ours, invariant
///         unenforceable" -- the same branch a real Chainlink feed takes. That
///         classification is correct rather than a gap: the bug that library
///         exists to prevent is a property of multi-reporter median freshness,
///         and a TWAP has no reporters. Adding the getter here would enforce an
///         invariant that does not apply. Do not add it.
contract UniswapV3TwapAdapter is AggregatorV3Interface {
    /// @dev Chainlink convention, and what `RWRotationVault` documents. The
    ///      vault reads this once at construction and scales every conversion
    ///      by it, so it is not free to change.
    uint8 private constant ANSWER_DECIMALS = 8;
    uint256 private constant ANSWER_SCALE = 1e8;
    uint256 private constant Q96 = 1 << 96;
    uint256 private constant BPS = 10000;

    IUniswapV3PoolMinimal public immutable pool;
    address public immutable base;
    address public immutable quote;

    /// @notice True when `base` is the pool's token0.
    /// @dev    Derived by comparison against the pool at construction, never
    ///         taken on the deployer's word. See the constructor.
    bool public immutable baseIsToken0;

    uint8 public immutable baseDecimals;
    uint8 public immutable quoteDecimals;

    uint32 public immutable twapWindow;
    uint16 public immutable minCardinality;
    uint128 public immutable minLiquidity;
    uint32 public immutable maxObservationAge;
    uint16 public immutable maxSpotDivergenceBps;

    error PoolTokenMismatch(address token0, address token1);
    error InsufficientCardinality(uint16 have, uint16 need);
    error InsufficientLiquidity(uint128 have, uint128 need);
    error ObservationTooOld(uint32 ageSeconds, uint32 maxAgeSeconds);
    error SpotDivergesFromTwap(uint256 twapAnswer, uint256 spotAnswer, uint256 divergenceBps);
    error InvalidAnswer(uint256 answer);
    error BadWindowSeries();

    /// @param pool_                 the Uniswap V3 pool to read
    /// @param base_                 the token being priced
    /// @param quote_                the token it is priced in
    /// @param twapWindow_           seconds to average over
    /// @param minCardinality_       refuse below this observation cardinality
    /// @param minLiquidity_         refuse below this in-range liquidity
    /// @param maxObservationAge_    refuse if the newest observation is older
    /// @param maxSpotDivergenceBps_ refuse if spot is further than this from the average
    constructor(
        address pool_,
        address base_,
        address quote_,
        uint32 twapWindow_,
        uint16 minCardinality_,
        uint128 minLiquidity_,
        uint32 maxObservationAge_,
        uint16 maxSpotDivergenceBps_
    ) {
        require(pool_ != address(0) && base_ != address(0) && quote_ != address(0), "zero addr");
        require(base_ != quote_, "same token");
        // Zero would make the mean-tick division divide by zero at the first
        // price read rather than here.
        require(twapWindow_ > 0, "zero window");
        // Zero would reject every observation, including one written in this
        // very block, so the adapter would never answer at all.
        require(maxObservationAge_ > 0, "zero max age");
        require(maxSpotDivergenceBps_ > 0 && maxSpotDivergenceBps_ <= BPS, "bad bps");

        IUniswapV3PoolMinimal p = IUniswapV3PoolMinimal(pool_);
        address t0 = p.token0();
        address t1 = p.token1();

        // THE CHECK THAT CANNOT BE SKIPPED.
        //
        // A Uniswap tick expresses token1/token0. Which of `base` and `quote`
        // is which decides whether the price arithmetic inverts, and getting
        // that wrong produces 0.0043 where 231.35 belongs: a plausible-looking
        // number that would price every rebalance wrongly and revert nothing.
        //
        // So the flag is DERIVED from the pool in order, not accepted as an
        // argument. Naming the pair the other way round stays legal -- it means
        // "the price of USDG in NVDA", which is a real quantity -- and the flag
        // simply flips to match. What is impossible is a mismatch between the
        // branch taken and the pool's actual token order.
        bool isToken0;
        if (base_ == t0 && quote_ == t1) isToken0 = true;
        else if (base_ == t1 && quote_ == t0) isToken0 = false;
        else revert PoolTokenMismatch(t0, t1);
        baseIsToken0 = isToken0;

        pool = p;
        base = base_;
        quote = quote_;
        baseDecimals = IERC20Metadata(base_).decimals();
        quoteDecimals = IERC20Metadata(quote_).decimals();

        twapWindow = twapWindow_;
        minCardinality = minCardinality_;
        minLiquidity = minLiquidity_;
        maxObservationAge = maxObservationAge_;
        maxSpotDivergenceBps = maxSpotDivergenceBps_;
    }

    /// @notice Decimals of the answer, matching the Chainlink convention the
    ///         consuming vault already assumes.
    function decimals() external pure override returns (uint8) {
        return ANSWER_DECIMALS;
    }

    /// @notice The price of one whole `base` token in whole `quote` units, at
    ///         `ANSWER_DECIMALS`, for an arbitrary tick.
    ///
    ///         Public because the fork test compares it against a TWAP computed
    ///         independently from the pool's raw cumulatives, and because the
    ///         charting view and `latestRoundData` must demonstrably share one
    ///         implementation rather than two that happen to agree today.
    ///
    ///         DIRECTION. `SpotVaultMinimal.assetToCash` is
    ///         `assetAmt * 10^cashDec * p / (10^assetDec * 10^priceDec)`, so `p`
    ///         is quote-per-base. A Uniswap tick expresses token1/token0 in RAW
    ///         units, so when base is token1 it is the reciprocal of what the
    ///         vault wants AND both decimal scalings apply. Worked at tick
    ///         221,882 with token0 = USDG (6dp), token1 = NVDA (18dp):
    ///
    ///             raw token1/token0     1.0001^221882    = 4.3225e9
    ///             NVDA per USDG         x 10^6 / 10^18   = 0.00432246
    ///             USDG per NVDA         reciprocal       = 231.349708
    ///             answer at 1e8                          = 23,134,970,771
    ///
    ///         Neither branch forms `sqrtP * sqrtP` as a plain product: that
    ///         overflows uint256 above roughly tick 500,000. `Math.mulDiv`
    ///         carries the 512-bit intermediate instead, so both branches are
    ///         exact to within a single truncation.
    function answerAtTick(int24 tick) public view returns (uint256) {
        uint256 sqrtP = uint256(TickMath.getSqrtRatioAtTick(tick));
        uint256 baseUnit = 10 ** baseDecimals;
        uint256 quoteUnit = 10 ** quoteDecimals;

        if (baseIsToken0) {
            // token1/token0 is already quote-raw per base-raw. Scale directly.
            uint256 ratioX96 = Math.mulDiv(sqrtP, sqrtP, Q96);
            return Math.mulDiv(ratioX96, baseUnit * ANSWER_SCALE, Q96 * quoteUnit);
        }
        // base is token1, so invert first, then scale.
        uint256 inverseX96 = Math.mulDiv(Q96, Q96, sqrtP);
        return Math.mulDiv(inverseX96, baseUnit * ANSWER_SCALE, sqrtP * quoteUnit);
    }

    /// @notice The arithmetic mean tick over `twapWindow`, from the pool's own
    ///         observation history.
    function meanTick() public view returns (int24) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapWindow;
        secondsAgos[1] = 0;

        (int56[] memory cumulatives, ) = pool.observe(secondsAgos);
        int56 delta = cumulatives[1] - cumulatives[0];
        int56 window = int56(uint56(twapWindow));

        int24 mean = int24(delta / window);
        // Solidity truncates toward zero; Uniswap's OracleLibrary floors. They
        // differ only for a negative delta with a remainder. One tick is one
        // basis point of price, so the gap is small -- but it is a one-sided
        // bias on falling prices only, and matching the reference costs nothing.
        if (delta < 0 && (delta % window != 0)) mean--;
        return mean;
    }

    /// @notice The latest price, in Chainlink's shape.
    /// @dev    `updatedAt` is `block.timestamp` because that is the truth: a
    ///         TWAP is computed at call time from history and is never stale in
    ///         the sense `MedianOracle.updatedAt` carries. The real staleness
    ///         risk for a TWAP is a pool nobody is trading, which `updatedAt`
    ///         cannot express and which the observation-age guard handles.
    ///
    ///         `roundId` and `answeredInRound` are both 1 so the vault's
    ///         `answeredInRound < roundId` check passes. There are no rounds.
    ///
    ///         EVERY GUARD REVERTS. A failure here stops a rebalance rather
    ///         than pricing one wrongly, which is the point: `_oraclePrice` is
    ///         the only path into `rebalanceTo`, so refusing to answer is
    ///         refusing to trade.
    ///
    ///         ORDER IS LOAD-BEARING. The three cheap checks all run before
    ///         anything calls `observe`, because a pool that cannot serve the
    ///         requested window reverts with a bare "OLD" that names nothing an
    ///         operator can act on. Running them first turns each diagnosable
    ///         condition into a typed error carrying both numbers.
    ///
    ///         KNOWN GAP, stated because it is real rather than because it is
    ///         handled: cardinality is the buffer's SIZE, not its time span. A
    ///         pool holding 300 observations that between them cover a few
    ///         minutes cannot serve a 30-minute window, and that case still
    ///         arrives as "OLD". It is fail-closed -- the vault refuses either
    ///         way -- so it costs diagnosis, not safety.
    function latestRoundData()
        external
        view
        override
        returns (uint80, int256, uint256, uint256, uint80)
    {
        (, int24 spotTick, uint16 observationIndex, uint16 cardinality, , , ) = pool.slot0();

        // 1. HISTORY. A pool at cardinality 1 keeps a single observation and
        //    cannot answer a windowed query at all. SPY/USDG 0.01% and
        //    ZOR/USDG both sit there today.
        if (cardinality < minCardinality) revert InsufficientCardinality(cardinality, minCardinality);

        // 2. DEPTH. This is what makes the average expensive to move, so its
        //    draining away is the condition under which every other guarantee
        //    here weakens. Note `liquidity()` is IN-RANGE liquidity and moves as
        //    positions enter and leave range, so the floor is set well below the
        //    observed value rather than just under it.
        uint128 liq = pool.liquidity();
        if (liq < minLiquidity) revert InsufficientLiquidity(liq, minLiquidity);

        // 3. ACTIVITY. On a quiet pool `observe` extrapolates the last tick
        //    forward, so it returns a confident price nobody has traded at.
        //    The subtraction is unchecked because the pool stores timestamps
        //    truncated to uint32: wrapping subtraction is the correct
        //    arithmetic there, and is what Uniswap itself does. A wrapped clock
        //    yields a huge age and therefore a revert, which is fail-closed.
        (uint32 lastObservedAt, , , ) = pool.observations(observationIndex);
        uint32 age;
        unchecked { age = uint32(block.timestamp) - lastObservedAt; }
        if (age > maxObservationAge) revert ObservationTooOld(age, maxObservationAge);

        uint256 twapAnswer = answerAtTick(meanTick());
        uint256 spotAnswer = answerAtTick(spotTick);

        // 5. SANITY, before 4, because a zero denominator cannot be divided by.
        //    Not hypothetical: a 6-decimal base against an 18-decimal quote
        //    computes to zero at any plausible tick, because one whole unit buys
        //    1e-12 of the other and that does not survive 1e8 scaling. Such a
        //    pair is refused at the first read rather than reported as free.
        if (twapAnswer == 0 || twapAnswer > uint256(type(int256).max)) revert InvalidAnswer(twapAnswer);
        if (spotAnswer == 0) revert InvalidAnswer(spotAnswer);

        // 4. MANIPULATION, and a market-condition check besides: a 2% gap
        //    between spot and a 30-minute average is a moment a fund should not
        //    be rebalancing, whatever the cause. `Math.mulDiv` rather than
        //    `diff * BPS / twapAnswer` so the intermediate cannot overflow at
        //    the top of the range the sanity check above permits.
        uint256 diff = twapAnswer > spotAnswer ? twapAnswer - spotAnswer : spotAnswer - twapAnswer;
        uint256 divergenceBps = Math.mulDiv(diff, BPS, twapAnswer);
        if (divergenceBps > maxSpotDivergenceBps) {
            revert SpotDivergesFromTwap(twapAnswer, spotAnswer, divergenceBps);
        }

        return (1, int256(twapAnswer), block.timestamp, block.timestamp, 1);
    }

    /// @notice The price over each of a series of consecutive intervals, for
    ///         charting.
    ///
    ///         DELIBERATELY UNGUARDED. None of the five checks in
    ///         `latestRoundData` runs here, and that is the point: a chart is
    ///         not NAV. A manager whose rebalance has just been refused because
    ///         spot diverged from the average is exactly the person who needs to
    ///         see what the price has been doing, and a guarded view would go
    ///         blank at that moment. Nothing that moves funds may call this.
    ///
    ///         Reading the series from the adapter rather than recomputing tick
    ///         maths in a browser means the chart and the vault's own NAV cannot
    ///         disagree: there is one implementation of the arithmetic, and a
    ///         test asserts the two return the same number for the same window.
    ///
    /// @param  secondsAgos Strictly decreasing, ending at 0, at least two
    ///         entries. Strictly, because equal neighbours are a zero-length
    ///         interval and therefore a division by zero.
    /// @return answers One per adjacent pair, `secondsAgos.length - 1` of them,
    ///         OLDEST INTERVAL FIRST, matching the order of the input.
    function answersOverWindows(uint32[] calldata secondsAgos)
        external
        view
        returns (uint256[] memory answers)
    {
        uint256 n = secondsAgos.length;
        if (n < 2) revert BadWindowSeries();
        if (secondsAgos[n - 1] != 0) revert BadWindowSeries();
        for (uint256 i = 1; i < n; i++) {
            if (secondsAgos[i] >= secondsAgos[i - 1]) revert BadWindowSeries();
        }

        (int56[] memory cumulatives, ) = pool.observe(secondsAgos);

        answers = new uint256[](n - 1);
        for (uint256 i = 0; i < n - 1; i++) {
            // Positive by the strictly-decreasing check above.
            int56 span = int56(uint56(secondsAgos[i] - secondsAgos[i + 1]));
            int56 delta = cumulatives[i + 1] - cumulatives[i];
            int24 mean = int24(delta / span);
            if (delta < 0 && (delta % span != 0)) mean--;
            answers[i] = answerAtTick(mean);
        }
    }

    /// @notice How far back the pool's observation ring buffer reaches.
    ///
    ///         `observe` reverts with a bare "OLD" for any `secondsAgo` beyond
    ///         this, so a caller building a chart must clamp its horizon to what
    ///         this returns rather than guessing a horizon and retrying.
    ///
    ///         The oldest slot is the one AFTER the newest, because the ring
    ///         overwrites forward. A ring that has not filled yet has nothing
    ///         there: Uniswap leaves those slots uninitialised, and their zero
    ///         timestamp would read as a buffer stretching back to 1970. Slot 0
    ///         is written when the pool is created, so it is the fallback.
    function oldestObservationSecondsAgo() external view returns (uint32) {
        (, , uint16 index, uint16 cardinality, , , ) = pool.slot0();
        uint256 oldest = cardinality == 0 ? 0 : (uint256(index) + 1) % uint256(cardinality);

        (uint32 ts, , , bool initialized) = pool.observations(oldest);
        if (!initialized) (ts, , , ) = pool.observations(0);

        // Wrapping subtraction, matching the pool's own truncated clock.
        unchecked { return uint32(block.timestamp) - ts; }
    }
}

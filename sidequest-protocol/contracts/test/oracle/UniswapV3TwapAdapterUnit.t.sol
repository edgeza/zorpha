// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {UniswapV3TwapAdapter} from "../../src/oracle/UniswapV3TwapAdapter.sol";
import {MockUniswapV3Pool} from "../mocks/MockUniswapV3Pool.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice The TWAP adapter against a pool whose every guarded quantity can be
///         moved, which is the only place the guards can actually be tested.
contract UniswapV3TwapAdapterUnitTest is Test {
    // Mirrors the live pool's shape exactly: token0 is the 6dp quote, token1
    // the 18dp base. Getting this backwards in the fixture would make every
    // decimals assertion below agree with the wrong thing.
    MockERC20 usdg;   // token0, quote, 6dp
    MockERC20 nvda;   // token1, base,  18dp
    MockUniswapV3Pool pool;

    uint32 constant WINDOW = 1800;
    uint16 constant MIN_CARDINALITY = 300;
    uint128 constant MIN_LIQUIDITY = 12e18;
    uint32 constant MAX_OBS_AGE = 4 hours;
    uint16 constant MAX_DIVERGENCE_BPS = 200;

    function setUp() public {
        // Forge starts at block.timestamp == 1, and the mock computes an
        // observation's timestamp by subtracting an age from now. Without a warp
        // that subtraction underflows and every guard test fails inside the
        // fixture rather than in the code under test.
        vm.warp(1788713101);

        usdg = new MockERC20("USDG", "USDG", 6);
        nvda = new MockERC20("NVDA", "NVDA", 18);
        pool = new MockUniswapV3Pool(address(usdg), address(nvda));
    }

    function _deploy(address base_, address quote_) internal returns (UniswapV3TwapAdapter) {
        return new UniswapV3TwapAdapter(
            address(pool), base_, quote_,
            WINDOW, MIN_CARDINALITY, MIN_LIQUIDITY, MAX_OBS_AGE, MAX_DIVERGENCE_BPS
        );
    }

    // --- construction -------------------------------------------------------

    function test_Constructor_RecordsOrderingAndDecimals() public {
        UniswapV3TwapAdapter a = _deploy(address(nvda), address(usdg));
        assertEq(a.base(), address(nvda));
        assertEq(a.quote(), address(usdg));
        assertFalse(a.baseIsToken0(), "NVDA is token1 in this pool");
        assertEq(a.baseDecimals(), 18);
        assertEq(a.quoteDecimals(), 6);
        assertEq(a.decimals(), 8, "the vault reads this to scale every conversion");
        assertEq(address(a.pool()), address(pool));
        assertEq(a.twapWindow(), WINDOW);
        assertEq(a.minCardinality(), MIN_CARDINALITY);
        assertEq(a.minLiquidity(), MIN_LIQUIDITY);
        assertEq(a.maxObservationAge(), MAX_OBS_AGE);
        assertEq(a.maxSpotDivergenceBps(), MAX_DIVERGENCE_BPS);
    }

    /// The other branch of the ordering check: a pool where the base really is
    /// token0.
    function test_Constructor_AcceptsBaseAsToken0() public {
        MockUniswapV3Pool flipped = new MockUniswapV3Pool(address(nvda), address(usdg));
        UniswapV3TwapAdapter a = new UniswapV3TwapAdapter(
            address(flipped), address(nvda), address(usdg),
            WINDOW, MIN_CARDINALITY, MIN_LIQUIDITY, MAX_OBS_AGE, MAX_DIVERGENCE_BPS
        );
        assertTrue(a.baseIsToken0(), "NVDA is token0 in the flipped pool");
    }

    /// WHAT THE ORDERING ASSERTION DOES AND DOES NOT PROMISE.
    ///
    /// Naming the pair the other way round is LEGAL and does not revert: it
    /// means "the price of USDG in NVDA", which is a real quantity, and the
    /// flag flips to match. What the constructor guarantees is narrower and
    /// more useful -- that the ARITHMETIC BRANCH always matches the pool's real
    /// token order, so the adapter can never compute a reciprocal by accident.
    /// That is the bug this class of contract actually ships: 0.0043 where
    /// 231.35 belongs, a plausible number that prices every rebalance wrongly
    /// and reverts nothing.
    ///
    /// A deployer who genuinely meant NVDA-in-USDG and typed the arguments the
    /// other way round is NOT caught here, because both orderings describe a
    /// real pair. That is caught by the deploy script reading the answer back
    /// and printing `baseIsToken0` and `assetToCash(1e18)` before anyone signs.
    function test_Constructor_ReversingTheDirectionFlipsTheFlagRatherThanReverting() public {
        UniswapV3TwapAdapter forward = _deploy(address(nvda), address(usdg));
        UniswapV3TwapAdapter reverse = _deploy(address(usdg), address(nvda));

        assertFalse(forward.baseIsToken0(), "NVDA priced in USDG");
        assertTrue(reverse.baseIsToken0(), "USDG priced in NVDA");
        assertEq(forward.base(), reverse.quote());
        assertEq(forward.quote(), reverse.base());
    }

    function test_Constructor_RevertsWhenATokenIsNotInThePool() public {
        MockERC20 spy = new MockERC20("SPY", "SPY", 18);
        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapV3TwapAdapter.PoolTokenMismatch.selector, address(usdg), address(nvda)
            )
        );
        _deploy(address(spy), address(usdg));
    }

    /// Both tokens real, both in the pool, but paired with an outsider.
    function test_Constructor_RevertsWhenOnlyOneTokenBelongsToThePool() public {
        MockERC20 spy = new MockERC20("SPY", "SPY", 18);
        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapV3TwapAdapter.PoolTokenMismatch.selector, address(usdg), address(nvda)
            )
        );
        _deploy(address(nvda), address(spy));
    }

    function test_Constructor_RevertsOnZeroPool() public {
        vm.expectRevert(bytes("zero addr"));
        new UniswapV3TwapAdapter(
            address(0), address(nvda), address(usdg),
            WINDOW, MIN_CARDINALITY, MIN_LIQUIDITY, MAX_OBS_AGE, MAX_DIVERGENCE_BPS
        );
    }

    function test_Constructor_RevertsOnZeroBase() public {
        vm.expectRevert(bytes("zero addr"));
        _deploy(address(0), address(usdg));
    }

    function test_Constructor_RevertsOnZeroQuote() public {
        vm.expectRevert(bytes("zero addr"));
        _deploy(address(nvda), address(0));
    }

    function test_Constructor_RevertsOnTheSameTokenTwice() public {
        vm.expectRevert(bytes("same token"));
        _deploy(address(nvda), address(nvda));
    }

    /// A zero window makes `meanTick` divide by zero, so it has to be refused at
    /// construction rather than at the first price read.
    function test_Constructor_RevertsOnZeroWindow() public {
        vm.expectRevert(bytes("zero window"));
        new UniswapV3TwapAdapter(
            address(pool), address(nvda), address(usdg),
            0, MIN_CARDINALITY, MIN_LIQUIDITY, MAX_OBS_AGE, MAX_DIVERGENCE_BPS
        );
    }

    /// A zero max age would reject every observation, including one written in
    /// this very block, so the adapter would never answer at all.
    function test_Constructor_RevertsOnZeroMaxObservationAge() public {
        vm.expectRevert(bytes("zero max age"));
        new UniswapV3TwapAdapter(
            address(pool), address(nvda), address(usdg),
            WINDOW, MIN_CARDINALITY, MIN_LIQUIDITY, 0, MAX_DIVERGENCE_BPS
        );
    }

    function test_Constructor_RevertsOnZeroDivergenceTolerance() public {
        vm.expectRevert(bytes("bad bps"));
        new UniswapV3TwapAdapter(
            address(pool), address(nvda), address(usdg),
            WINDOW, MIN_CARDINALITY, MIN_LIQUIDITY, MAX_OBS_AGE, 0
        );
    }

    function test_Constructor_RevertsOnDivergenceToleranceAboveOneHundredPercent() public {
        vm.expectRevert(bytes("bad bps"));
        new UniswapV3TwapAdapter(
            address(pool), address(nvda), address(usdg),
            WINDOW, MIN_CARDINALITY, MIN_LIQUIDITY, MAX_OBS_AGE, 10001
        );
    }

    // --- price arithmetic ---------------------------------------------------

    /// The spec's worked example, to the unit.
    ///
    /// tick 221,882 on a pool with token0 = USDG (6dp) and token1 = NVDA (18dp)
    /// is 231.349708 USDG per NVDA, which at 1e8 is 23,134,970,771. That figure
    /// was derived off-chain from 1.0001^221882 at 60 significant digits, and is
    /// asserted EXACTLY rather than approximately, so a change to the arithmetic
    /// cannot quietly agree with itself.
    ///
    /// NOTE FOR ANYONE COMPARING THIS AGAINST THE FORK TEST. Reading the live
    /// pool's slot0 gives sqrtPriceX96 = 5209002981863638722623952383317079,
    /// which works out to 23,133,958,672 -- 0.0044% below this. Both are
    /// correct; they answer different questions. A pool's price sits somewhere
    /// INSIDE a tick, while `getSqrtRatioAtTick` returns that tick's lower
    /// boundary. The gap is bounded by one tick, which is one basis point.
    function test_AnswerAtTick_MatchesTheWorkedExample() public {
        UniswapV3TwapAdapter a = _deploy(address(nvda), address(usdg));
        assertEq(a.answerAtTick(221882), 23134970771, "USDG per NVDA at 1e8");
    }

    /// Flipping which token is base must INVERT the answer, not shift it by a
    /// power of ten. This is the test that catches a decimals bug a
    /// single-direction test passes: get the 18/6 scaling wrong in one branch
    /// and the forward answer still looks like a plausible share price.
    function test_AnswerAtTick_IsReciprocalWhenBaseAndQuoteSwap() public {
        UniswapV3TwapAdapter nvdaInUsdg = _deploy(address(nvda), address(usdg));
        UniswapV3TwapAdapter usdgInNvda = _deploy(address(usdg), address(nvda));

        uint256 forward = nvdaInUsdg.answerAtTick(221882);   // 231.349708e8
        uint256 backward = usdgInNvda.answerAtTick(221882);  // 0.00432246e8

        assertEq(forward, 23134970771);
        assertEq(backward, 432246);
        // Both are 1e8-scaled, so a value times its reciprocal is (1e8)^2.
        // Measured truncation error across the four mulDivs is 1.4e-7.
        assertApproxEqRel(forward * backward, 1e16, 1e13, "not reciprocal");
    }

    /// Decimal scaling, isolated from the tick maths entirely.
    ///
    /// At tick 0 the sqrt ratio is exactly 2^96, so the raw token1/token0 ratio
    /// is exactly 1 and every digit of the answer comes from the decimal
    /// adjustment. Anything wrong in the 18/6/8 handling shows up here as a
    /// clean power of ten rather than as a plausible price.
    function test_AnswerAtTick_DecimalScalingAtUnityRatio() public {
        // 18dp base, 6dp quote. One NVDA-wei buys one USDG-microunit, so one
        // whole NVDA (1e18 wei) buys 1e18 microunits = 1e12 USDG. At 1e8: 1e20.
        UniswapV3TwapAdapter a = _deploy(address(nvda), address(usdg));
        assertEq(a.answerAtTick(0), 1e20, "18dp base against 6dp quote");

        // The inverse: one whole USDG buys 1e-12 NVDA, which at 1e8 rounds to
        // zero. Arithmetically right, and precisely why latestRoundData carries
        // a sanity guard rather than trusting the arithmetic to be positive.
        UniswapV3TwapAdapter b = _deploy(address(usdg), address(nvda));
        assertEq(b.answerAtTick(0), 0, "6dp base against 18dp quote underflows 1e8");
    }

    /// Matched decimals need no adjustment at all, so unity ratio is exactly 1e8.
    function test_AnswerAtTick_MatchedDecimalsNeedNoAdjustment() public {
        MockERC20 a18 = new MockERC20("A", "A", 18);
        MockERC20 b18 = new MockERC20("B", "B", 18);
        MockUniswapV3Pool p = new MockUniswapV3Pool(address(a18), address(b18));
        UniswapV3TwapAdapter a = new UniswapV3TwapAdapter(
            address(p), address(b18), address(a18),
            WINDOW, MIN_CARDINALITY, MIN_LIQUIDITY, MAX_OBS_AGE, MAX_DIVERGENCE_BPS
        );
        assertEq(a.answerAtTick(0), 1e8, "matched decimals at unity ratio");
    }

    // --- the mean tick ------------------------------------------------------

    function test_MeanTick_AveragesTheCumulatives() public {
        UniswapV3TwapAdapter a = _deploy(address(nvda), address(usdg));
        pool.setMeanTick(221882, WINDOW);
        assertEq(a.meanTick(), int24(221882));
    }

    function _shortWindow() internal returns (UniswapV3TwapAdapter) {
        return new UniswapV3TwapAdapter(
            address(pool), address(nvda), address(usdg),
            2, MIN_CARDINALITY, MIN_LIQUIDITY, MAX_OBS_AGE, MAX_DIVERGENCE_BPS
        );
    }

    /// Solidity truncates integer division toward zero; Uniswap's OracleLibrary
    /// floors. They differ only for a NEGATIVE delta with a remainder.
    /// delta = -5 over a window of 2 is -2.5: truncation gives -2, floor -3.
    function test_MeanTick_FloorsNegativeDeltas() public {
        UniswapV3TwapAdapter a = _shortWindow();
        pool.setTickCumulatives(int56(0), int56(-5));
        assertEq(a.meanTick(), int24(-3), "must floor, not truncate");
    }

    /// And must NOT adjust a positive delta, where truncation already floors.
    /// Getting this wrong is a silent one-tick bias on every upward move.
    function test_MeanTick_LeavesPositiveDeltasAlone() public {
        UniswapV3TwapAdapter a = _shortWindow();
        pool.setTickCumulatives(int56(0), int56(5));
        assertEq(a.meanTick(), int24(2), "floor(2.5) is 2");
    }

    /// An exact negative division has no remainder, so no adjustment either.
    function test_MeanTick_ExactNegativeDivisionIsNotAdjusted() public {
        UniswapV3TwapAdapter a = _shortWindow();
        pool.setTickCumulatives(int56(0), int56(-6));
        assertEq(a.meanTick(), int24(-3), "floor(-3.0) is -3");
    }

    // --- latestRoundData ----------------------------------------------------

    function test_LatestRoundData_ReportsTheTwapAndTheCurrentTimestamp() public {
        UniswapV3TwapAdapter a = _deploy(address(nvda), address(usdg));
        pool.setTick(221882);
        pool.setMeanTick(221882, WINDOW);

        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
            = a.latestRoundData();

        assertEq(roundId, 1);
        assertEq(answeredInRound, 1);
        assertEq(startedAt, block.timestamp);
        assertEq(updatedAt, block.timestamp, "a TWAP is computed now, from history");
        assertEq(uint256(answer), 23134970771);
    }

    /// The answer must track the AVERAGE, not spot. Moving spot alone, within
    /// the divergence tolerance, must not move what is reported.
    function test_LatestRoundData_ReportsTheAverageAndNotSpot() public {
        UniswapV3TwapAdapter a = _deploy(address(nvda), address(usdg));
        pool.setMeanTick(221882, WINDOW);

        pool.setTick(221882);
        (, int256 atMean, , , ) = a.latestRoundData();
        pool.setTick(221882 + 100); // 99.5 bps away, inside the tolerance
        (, int256 spotMoved, , , ) = a.latestRoundData();

        assertEq(spotMoved, atMean, "spot moved; the reported average must not");
    }

    /// The exact shape `SpotVaultMinimal._oraclePrice` checks before it will
    /// price anything: a positive answer, answeredInRound not below roundId,
    /// and a non-zero updatedAt inside the vault's staleness window.
    function test_LatestRoundData_SatisfiesTheVaultsFreshnessChecks() public {
        UniswapV3TwapAdapter a = _deploy(address(nvda), address(usdg));
        pool.setTick(221882);
        pool.setMeanTick(221882, WINDOW);

        (uint80 roundId, int256 answer, , uint256 updatedAt, uint80 answeredInRound)
            = a.latestRoundData();

        assertGt(answer, 0, "would trip InvalidOraclePrice");
        assertGe(answeredInRound, roundId, "would trip StaleOracle");
        assertGt(updatedAt, 0, "would trip StaleOracle");
        assertEq(block.timestamp - updatedAt, 0, "never stale by construction");
    }

    /// THE INVARIANT OracleWindow DEPENDS ON.
    ///
    /// `requireNotTighterThan` staticcalls `maxStaleness()` and treats a failure
    /// as "not one of ours, invariant unenforceable" -- the branch a real
    /// Chainlink feed takes. A contract with no fallback reverts on an unknown
    /// selector, so this call MUST fail. If someone later adds the getter, the
    /// vault starts enforcing an invariant that does not apply to a TWAP, and a
    /// vault window tighter than the TWAP window stops constructing.
    function test_DoesNotImplementMaxStaleness() public {
        UniswapV3TwapAdapter a = _deploy(address(nvda), address(usdg));
        (bool ok, ) = address(a).staticcall(abi.encodeWithSignature("maxStaleness()"));
        assertFalse(ok, "the adapter must not answer maxStaleness()");
    }

    // --- guards -------------------------------------------------------------
    //
    // Each must fire on its OWN trigger and only its own trigger. A guard that
    // fires for a neighbour's reason sends an operator to fix the wrong thing,
    // which is worse than not having it: they change the pool, the vault still
    // refuses, and now they distrust the error.

    /// Every guard satisfied, so each test below breaks exactly one thing.
    function _healthy() internal {
        pool.setTick(221882);
        pool.setMeanTick(221882, WINDOW);
        pool.setLiquidity(50e18);
        pool.setCardinality(6000);
        pool.setObservationAge(60);
    }

    function test_Guard_AllHealthyDoesNotRevert() public {
        UniswapV3TwapAdapter a = _deploy(address(nvda), address(usdg));
        _healthy();
        (, int256 answer, , , ) = a.latestRoundData();
        assertEq(uint256(answer), 23134970771);
    }

    // 1. cardinality

    function test_Guard_CardinalityBelowMinimumReverts() public {
        UniswapV3TwapAdapter a = _deploy(address(nvda), address(usdg));
        _healthy();
        pool.setCardinality(299);
        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapV3TwapAdapter.InsufficientCardinality.selector, uint16(299), MIN_CARDINALITY
            )
        );
        a.latestRoundData();
    }

    function test_Guard_CardinalityExactlyAtMinimumPasses() public {
        UniswapV3TwapAdapter a = _deploy(address(nvda), address(usdg));
        _healthy();
        pool.setCardinality(MIN_CARDINALITY);
        (, int256 answer, , , ) = a.latestRoundData();
        assertGt(answer, 0, "the floor is inclusive");
    }

    /// Cardinality 1 is the state SPY/USDG 0.01% and ZOR/USDG are in today: a
    /// pool that exists and trades but keeps a single observation.
    function test_Guard_CardinalityOneIsRefused() public {
        UniswapV3TwapAdapter a = _deploy(address(nvda), address(usdg));
        _healthy();
        pool.setCardinality(1);
        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapV3TwapAdapter.InsufficientCardinality.selector, uint16(1), MIN_CARDINALITY
            )
        );
        a.latestRoundData();
    }

    // 2. liquidity

    function test_Guard_LiquidityBelowFloorReverts() public {
        UniswapV3TwapAdapter a = _deploy(address(nvda), address(usdg));
        _healthy();
        pool.setLiquidity(MIN_LIQUIDITY - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapV3TwapAdapter.InsufficientLiquidity.selector, MIN_LIQUIDITY - 1, MIN_LIQUIDITY
            )
        );
        a.latestRoundData();
    }

    function test_Guard_LiquidityExactlyAtFloorPasses() public {
        UniswapV3TwapAdapter a = _deploy(address(nvda), address(usdg));
        _healthy();
        pool.setLiquidity(MIN_LIQUIDITY);
        (, int256 answer, , , ) = a.latestRoundData();
        assertGt(answer, 0, "the floor is inclusive");
    }

    function test_Guard_DrainedPoolIsRefused() public {
        UniswapV3TwapAdapter a = _deploy(address(nvda), address(usdg));
        _healthy();
        pool.setLiquidity(0);
        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapV3TwapAdapter.InsufficientLiquidity.selector, uint128(0), MIN_LIQUIDITY
            )
        );
        a.latestRoundData();
    }

    // 3. observation age

    function test_Guard_ObservationOlderThanMaxAgeReverts() public {
        UniswapV3TwapAdapter a = _deploy(address(nvda), address(usdg));
        _healthy();
        pool.setObservationAge(MAX_OBS_AGE + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapV3TwapAdapter.ObservationTooOld.selector, MAX_OBS_AGE + 1, MAX_OBS_AGE
            )
        );
        a.latestRoundData();
    }

    function test_Guard_ObservationExactlyAtMaxAgePasses() public {
        UniswapV3TwapAdapter a = _deploy(address(nvda), address(usdg));
        _healthy();
        pool.setObservationAge(MAX_OBS_AGE);
        (, int256 answer, , , ) = a.latestRoundData();
        assertGt(answer, 0, "the ceiling is inclusive");
    }

    /// An observation written in this very block is age zero, which must pass.
    /// A guard that rejected it would make the adapter unusable on a busy pool.
    function test_Guard_FreshObservationPasses() public {
        UniswapV3TwapAdapter a = _deploy(address(nvda), address(usdg));
        _healthy();
        pool.setObservationAge(0);
        (, int256 answer, , , ) = a.latestRoundData();
        assertGt(answer, 0);
    }

    // 4. spot against the average

    /// 300 ticks is 295 bps against a 200 bps tolerance. Base is token1, so a
    /// HIGHER tick means a LOWER answer -- direction does not matter to the
    /// guard, only magnitude, and both directions are tested.
    function test_Guard_SpotAboveTwapByMoreThanToleranceReverts() public {
        UniswapV3TwapAdapter a = _deploy(address(nvda), address(usdg));
        _healthy();
        pool.setTick(221882 + 300);
        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapV3TwapAdapter.SpotDivergesFromTwap.selector,
                uint256(23134970771), uint256(22451262728), uint256(295)
            )
        );
        a.latestRoundData();
    }

    function test_Guard_SpotBelowTwapByMoreThanToleranceReverts() public {
        UniswapV3TwapAdapter a = _deploy(address(nvda), address(usdg));
        _healthy();
        pool.setTick(221882 - 300);
        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapV3TwapAdapter.SpotDivergesFromTwap.selector,
                uint256(23134970771), uint256(23839499767), uint256(304)
            )
        );
        a.latestRoundData();
    }

    /// 100 ticks is 99 bps, comfortably inside the tolerance.
    function test_Guard_SmallSpotDivergenceIsAllowed() public {
        UniswapV3TwapAdapter a = _deploy(address(nvda), address(usdg));
        _healthy();
        pool.setTick(221882 + 100);
        (, int256 answer, , , ) = a.latestRoundData();
        assertEq(uint256(answer), 23134970771, "still reports the average");
    }

    /// The tolerance is inclusive: exactly at the limit must pass, so that a
    /// pool sitting on the boundary is not a coin flip between blocks.
    function test_Guard_DivergenceExactlyAtToleranceIsAllowed() public {
        UniswapV3TwapAdapter a = _deploy(address(nvda), address(usdg));
        _healthy();
        // Search downward for the largest gap that still reports exactly
        // MAX_DIVERGENCE_BPS, rather than hardcoding a tick that a change to
        // the tolerance would silently invalidate.
        int24 offset = 300;
        while (offset > 0) {
            uint256 twap = a.answerAtTick(221882);
            uint256 spot = a.answerAtTick(221882 + offset);
            uint256 diff = twap > spot ? twap - spot : spot - twap;
            if ((diff * 10000) / twap == MAX_DIVERGENCE_BPS) break;
            offset--;
        }
        assertGt(offset, 0, "no tick offset produces exactly the tolerance");
        pool.setTick(221882 + offset);
        (, int256 answer, , , ) = a.latestRoundData();
        assertGt(answer, 0, "exactly at the tolerance must be allowed");
    }

    // 5. sanity

    /// A pair whose price cannot be expressed at 1e8 -- 6dp base against an
    /// 18dp quote, where one whole unit buys 1e-12 of the other -- computes to
    /// zero and must be refused rather than reported as a free asset.
    function test_Guard_AnswerThatUnderflowsToZeroIsRefused() public {
        UniswapV3TwapAdapter a = _deploy(address(usdg), address(nvda));
        pool.setTick(0);
        pool.setMeanTick(0, WINDOW);
        pool.setLiquidity(50e18);
        pool.setCardinality(6000);
        pool.setObservationAge(60);

        vm.expectRevert(
            abi.encodeWithSelector(UniswapV3TwapAdapter.InvalidAnswer.selector, uint256(0))
        );
        a.latestRoundData();
    }

    // --- ordering -----------------------------------------------------------

    /// ORDER IS LOAD-BEARING, not cosmetic.
    ///
    /// A pool that cannot serve the requested window makes `observe` revert
    /// with a bare "OLD" that names nothing an operator can act on. All three
    /// cheap guards therefore run BEFORE anything calls observe, so each of the
    /// three diagnosable conditions produces its own typed error carrying both
    /// numbers. This test makes observe always revert, then trips each guard in
    /// turn: if any of them moved after the observe call, its typed error would
    /// be replaced by "OLD" and this would fail.
    function test_Guard_TheCheapGuardsAllRunBeforeObserve() public {
        UniswapV3TwapAdapter a = _deploy(address(nvda), address(usdg));
        _healthy();
        pool.setObserveReverts(true);

        pool.setCardinality(1);
        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapV3TwapAdapter.InsufficientCardinality.selector, uint16(1), MIN_CARDINALITY
            )
        );
        a.latestRoundData();
        pool.setCardinality(6000);

        pool.setLiquidity(0);
        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapV3TwapAdapter.InsufficientLiquidity.selector, uint128(0), MIN_LIQUIDITY
            )
        );
        a.latestRoundData();
        pool.setLiquidity(50e18);

        pool.setObservationAge(MAX_OBS_AGE + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapV3TwapAdapter.ObservationTooOld.selector, MAX_OBS_AGE + 1, MAX_OBS_AGE
            )
        );
        a.latestRoundData();
    }

    /// A KNOWN DIAGNOSTIC GAP, pinned so it cannot change silently.
    ///
    /// Cardinality is the buffer's SIZE, not its time span. A pool can hold 300
    /// observations that between them cover only a few minutes, in which case a
    /// 30-minute window is unavailable and `observe` reverts with a bare "OLD"
    /// -- past all five guards, because none of them measures span.
    ///
    /// This is fail-closed: the vault refuses to rebalance either way, so it is
    /// a diagnosis cost rather than a safety hole. It is not fixed here because
    /// the spec fixes the guard list at five. `oldestObservationSecondsAgo` in
    /// the next commit is what a sixth guard would use if one is ever wanted.
    function test_Guard_ATooShallowBufferRevertsUntyped() public {
        UniswapV3TwapAdapter a = _deploy(address(nvda), address(usdg));
        _healthy();
        pool.setObserveReverts(true);
        vm.expectRevert(bytes("OLD"));
        a.latestRoundData();
    }
}

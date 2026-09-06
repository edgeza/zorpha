// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {UniswapV3TwapAdapter, IUniswapV3PoolMinimal} from "../../src/oracle/UniswapV3TwapAdapter.sol";
import {SpotVaultMinimal} from "../../src/vaults/SpotVaultMinimal.sol";
import {RobinhoodChainRouterAdapter} from "../../src/adapters/RobinhoodChainRouterAdapter.sol";

/// @notice The oracle-free stock vault, against the pool it will actually use.
///
///         WHY THIS RUNS AT HEAD AND NOT AT A PINNED BLOCK
///
///         The spec asked for a pinned block. The public RPC prunes archive
///         state, so pinning does not work -- a call 500k blocks behind the tip
///         returns "metadata is not found, 55629662" while the same call at head
///         answers fine. All seven existing fork tests run at head for this
///         reason.
///
///         So nothing here asserts a hardcoded price. Every expected value is
///         derived from the same live state the contract reads, which is the
///         discipline SpotRebalanceMainnet.t.sol already follows: it reads the
///         price out of the pool rather than pinning it, precisely because a
///         pinned number goes stale.
///
///         WHAT COUNTS AS INDEPENDENT HERE
///
///         Checking the adapter against its own arithmetic proves nothing. Two
///         genuinely independent references are used instead:
///
///           1. the TWAP recomputed in this file from the pool's raw
///              cumulatives, without calling meanTick;
///           2. the price the pool ACTUALLY FILLS AT, measured by executing a
///              real swap through SwapRouter02.
///
///         The second is the strongest available: it is the number a depositor
///         experiences, produced by a completely different code path.
///
///         Opt-in. Run with:
///           RH_MAINNET_RPC_URL=https://rpc.mainnet.chain.robinhood.com \
///             forge test --match-path 'test/fork/StockVaultMainnet.t.sol' -vv
contract StockVaultMainnetForkTest is Test {
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168; // token0, 6dp
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC; // token1, 18dp
    address constant POOL = 0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3; // 0.05%
    address constant SWAP_ROUTER_02 = 0xCaf681a66D020601342297493863E78C959E5cb2;
    uint24 constant FEE = 500;

    uint32 constant TWAP_WINDOW = 1800;
    uint16 constant MIN_CARDINALITY = 300;
    uint128 constant MIN_LIQUIDITY = 12e18;
    uint32 constant MAX_OBS_AGE = 4 hours;
    uint16 constant MAX_DIVERGENCE_BPS = 200;

    uint256 constant ONE_USDG = 1e6;

    UniswapV3TwapAdapter adapter;
    IUniswapV3PoolMinimal pool;
    bool forked;

    function setUp() public {
        string memory url = vm.envOr("RH_MAINNET_RPC_URL", string(""));
        if (bytes(url).length == 0) return;
        vm.createSelectFork(url);
        forked = true;

        pool = IUniswapV3PoolMinimal(POOL);
        adapter = new UniswapV3TwapAdapter(
            POOL, NVDA, USDG,
            TWAP_WINDOW, MIN_CARDINALITY, MIN_LIQUIDITY, MAX_OBS_AGE, MAX_DIVERGENCE_BPS
        );
    }

    function _answer() internal view returns (uint256 answer) {
        (, int256 a, , , ) = adapter.latestRoundData();
        answer = uint256(a);
    }

    // --- the pool ------------------------------------------------------------

    /// The pool's shape, so a change on chain fails HERE rather than somewhere
    /// downstream where the cause is unrecognisable.
    function test_PoolIsShapedAsTheSpecAssumes() public {
        if (!forked) { vm.skip(true); }
        assertEq(pool.token0(), USDG, "token0 must be USDG");
        assertEq(pool.token1(), NVDA, "token1 must be NVDA");
        assertFalse(adapter.baseIsToken0(), "NVDA must be token1");
        assertEq(adapter.baseDecimals(), 18);
        assertEq(adapter.quoteDecimals(), 6);
        assertEq(adapter.decimals(), 8);
    }

    /// The four numeric guards must all be SATISFIED by the live pool, or the
    /// vault could never rebalance. Assert the headroom rather than assume it.
    function test_LivePoolClearsEveryGuardWithHeadroom() public {
        if (!forked) { vm.skip(true); }

        (, , uint16 index, uint16 cardinality, , , ) = pool.slot0();
        uint128 liq = pool.liquidity();
        (uint32 lastObs, , , ) = pool.observations(index);
        uint32 age = uint32(block.timestamp) - lastObs;
        uint32 depth = adapter.oldestObservationSecondsAgo();

        console2.log("cardinality           ", cardinality);
        console2.log("liquidity             ", liq);
        console2.log("newest observation age", age);
        console2.log("buffer reaches back   ", depth);

        assertGe(cardinality, MIN_CARDINALITY, "cardinality below the floor");
        assertGe(liq, MIN_LIQUIDITY, "liquidity below the floor: see the spec, do not lower it here");
        assertLe(age, MAX_OBS_AGE, "newest observation older than the guard allows");

        // Not a guard, but the reason the terminal's chart has anything to draw,
        // and the reason a 30-minute window can be served at all.
        assertGe(depth, TWAP_WINDOW, "buffer shallower than the TWAP window");
    }

    // --- the price -----------------------------------------------------------

    /// The answer must match a TWAP recomputed here from the pool's raw
    /// cumulatives -- not from `meanTick`, which would be the implementation
    /// checking itself.
    function test_AnswerMatchesAnIndependentlyComputedTwap() public {
        if (!forked) { vm.skip(true); }

        uint32[] memory agos = new uint32[](2);
        agos[0] = TWAP_WINDOW;
        agos[1] = 0;
        (int56[] memory cum, ) = pool.observe(agos);

        int56 delta = cum[1] - cum[0];
        int56 window = int56(uint56(TWAP_WINDOW));
        int24 expectedTick = int24(delta / window);
        if (delta < 0 && delta % window != 0) expectedTick--;

        assertEq(adapter.meanTick(), expectedTick, "mean tick");
        assertEq(_answer(), adapter.answerAtTick(expectedTick), "answer is the mean tick's price");

        console2.log("NVDA/USDG 30m TWAP at 1e8:", _answer());
        assertGt(_answer(), 1e8, "under $1 is not a plausible NVDA price");
        assertLt(_answer(), 100000e8, "over $100,000 is not a plausible NVDA price");
    }

    /// THE STRONGEST CHECK AVAILABLE: the oracle against what the pool actually
    /// fills at.
    ///
    /// Every other assertion here shares code with the thing it is testing. This
    /// one does not -- it executes a real swap through the real router and
    /// derives the price from tokens received, which is the number a depositor
    /// experiences. A decimals error, an inverted ratio or a wrong scale factor
    /// all show up as an order-of-magnitude gap.
    ///
    /// A buy should land slightly ABOVE the mid price: 0.05% in fees plus impact.
    /// 1% is the tolerance because the TWAP is a 30-minute average and spot has
    /// moved since; the divergence guard already bounds that at 2%.
    function test_AnswerAgreesWithWhatThePoolActuallyFills() public {
        if (!forked) { vm.skip(true); }

        RobinhoodChainRouterAdapter router =
            new RobinhoodChainRouterAdapter(SWAP_ROUTER_02, NVDA, USDG, FEE, address(this));
        router.grantRole(router.VAULT_ROLE(), address(this));

        uint256 probe = 1_000 * ONE_USDG;
        deal(USDG, address(this), probe);
        IERC20(USDG).approve(address(router), probe);
        uint256 got = router.swap(USDG, NVDA, probe, 1);
        assertGt(got, 0, "the probe swap returned nothing");

        // USDG per NVDA at 8 decimals: (in / 1e6) / (out / 1e18) * 1e8.
        uint256 filled = (probe * 1e20) / got;
        uint256 oracle = _answer();

        console2.log("oracle (30m TWAP) :", oracle);
        console2.log("actually filled at:", filled);

        assertApproxEqRel(
            filled, oracle, 1e16,
            "the oracle disagrees with the pool it prices against by more than 1%"
        );
    }

    /// The TWAP was measured stable across two orders of magnitude of window --
    /// 60s to 7200s moved it three cents. If that stops holding, the window
    /// choice needs revisiting, so assert it rather than trusting the spec.
    ///
    /// A FAILURE HERE MAY NOT BE A CODE FAULT. 2% between a one-minute and a
    /// two-hour average is a genuinely fast-moving market, which is a fact about
    /// NVDA that day rather than about this contract. Read the logged values
    /// before changing anything.
    ///
    /// AND A GUARD AGAINST THIS TEST BEING VACUOUS. When the market is flat the
    /// windows return byte-identical answers, because their mean ticks differ by
    /// hundredths and integer flooring collapses that: measured 6 September, the
    /// exact means were 221881.0000 over 60s and 221881.0200 over 1800s, both
    /// flooring to 221881. Identical answers are therefore the expected quiet
    /// case -- but they are also what a broken `observe` would produce. So the
    /// raw cumulatives are checked first: a 7200-second lookback must reach a
    /// different point in the accumulator than a 60-second one, whatever the
    /// prices work out to.
    function test_TwapIsStableAcrossWindowLengths() public {
        if (!forked) { vm.skip(true); }

        uint32 depth = adapter.oldestObservationSecondsAgo();

        uint32[] memory nearAgos = new uint32[](2);
        nearAgos[0] = 60;
        nearAgos[1] = 0;
        uint32[] memory farAgos = new uint32[](2);
        farAgos[0] = 7200;
        farAgos[1] = 0;
        (int56[] memory near, ) = pool.observe(nearAgos);
        (int56[] memory far, ) = pool.observe(farAgos);
        assertTrue(
            near[0] != far[0],
            "observe returned the same history for a 60s and a 7200s lookback"
        );

        uint32[3] memory windows = [uint32(60), 1800, 7200];

        uint256 firstAnswer;
        uint256 tested;
        for (uint256 i = 0; i < windows.length; i++) {
            // `observe` reverts with a bare "OLD" past the ring's reach, so skip
            // a window the buffer cannot serve rather than fail for that reason.
            if (windows[i] > depth) {
                console2.log("skipping window, buffer too shallow:", windows[i]);
                continue;
            }
            UniswapV3TwapAdapter a = new UniswapV3TwapAdapter(
                POOL, NVDA, USDG,
                windows[i], MIN_CARDINALITY, MIN_LIQUIDITY, MAX_OBS_AGE, MAX_DIVERGENCE_BPS
            );
            (, int256 answer, , , ) = a.latestRoundData();
            console2.log("window", windows[i], "answer", uint256(answer));
            console2.log("  mean tick", int256(a.meanTick()));

            if (tested == 0) firstAnswer = uint256(answer);
            else assertApproxEqRel(uint256(answer), firstAnswer, 2e16, "windows disagree by over 2%");
            tested++;
        }
        assertGe(tested, 2, "not enough windows served to compare anything");
    }

    // --- the vault -----------------------------------------------------------

    /// Constructing the vault exercises `OracleWindow.requireNotTighterThan`
    /// against the real adapter, which is the branch the whole design relies on:
    /// the staticcall for `maxStaleness()` must fail and be treated as
    /// "not one of ours" rather than reverting the deployment.
    function test_VaultConstructsAgainstTheAdapter() public {
        if (!forked) { vm.skip(true); }

        SpotVaultMinimal vault = new SpotVaultMinimal(
            NVDA, USDG, address(adapter), 3600,
            "Zorpha NVDA Long/Flat", "zqNVDA",
            100, 100, 1000,
            address(this), address(this), 0
        );

        assertEq(address(vault.oracle()), address(adapter));
        assertEq(vault.maxOracleStaleness(), 3600);

        // The vault read decimals() off the adapter at construction and scales
        // every conversion by it. assetToCash is
        //   assetAmt * 10^cashDec * p / (10^assetDec * 10^priceDec)
        // so one whole NVDA in USDG units is the 1e8 answer divided by 100. If
        // that is off by a power of ten, the decimals handling is wrong and this
        // is the assertion that says so.
        assertEq(vault.assetToCash(1e18), _answer() / 100, "1 NVDA in USDG (6dp)");

        // And the inverse round-trips, within the truncation of two divisions.
        assertApproxEqRel(vault.cashToAsset(vault.assetToCash(1e18)), 1e18, 1e12, "round trip");
    }

    /// A vault window TIGHTER than the adapter's TWAP window must ALSO be
    /// accepted. With a MedianOracle this combination is the exact bug
    /// OracleWindow exists to prevent; with a TWAP there is nothing to compare
    /// against, so it is legal and must stay legal.
    function test_VaultConstructsWithAWindowTighterThanTheTwap() public {
        if (!forked) { vm.skip(true); }

        SpotVaultMinimal vault = new SpotVaultMinimal(
            NVDA, USDG, address(adapter), 60, // 60s vault against an 1800s TWAP
            "Zorpha NVDA Long/Flat", "zqNVDA",
            100, 100, 1000,
            address(this), address(this), 0
        );
        assertEq(vault.maxOracleStaleness(), 60);

        // And it can actually price: a TWAP's updatedAt is always block.timestamp,
        // so even a 60-second window is never stale.
        assertGt(vault.assetToCash(1e18), 0, "a tight window must not make it unpriceable");
    }
}

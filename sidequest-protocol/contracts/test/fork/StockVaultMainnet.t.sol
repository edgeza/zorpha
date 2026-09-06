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

    // --- the whole vault ------------------------------------------------------

    address alice = address(0xA11CE);

    function _wiredVault() internal returns (SpotVaultMinimal vault) {
        vault = new SpotVaultMinimal(
            NVDA, USDG, address(adapter), 3600,
            "Zorpha NVDA Long/Flat", "zqNVDA",
            100,   // rebalanceThresholdBps
            100,   // maxSlippageBps
            1000,  // performanceFeeBps
            address(this), address(this), 0
        );
        RobinhoodChainRouterAdapter swap =
            new RobinhoodChainRouterAdapter(SWAP_ROUTER_02, NVDA, USDG, FEE, address(this));
        swap.grantRole(swap.VAULT_ROLE(), address(vault));
        vault.setSwapAdapter(address(swap));
        vault.grantRole(vault.KEEPER_ROLE(), address(this));
    }


    /// Which guard refused, by selector. "It reverted" is not a measurement --
    /// a liquidity floor and a divergence tolerance are different claims about
    /// how expensive this design is to attack.
    function _whyRefused() internal view returns (string memory) {
        (bool ok, bytes memory ret) =
            address(adapter).staticcall(abi.encodeWithSignature("latestRoundData()"));
        if (ok) return "answered";
        if (ret.length < 4) return "reverted (no selector)";
        bytes4 sel = bytes4(ret);
        if (sel == UniswapV3TwapAdapter.InsufficientCardinality.selector) return "InsufficientCardinality";
        if (sel == UniswapV3TwapAdapter.InsufficientLiquidity.selector) return "InsufficientLiquidity";
        if (sel == UniswapV3TwapAdapter.ObservationTooOld.selector) return "ObservationTooOld";
        if (sel == UniswapV3TwapAdapter.SpotDivergesFromTwap.selector) return "SpotDivergesFromTwap";
        if (sel == UniswapV3TwapAdapter.InvalidAnswer.selector) return "InvalidAnswer";
        return "reverted (unknown selector)";
    }

    /// A swap router this test controls, for moving the pool.
    function _attacker() internal returns (RobinhoodChainRouterAdapter r) {
        r = new RobinhoodChainRouterAdapter(SWAP_ROUTER_02, NVDA, USDG, FEE, address(this));
        r.grantRole(r.VAULT_ROLE(), address(this));
    }

    /// Deposit, go flat, go long again, redeem. The only value that may be lost
    /// is fees and slippage: two swaps at 0.05% plus impact, each bounded by the
    /// 1% maxSlippageBps the vault enforces on its own leg.
    function test_RoundTrip_DepositLongFlatRedeem() public {
        if (!forked) { vm.skip(true); }

        SpotVaultMinimal vault = _wiredVault();

        // The vault is denominated in NVDA, so the depositor deposits NVDA.
        uint256 deposit = 1e18;
        deal(NVDA, alice, deposit);

        vm.startPrank(alice);
        IERC20(NVDA).approve(address(vault), deposit);
        uint256 shares = vault.deposit(deposit, alice);
        vm.stopPrank();

        assertGt(shares, 0, "no shares minted");
        assertEq(vault.totalAssets(), deposit, "a fresh vault holds exactly the deposit");

        // The deposit arrived in NVDA, so the vault is already fully long. Flat.
        vault.rebalanceTo(0);
        assertEq(vault.targetWeightBps(), 0);
        assertEq(vault.rebalanceCount(), 1, "going flat should have emitted a receipt");
        assertGt(IERC20(USDG).balanceOf(address(vault)), 0, "no cash leg after going flat");
        assertLt(IERC20(NVDA).balanceOf(address(vault)), deposit / 100, "still mostly long");

        uint256 flatNav = vault.totalAssets();
        console2.log("NAV after going flat (NVDA units) :", flatNav);

        // And back to fully long.
        vault.rebalanceTo(10000);
        assertEq(vault.targetWeightBps(), 10000);
        assertEq(vault.rebalanceCount(), 2);
        assertGt(IERC20(NVDA).balanceOf(address(vault)), 0, "no asset leg after going long");

        uint256 longNav = vault.totalAssets();
        console2.log("NAV after going long again        :", longNav);
        console2.log("round-trip cost (NVDA wei)        :", deposit - longNav);

        // Two swaps at 0.05% each plus impact on a ~$231 trade, which is dust
        // against this pool. 1% is a ceiling that still fails loudly if a leg
        // executed at a wrong price.
        assertApproxEqRel(longNav, deposit, 1e16, "round trip lost more than 1%");

        // The depositor can leave with what is left.
        //
        // 99.99% of the shares rather than all of them, deliberately: a FULL
        // redeem reverts whenever the vault holds cash dust, which is a
        // pre-existing SpotVaultMinimal bug demonstrated in
        // test_KnownIssue_FullRedeemRevertsOnOneUnitOfCashDust below. Redeeming
        // everything here would make this test fail for that reason rather than
        // for anything about the round trip.
        vm.startPrank(alice);
        uint256 got = vault.redeem((vault.balanceOf(alice) * 9999) / 10000, alice, alice);
        vm.stopPrank();
        console2.log("redeemed                          :", got);
        assertApproxEqRel(got, deposit, 2e16, "redeem lost more than 2%");
    }

    /// A move smaller than rebalanceThresholdBps writes the target and returns
    /// WITHOUT swapping, emitting no event and bumping no counter. The
    /// transaction succeeds and costs gas, which is the one thing about this
    /// contract a manager reliably misreads, so it is pinned here against the
    /// real venue rather than only in the unit suite.
    function test_RoundTrip_BelowThresholdIsANoOpThatStillSucceeds() public {
        if (!forked) { vm.skip(true); }

        SpotVaultMinimal vault = _wiredVault();
        uint256 deposit = 1e18;
        deal(NVDA, alice, deposit);
        vm.startPrank(alice);
        IERC20(NVDA).approve(address(vault), deposit);
        vault.deposit(deposit, alice);
        vm.stopPrank();

        // Already at 100%. Asking for 99.5% is a 0.5% move against a 1% floor.
        vault.rebalanceTo(9950);
        assertEq(vault.targetWeightBps(), 9950, "the target is still written");
        assertEq(vault.rebalanceCount(), 0, "no receipt for a move that did not happen");
        assertEq(IERC20(NVDA).balanceOf(address(vault)), deposit, "nothing was traded");
    }

    // --- manipulation ---------------------------------------------------------

    /// WHAT DOES IT COST TO BREAK THE PRICE?
    ///
    /// The claim this design rests on is that moving the pool enough to fool
    /// NAV is expensive and self-defeating. That is worth measuring rather than
    /// asserting, so this escalates single-trade sizes against a snapshot until
    /// the divergence guard refuses, and reports the figure.
    ///
    /// The number is a property of the pool on the day, not of this contract, so
    /// nothing is asserted about its size beyond it existing. It is logged so a
    /// human can see whether the margin is still comfortable.
    function test_Manipulation_MeasureWhatItCostsToTripTheGuard() public {
        if (!forked) { vm.skip(true); }

        uint256 baseline = _answer();
        console2.log("baseline TWAP        :", baseline);
        console2.log("baseline in-range liq:", pool.liquidity());
        console2.log("--- size(USDG) | in-range liq | spot divergence bps | guard ---");

        uint256[6] memory sizes = [uint256(50_000), 100_000, 250_000, 500_000, 1_000_000, 2_000_000];
        uint256 tripped;
        string memory reason;

        for (uint256 i = 0; i < sizes.length; i++) {
            uint256 snap = vm.snapshotState();
            RobinhoodChainRouterAdapter atk = _attacker();

            uint256 amt = sizes[i] * ONE_USDG;
            deal(USDG, address(this), amt);
            IERC20(USDG).approve(address(atk), amt);

            try atk.swap(USDG, NVDA, amt, 1) {
                (, int24 spotAfter, , , , , ) = pool.slot0();
                uint256 spotAnswer = adapter.answerAtTick(spotAfter);
                uint256 d = spotAnswer > baseline ? spotAnswer - baseline : baseline - spotAnswer;
                string memory why = _whyRefused();

                console2.log("size", sizes[i]);
                console2.log("   in-range liq  ", pool.liquidity());
                console2.log("   divergence bps", (d * 10000) / baseline);
                console2.log("   guard         ", why);

                if (tripped == 0 && keccak256(bytes(why)) != keccak256(bytes("answered"))) {
                    tripped = sizes[i];
                    reason = why;
                }
            } catch {
                console2.log("swap itself reverted at USDG", sizes[i]);
            }

            vm.revertToState(snap);
        }

        assertGt(tripped, 0, "no single trade up to 2M USDG made the oracle refuse");
        console2.log("=== first size that made the oracle refuse, USDG:", tripped);
        console2.log("=== and the guard that caught it:", reason);
    }

    /// And the consequence that matters: while the guard is tripped the VAULT
    /// cannot rebalance, and emits no receipt.
    ///
    /// This is the whole safety claim in one test. `_oraclePrice` is the only
    /// path into `rebalanceTo`, so an adapter that refuses is a vault that
    /// refuses -- it cannot be talked into pricing off a manipulated tick.
    function test_Manipulation_PushingSpotBlocksTheRebalance() public {
        if (!forked) { vm.skip(true); }

        SpotVaultMinimal vault = _wiredVault();
        uint256 deposit = 1e18;
        deal(NVDA, alice, deposit);
        vm.startPrank(alice);
        IERC20(NVDA).approve(address(vault), deposit);
        vault.deposit(deposit, alice);
        vm.stopPrank();

        // A rebalance is possible right now.
        vault.rebalanceTo(0);
        assertEq(vault.rebalanceCount(), 1);

        // Now shove spot with a large single trade through the same venue the
        // vault uses. This moves slot0 and leaves the 30-minute average alone,
        // which is exactly the condition the divergence guard exists for.
        RobinhoodChainRouterAdapter atk = _attacker();
        uint256 push = 10_000_000 * ONE_USDG;
        deal(USDG, address(this), push);
        IERC20(USDG).approve(address(atk), push);
        atk.swap(USDG, NVDA, push, 1);

        (, int24 spotAfter, , , , , ) = pool.slot0();
        console2.log("spot tick after the push:", int256(spotAfter));
        console2.log("mean tick (unmoved)     :", int256(adapter.meanTick()));

        // The adapter refuses...
        vm.expectRevert();
        adapter.latestRoundData();

        // ...and so, therefore, does the vault.
        vm.expectRevert();
        vault.rebalanceTo(10000);
        assertEq(vault.rebalanceCount(), 1, "no receipt may be emitted while the guard is tripped");
        assertEq(vault.targetWeightBps(), 0, "and no target may be written either");
    }

    /// The chart keeps answering while NAV refuses, on real data. This is the
    /// reason `answersOverWindows` is ungated: a manager whose rebalance was
    /// just rejected is exactly the person who needs to see the price.
    function test_Manipulation_ChartStillAnswersWhileNavRefuses() public {
        if (!forked) { vm.skip(true); }

        RobinhoodChainRouterAdapter atk = _attacker();
        uint256 push = 10_000_000 * ONE_USDG;
        deal(USDG, address(this), push);
        IERC20(USDG).approve(address(atk), push);
        atk.swap(USDG, NVDA, push, 1);

        vm.expectRevert();
        adapter.latestRoundData();

        uint32 horizon = adapter.oldestObservationSecondsAgo();
        if (horizon > 3600) horizon = 3600;
        uint32[] memory agos = new uint32[](3);
        agos[0] = horizon;
        agos[1] = horizon / 2;
        agos[2] = 0;

        uint256[] memory series = adapter.answersOverWindows(agos);
        assertEq(series.length, 2);
        assertGt(series[0], 0, "the chart went blank exactly when it was needed");
        assertGt(series[1], 0);
        console2.log("chart still reads:", series[0], series[1]);
    }

    // --- a pre-existing SpotVaultMinimal bug, found by this work --------------

    /// A FULL REDEEM REVERTS WHEN THE VAULT HOLDS ONE UNIT OF CASH DUST.
    ///
    /// This is NOT caused by the TWAP adapter. Any oracle produces it, because
    /// the fault is in `SpotVaultMinimal._withdraw` and in the asymmetry between
    /// the two conversion helpers. It is pinned here rather than fixed, because
    /// the spec ships SpotVaultMinimal unmodified.
    ///
    /// THE MECHANISM, measured on this pool at 23,137,284,268 (1e8):
    ///
    ///   1. The vault holds NVDA plus 1 unit of USDG (1e-6 USDG).
    ///   2. `totalAssets()` values that unit at `cashToAsset(1)`, which is
    ///      4,322,028,412 NVDA wei -- so it counts toward what a redeemer is owed.
    ///   3. A full redeem therefore asks for more NVDA than the vault holds.
    ///   4. `_withdraw` sees the shortfall and computes
    ///      `cashIn = assetToCash(shortfall)`, which is 0.99990... and FLOORS TO
    ///      ZERO.
    ///   5. `_swap` returns early on a zero amount, the NVDA balance never
    ///      rises, and `safeTransfer` reverts with ERC20InsufficientBalance.
    ///
    /// The root cause in one line: `assetToCash(cashToAsset(1)) == 0`, not 1.
    /// The floor loses the smallest unit in both directions, so any cash the
    /// vault values in asset terms can be unreachable by the only code path
    /// meant to convert it back.
    ///
    /// IMPACT. Funds are not lost -- 99.99% redeems fine, and the dust is worth
    /// about four billionths of one NVDA. But `maxRedeem` reports the full share
    /// balance, so the obvious call, `redeem(maxRedeem(me), me, me)`, reverts.
    /// A depositor trying to exit completely hits it, and the revert names an
    /// ERC20 balance rather than anything they can act on.
    function test_KnownIssue_FullRedeemRevertsOnOneUnitOfCashDust() public {
        if (!forked) { vm.skip(true); }

        // CONTROL: with no cash leg at all, a full redeem works.
        {
            SpotVaultMinimal clean = _wiredVault();
            deal(NVDA, alice, 1e18);
            vm.startPrank(alice);
            IERC20(NVDA).approve(address(clean), 1e18);
            clean.deposit(1e18, alice);
            uint256 out = clean.redeem(clean.balanceOf(alice), alice, alice);
            vm.stopPrank();
            assertEq(out, 1e18, "an all-asset vault redeems in full");
        }

        // NOW WITH ONE UNIT OF DUST.
        SpotVaultMinimal vault = _wiredVault();
        deal(NVDA, alice, 1e18);
        vm.startPrank(alice);
        IERC20(NVDA).approve(address(vault), 1e18);
        vault.deposit(1e18, alice);
        vm.stopPrank();

        // One unit of USDG, sent directly. A rebalance leaves dust like this
        // whenever `assetToCash(delta)` lands below the cash balance.
        deal(USDG, address(this), 1);
        IERC20(USDG).transfer(address(vault), 1);

        uint256 held = IERC20(NVDA).balanceOf(address(vault));
        uint256 owed = vault.previewRedeem(vault.balanceOf(alice));
        assertGt(owed, held, "the dust must be counted as owed for this to bite");
        console2.log("held :", held);
        console2.log("owed :", owed);
        console2.log("short:", owed - held);

        // The conversion that should rescue it floors to zero.
        assertEq(vault.assetToCash(owed - held), 0, "the shortfall is worth zero cash units");
        console2.log("assetToCash(cashToAsset(1)):", vault.assetToCash(vault.cashToAsset(1)));
        assertEq(
            vault.assetToCash(vault.cashToAsset(1)), 0,
            "root cause: the two conversions do not round-trip at one unit"
        );

        // So the obvious call fails.
        uint256 all = vault.balanceOf(alice);
        assertEq(vault.maxRedeem(alice), all, "maxRedeem still advertises the full balance");
        vm.prank(alice);
        vm.expectRevert();
        vault.redeem(all, alice, alice);

        // A slightly smaller redeem succeeds, which is what makes this a UX
        // fault rather than trapped capital.
        //
        // "Slightly" has to be measured, not guessed. Shares carry 24 decimals
        // here -- an 18-decimal asset plus the vault's 6-decimal inflation
        // offset -- so shaving a handful of share-units moves the owed amount
        // by less than a wei and changes nothing. The shortfall is ~4.3e9 wei
        // against 1e18 held, so it takes roughly 4.3e-9 of the position to
        // clear it. 0.01% is comfortably past that and still economically
        // nothing.
        vm.prank(alice);
        uint256 got = vault.redeem((all * 9999) / 10000, alice, alice);
        assertGt(got, 0, "a marginally smaller redeem must work");
        console2.log("redeemed 99.99% instead:", got);
    }
}

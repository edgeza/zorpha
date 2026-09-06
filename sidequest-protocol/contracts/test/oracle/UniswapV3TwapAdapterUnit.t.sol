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
}

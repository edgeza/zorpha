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

    /// @notice The latest price, in Chainlink's shape.
    /// @dev    Implemented in the next commit. The price arithmetic and the
    ///         guards land together, deliberately, so no revision of this
    ///         contract ever exists that can answer without checking.
    ///
    ///         `pure` only because a function whose whole body is a revert
    ///         reads nothing. It relaxes to `view` the moment there is an
    ///         implementation, which the interface permits either way.
    function latestRoundData()
        external
        pure
        override
        returns (uint80, int256, uint256, uint256, uint80)
    {
        revert("UniswapV3TwapAdapter: not implemented");
    }
}

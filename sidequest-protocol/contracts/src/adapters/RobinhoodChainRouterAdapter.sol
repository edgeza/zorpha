// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AggregatorV3Interface} from "../oracle/MedianOracle.sol";

/// @notice Uniswap `SwapRouter02`, as deployed on Robinhood Chain at
///         0xcaf681a66d020601342297493863e78c959e5cb2.
///
///         Note the absence of `deadline`. The original `SwapRouter` carried one
///         inside this struct; SwapRouter02 removed it and expects callers that
///         want a deadline to wrap the call in `multicall(deadline, data)`.
///
///         Getting this wrong is not a warning, it is a revert on every swap:
///         the two structs ABI-encode differently and the selectors differ
///         (0x04e45aaf here, 0x414bf389 for the old shape). Confirmed against
///         the deployed bytecode, which contains the former and not the latter.
interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24  fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut);
}

/// @notice ISpotSwapAdapter — the interface SpotVault calls for rebalances.
interface ISpotSwapAdapter {
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut)
        external
        returns (uint256 amountOut);
}

/// @title RobinhoodChainRouterAdapter
/// @notice ISpotSwapAdapter for Zorpha: routes SpotVault asset<->cash rebalances
///         through Uniswap V3 on Robinhood Chain. Single-hop, fixed fee tier.
///
///         Single-hop is a measured choice, not a simplification. Quoting
///         USDG->AAPL against the live pools, the direct 0.05% pool costs 44bps
///         on $10k while routing through WETH costs 460bps on the same size,
///         because the USDG/WETH leg is itself thin. The extra hop makes the
///         execution worse everywhere it was tested.
///
///         Capacity is the real constraint, and it MOVES. Measured on the
///         AAPL/USDG 0.05% pool:
///
///                       1 Sep 2026   4 Sep 2026
///             $10k          0.44%        0.08%
///             $20k          0.94%        0.15%
///             $40k         31%           0.30%
///             $100k           --         0.75%
///             $250k           --         2.16%
///             $500k           --        45.13%
///
///         Two orders of magnitude deeper in three days. A vault with
///         `maxSlippageBps = 100` executed roughly $20k per rebalance on the
///         first reading and somewhere between $100k and $250k on the second.
///
///         That is a ceiling on vault size rather than a bug -- sizing a vault
///         past what the pool absorbs produces a vault that cannot rebalance --
///         but it is not a constant, and a number written here goes stale.
///         test/fork/PoolDepthProbe.t.sol measures it against the live pool;
///         run it before sizing anything.
///
///         The refusal comes from the ROUTER, not from this adapter: minOut is
///         forwarded as amountOutMinimum, so SwapRouter02 reverts "Too little
///         received" before `SlippageExceeded` below is reached. That check is a
///         backstop against a router that returns quietly, not the first line.
///
///         Testnet has no DEX at all, so `StubSwapAdapter` (below) stands in
///         there. The vault's adapter is swappable without redeploying it.
contract RobinhoodChainRouterAdapter is AccessControl, ISpotSwapAdapter {
    using SafeERC20 for IERC20;

    bytes32 public constant VAULT_ROLE = keccak256("VAULT_ROLE");

    ISwapRouter02 public immutable router;
    address public immutable asset;
    address public immutable cash;
    uint24  public immutable feeTier;

    event Swapped(
        address indexed caller,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );

    error UnsupportedPair(address tokenIn, address tokenOut);
    error SlippageExceeded(uint256 amountOut, uint256 minOut);

    constructor(
        address router_,
        address asset_,
        address cash_,
        uint24  feeTier_,
        address admin_
    ) {
        require(
            router_ != address(0) && asset_ != address(0) && cash_ != address(0) && admin_ != address(0),
            "zero addr"
        );
        require(asset_ != cash_, "asset == cash");
        router = ISwapRouter02(router_);
        asset = asset_;
        cash = cash_;
        feeTier = feeTier_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut)
        external
        onlyRole(VAULT_ROLE)
        returns (uint256 amountOut)
    {
        if (
            !((tokenIn == asset && tokenOut == cash) || (tokenIn == cash && tokenOut == asset))
        ) {
            revert UnsupportedPair(tokenIn, tokenOut);
        }

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).forceApprove(address(router), amountIn);

        // No deadline here: SwapRouter02 does not accept one, and the staleness
        // it would guard against is already covered a level up. A rebalance
        // carries an EIP-712 `expiry` that StrategyExecutor checks at execution
        // time, so a signature sitting in the mempool cannot be executed late.
        // `minOut` covers the economic side independently of either.
        amountOut = router.exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn:           tokenIn,
                tokenOut:          tokenOut,
                fee:               feeTier,
                recipient:         msg.sender,
                amountIn:          amountIn,
                amountOutMinimum:  minOut,
                sqrtPriceLimitX96: 0
            })
        );

        if (amountOut < minOut) revert SlippageExceeded(amountOut, minOut);
        require(IERC20(tokenIn).balanceOf(address(this)) == 0, "RHAdapter: residual tokenIn");
        IERC20(tokenIn).forceApprove(address(router), 0);

        emit Swapped(msg.sender, tokenIn, tokenOut, amountIn, amountOut);
    }

}

/// @title StubSwapAdapter
/// @notice Drop-in ISpotSwapAdapter for environments where no live DEX exists.
///         For NAV-only testing the vault still calls `swap(...)`; the stub
///         returns the same amount as the input (no slippage, no swap). This
///         is NOT a real swap — it just keeps the rebalance path non-reverting
///         so tests can exercise the vault's accounting.
contract StubSwapAdapter is ISpotSwapAdapter, AccessControl {
    using SafeERC20 for IERC20;
    bytes32 public constant VAULT_ROLE = keccak256("VAULT_ROLE");

    address public immutable asset;
    address public immutable cash;
    AggregatorV3Interface public immutable oracle;

    uint8 private immutable _assetDec;
    uint8 private immutable _cashDec;
    uint8 private immutable _priceDec;

    error UnsupportedPair(address tokenIn, address tokenOut);
    error BadOraclePrice(int256 answer);
    error StubSlippage(uint256 out, uint256 minOut);

    constructor(address asset_, address cash_, address oracle_, address admin_) {
        require(
            asset_ != address(0) && cash_ != address(0) && oracle_ != address(0) && admin_ != address(0),
            "zero addr"
        );
        asset = asset_;
        cash = cash_;
        oracle = AggregatorV3Interface(oracle_);
        _assetDec = IERC20Metadata(asset_).decimals();
        _cashDec = IERC20Metadata(cash_).decimals();
        _priceDec = AggregatorV3Interface(oracle_).decimals();
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    }

    /// @notice Swap at the oracle price with no slippage and no depth limit.
    ///
    /// @dev    This used to return `amountIn` unchanged -- 1:1 on RAW units,
    ///         ignoring both decimals and price -- and that was not a harmless
    ///         simplification. It permanently corrupted any vault it touched.
    ///
    ///         Selling 50e18 of an 18-decimal equity paid back 50e18 raw units
    ///         of a 6-decimal stable: fifty trillion nominal dollars. Since
    ///         SpotVaultMinimal.grossValue() denominates both legs in asset
    ///         units, that cash leg came back valued eleven orders of magnitude
    ///         too high -- measured on testnet 46630, grossValue went from 1e20
    ///         to 2e29 in a single rebalance. Every rebalance after it then
    ///         demanded a trade nothing could service, and a full redemption by
    ///         the only depositor reverted on slippage. The vault could be
    ///         neither rebalanced nor emptied again.
    ///
    ///         The docstring above the old version claimed it "keeps the
    ///         rebalance path non-reverting so tests can exercise the vault's
    ///         accounting". It did the opposite of both halves. Worth noting
    ///         that test/mocks/MockSpotAdapter.sol had the correct maths all
    ///         along, which is why the unit suite stayed green while the
    ///         testnet fixture destroyed vaults: the test double was more
    ///         faithful than the deploy default.
    ///
    ///         The formulas below are character-for-character the vault's own
    ///         `assetToCash` and `cashToAsset`. They have to be: the vault
    ///         computes `minOut` from its conversion and then requires the
    ///         return to clear it, so an adapter that rounds differently fails
    ///         the vault's slippage check on a trade that should have settled.
    ///
    ///         Still a stub, and still not a market: zero slippage, unbounded
    ///         depth, and it pays out of its own balance so it must be
    ///         pre-funded. Set SWAP_ROUTER before this touches real assets.
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut)
        external
        onlyRole(VAULT_ROLE)
        returns (uint256 out)
    {
        if (amountIn == 0) return 0;

        uint256 p = _price();
        if (tokenIn == asset && tokenOut == cash) {
            out = (amountIn * (10 ** _cashDec) * p) / ((10 ** _assetDec) * (10 ** _priceDec));
        } else if (tokenIn == cash && tokenOut == asset) {
            out = (amountIn * (10 ** _assetDec) * (10 ** _priceDec)) / ((10 ** _cashDec) * p);
        } else {
            revert UnsupportedPair(tokenIn, tokenOut);
        }

        // Refuse rather than under-deliver. The vault checks this too, but
        // failing here names the adapter as the cause instead of surfacing as
        // a bare "slippage" from inside the vault.
        if (out < minOut) revert StubSlippage(out, minOut);

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).safeTransfer(msg.sender, out);
    }

    /// @dev Deliberately no staleness check. The vault already enforces its own
    ///      `maxOracleStaleness` before it ever calls in here, and a second,
    ///      independently-configured window would be a way for the adapter to
    ///      refuse a trade the vault considered fresh.
    function _price() internal view returns (uint256) {
        // Only `answer` is used, deliberately, for the reason above.
        // slither-disable-next-line unused-return
        (, int256 answer, , , ) = oracle.latestRoundData();
        if (answer <= 0) revert BadOraclePrice(answer);
        return uint256(answer);
    }
}


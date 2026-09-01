// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

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
///         Capacity is the real constraint. Measured on the AAPL/USDG 0.05%
///         pool: $10k moves at 0.44%, $20k at 0.94%, and $40k at 31%. A vault
///         with `maxSlippageBps = 100` therefore executes up to roughly $20k per
///         rebalance and reverts above it. That is the correct behaviour and it
///         is a ceiling on vault size, not a bug: sizing a vault past what the
///         pool can absorb produces a vault that cannot rebalance.
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

    constructor(address asset_, address cash_, address admin_) {
        require(asset_ != address(0) && cash_ != address(0) && admin_ != address(0), "zero addr");
        asset = asset_;
        cash = cash_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256)
        external
        onlyRole(VAULT_ROLE)
        returns (uint256)
    {
        require(
            (tokenIn == asset && tokenOut == cash) || (tokenIn == cash && tokenOut == asset),
            "StubSwapAdapter: unsupported pair"
        );
        // 1:1 mock swap (testnet stub; not a real market).
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).safeTransfer(msg.sender, amountIn);
        return amountIn;
    }
}

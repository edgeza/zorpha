// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Minimal Uniswap-V3-style SwapRouter interface.
///         Robinhood Chain's primary DEX (if available at testnet) is expected
///         to expose this same `exactInputSingle` shape. If no live UniV3 fork
///         exists on RH testnet at launch, the adapter is wired to a stub
///         (no-op) and vaults fall back to NAV-accounting-only.
interface ISwapRouterV3 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24  fee;
        address recipient;
        uint256 deadline;
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
///         through a Robinhood Chain UniV3-style router. Single-hop with a
///         configurable fee tier; admin-settable deadline window.
///
///         If the live Robinhood Chain DEX is not available at testnet, the
///         owner can swap to `StubSwapAdapter` (in this file) for NAV-only
///         testing without redeploying the vault.
contract RobinhoodChainRouterAdapter is AccessControl, ISpotSwapAdapter {
    using SafeERC20 for IERC20;

    bytes32 public constant VAULT_ROLE = keccak256("VAULT_ROLE");

    ISwapRouterV3 public immutable router;
    address public immutable asset;
    address public immutable cash;
    uint24  public immutable feeTier;

    uint256 public swapDeadlineWindow = 300; // 5 minutes

    event Swapped(
        address indexed caller,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );
    event DeadlineWindowSet(uint256 window);

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
        router = ISwapRouterV3(router_);
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

        amountOut = router.exactInputSingle(
            ISwapRouterV3.ExactInputSingleParams({
                tokenIn:           tokenIn,
                tokenOut:          tokenOut,
                fee:               feeTier,
                recipient:         msg.sender,
                deadline:          block.timestamp + swapDeadlineWindow,
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

    function setDeadlineWindow(uint256 window) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(window > 0 && window <= 1 hours, "bad window");
        swapDeadlineWindow = window;
        emit DeadlineWindowSet(window);
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

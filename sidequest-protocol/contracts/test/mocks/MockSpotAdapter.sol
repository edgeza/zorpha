// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ISpotSwapAdapter} from "../../src/adapters/RobinhoodChainRouterAdapter.sol";
import {MockOracle} from "./MockOracle.sol";

/// @notice Perfect-fill spot venue priced off the oracle (no slippage).
contract MockSpotAdapter is ISpotSwapAdapter {
    address public immutable asset;
    address public immutable cash;
    MockOracle public immutable oracle;
    uint8 immutable aDec; uint8 immutable cDec; uint8 immutable pDec;

    constructor(address asset_, address cash_, address oracle_) {
        asset = asset_; cash = cash_; oracle = MockOracle(oracle_);
        aDec = IERC20Metadata(asset_).decimals();
        cDec = IERC20Metadata(cash_).decimals();
        pDec = MockOracle(oracle_).decimals();
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut)
        external returns (uint256 out)
    {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        uint256 p = uint256(oracle.answer());
        if (tokenIn == asset && tokenOut == cash) {
            out = (amountIn * (10 ** cDec) * p) / ((10 ** aDec) * (10 ** pDec));
        } else if (tokenIn == cash && tokenOut == asset) {
            out = (amountIn * (10 ** aDec) * (10 ** pDec)) / ((10 ** cDec) * p);
        } else {
            revert("unsupported pair");
        }
        require(out >= minOut, "mock slippage");
        IERC20(tokenOut).transfer(msg.sender, out);
    }
}

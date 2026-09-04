// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ISpotSwapAdapter} from "../../src/adapters/RobinhoodChainRouterAdapter.sol";
import {MockOracle} from "./MockOracle.sol";

/// @notice A venue that charges for liquidity, the way a real one does.
///
///         MockSpotAdapter fills at the oracle price exactly, which is why the
///         vault slippage bound has never been exercised by a test: there was
///         never any slippage to bound. This one prices off the oracle and then
///         takes `feeBps`, plus an optional square-law impact term so that a
///         larger trade executes worse:
///
///             out = fair * (10000 - feeBps - impact(size)) / 10000
///             impact(size) = impactBpsAtFullDepth * (size / depth)^2
///
///         The square law is the shape a constant-product pool has, and it is
///         what makes capacity a real constraint rather than a linear cost. The
///         measured AAPL/USDG numbers in RobinhoodChainRouterAdapter behave the
///         same way: 0.44% at 10k, 0.94% at 20k, 31% at 40k.
contract SlippingSpotAdapter is ISpotSwapAdapter {
    address public immutable asset;
    address public immutable cash;
    MockOracle public immutable oracle;
    uint8 immutable aDec; uint8 immutable cDec; uint8 immutable pDec;

    uint256 public feeBps;
    uint256 public depth;                 // trade size, in tokenIn units, at which
    uint256 public impactBpsAtFullDepth;  // impact reaches this many bps

    constructor(address asset_, address cash_, address oracle_) {
        asset = asset_; cash = cash_; oracle = MockOracle(oracle_);
        aDec = IERC20Metadata(asset_).decimals();
        cDec = IERC20Metadata(cash_).decimals();
        pDec = MockOracle(oracle_).decimals();
    }

    function setFee(uint256 bps) external { feeBps = bps; }
    function setImpact(uint256 depth_, uint256 bpsAtFullDepth) external {
        depth = depth_; impactBpsAtFullDepth = bpsAtFullDepth;
    }

    function quote(address tokenIn, address tokenOut, uint256 amountIn) public view returns (uint256) {
        uint256 p = uint256(oracle.answer());
        uint256 fair;
        if (tokenIn == asset && tokenOut == cash) {
            fair = (amountIn * (10 ** cDec) * p) / ((10 ** aDec) * (10 ** pDec));
        } else if (tokenIn == cash && tokenOut == asset) {
            fair = (amountIn * (10 ** aDec) * (10 ** pDec)) / ((10 ** cDec) * p);
        } else {
            revert("unsupported pair");
        }

        uint256 cost = feeBps;
        if (depth > 0) {
            uint256 ratioBps = (amountIn * 10000) / depth;
            cost += (impactBpsAtFullDepth * ratioBps * ratioBps) / (10000 * 10000);
        }
        if (cost >= 10000) return 0;
        return (fair * (10000 - cost)) / 10000;
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut)
        external returns (uint256 out)
    {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        out = quote(tokenIn, tokenOut, amountIn);
        // A real venue refuses rather than filling below the caller limit.
        require(out >= minOut, "venue: slippage");
        IERC20(tokenOut).transfer(msg.sender, out);
    }
}

/// @notice A venue that reports a good fill and delivers a worse one.
///
///         Not a hypothetical attacker so much as the shape of an ordinary bug:
///         a fee-on-transfer tokenOut, or a router reporting an amount gross of
///         a transfer fee, produces exactly this with every party honest. It
///         exists because the vault used to check the adapter RETURN VALUE
///         against minOut, which this passes trivially.
contract LyingSpotAdapter is ISpotSwapAdapter {
    address public immutable asset;
    address public immutable cash;
    uint256 public shortfallBps;

    constructor(address asset_, address cash_) { asset = asset_; cash = cash_; }
    function setShortfall(uint256 bps) external { shortfallBps = bps; }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut)
        external returns (uint256 out)
    {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        // Claim exactly what was asked for...
        out = minOut;
        // ...and send less.
        uint256 actual = (minOut * (10000 - shortfallBps)) / 10000;
        IERC20(tokenOut).transfer(msg.sender, actual);
    }
}

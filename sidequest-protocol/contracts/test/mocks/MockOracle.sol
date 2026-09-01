// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AggregatorV3Interface} from "../../src/oracle/MedianOracle.sol";

/// @notice Chainlink-style mock feed with settable answer + updatedAt.
contract MockOracle is AggregatorV3Interface {
    int256 public answer;
    uint256 public updatedAt;
    uint8 public immutable override decimals;

    constructor(int256 a, uint8 d) { answer = a; updatedAt = block.timestamp; decimals = d; }

    function setPrice(int256 a) external { answer = a; updatedAt = block.timestamp; }
    function setUpdatedAt(uint256 t) external { updatedAt = t; }
    function setAnswer(int256 a) external { answer = a; }

    function latestRoundData()
        external view override returns (uint80, int256, uint256, uint256, uint80)
    {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

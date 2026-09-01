// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title Protocol Treasury
/// @notice Central wallet that receives all protocol fees (vault fees, sub fees, etc.)
///         and routes them: 50% to ZorphaBuyback, 50% to operational treasury.
contract ProtocolTreasury is Ownable2Step {
    using SafeERC20 for IERC20;

    address public immutable buyback;
    address public immutable operations;

    uint256 public constant BUYBACK_SHARE_BPS = 5000; // 50%

    event Sweep(address indexed token, uint256 toBuyback, uint256 toOperations);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    constructor(address _buyback, address _operations) Ownable(msg.sender) {
        require(_buyback != address(0), "ProtocolTreasury: zero buyback");
        require(_operations != address(0), "ProtocolTreasury: zero operations");
        buyback = _buyback;
        operations = _operations;
    }

    /// @notice Sweep all of a given token to buyback + operations.
    function sweep(address token) external {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance == 0) return;

        uint256 buybackAmount = (balance * BUYBACK_SHARE_BPS) / 10000;
        uint256 opsAmount = balance - buybackAmount;

        IERC20(token).safeTransfer(buyback, buybackAmount);
        IERC20(token).safeTransfer(operations, opsAmount);

        emit Sweep(token, buybackAmount, opsAmount);
    }

    /// @notice Owner-only escape hatch for tokens misrouted to this contract.
    function rescue(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "ProtocolTreasury: zero recipient");
        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }
}

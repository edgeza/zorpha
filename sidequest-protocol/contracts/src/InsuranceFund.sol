// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title InsuranceFund
/// @notice Dedicated, governance-controlled reserve that backstops the protocol.
///         Receives slashed bonds and holds them until governance pays out to cover
///         a shortfall (exploit, oracle failure, bad-debt event).
contract InsuranceFund is Ownable2Step {
    using SafeERC20 for IERC20;

    event PaidOut(address indexed token, address indexed to, uint256 amount, string reason);

    constructor(address governance) Ownable(governance) {}

    function reserveOf(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    function payout(address token, address to, uint256 amount, string calldata reason)
        external
        onlyOwner
    {
        require(to != address(0), "InsuranceFund: zero recipient");
        require(amount > 0, "InsuranceFund: zero amount");
        IERC20(token).safeTransfer(to, amount);
        emit PaidOut(token, to, amount, reason);
    }
}

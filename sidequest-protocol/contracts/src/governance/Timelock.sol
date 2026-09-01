// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title Timelock
/// @notice Thin wrapper around TimelockController.
/// @dev   After deployment, the deployer (admin) should grant EXECUTOR_ROLE to
///        the desired executor address via `grantRole(EXECUTOR_ROLE, executor)`.
contract Timelock is TimelockController {
    constructor(
        uint256 delay_,
        address[] memory proposers,
        address[] memory executors,
        address admin
    )
        TimelockController(delay_, proposers, executors, admin)
    {}
}

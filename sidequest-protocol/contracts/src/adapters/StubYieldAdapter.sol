// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IYieldAdapter} from "../interfaces/IYieldAdapter.sol";

/// @title StubYieldAdapter
/// @notice No-op IYieldAdapter that simply holds the underlying on its own
///         balance. Used as the V1 default for the YieldVault so the slot
///         is functional even before a real lending market is wired up.
///         `totalAssets()` is always equal to the adapter's own underlying
///         balance, i.e. zero yield, zero risk.
contract StubYieldAdapter is IYieldAdapter, AccessControl {
    using SafeERC20 for IERC20;

    IERC20 public immutable asset;

    constructor(address asset_, address admin_) {
        require(asset_ != address(0) && admin_ != address(0), "zero addr");
        asset = IERC20(asset_);
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    }

    function totalAssets() external view override returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function deposit(uint256 amount) external override {
        // Pull `amount` from caller (vault). The vault has already approved.
        asset.safeTransferFrom(msg.sender, address(this), amount);
    }

    function withdraw(uint256 amount) external override {
        // Send `amount` back to caller (vault).
        asset.safeTransfer(msg.sender, amount);
    }
}

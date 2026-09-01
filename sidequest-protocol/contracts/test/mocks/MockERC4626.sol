// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IMockMintable {
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
}

/// @notice ERC-4626 stand-in for a curated vault such as Steakhouse USDG.
///
///         Two knobs the real thing has and a plain mock does not:
///
///         `accrue()` mints underlying straight to the vault, which raises the
///         share price exactly the way earned yield does.
///
///         `setLiquidityCap()` caps `maxWithdraw`/`maxRedeem`, modelling a vault
///         whose markets are fully utilised. Without it there is no way to test
///         the shortfall path, and the shortfall path is the one that decides
///         whether depositors can exit during a crunch.
contract MockERC4626 is ERC4626 {
    /// @dev type(uint256).max means "no constraint".
    uint256 public liquidityCap = type(uint256).max;

    constructor(IERC20 asset_, string memory name_, string memory symbol_)
        ERC4626(asset_)
        ERC20(name_, symbol_)
    {}

    /// @notice Simulate earned yield by donating underlying to the vault.
    function accrue(uint256 amount) external {
        IMockMintable(asset()).mint(address(this), amount);
    }

    /// @notice Simulate a loss by burning underlying held by the vault.
    function slash(uint256 amount) external {
        IMockMintable(asset()).burn(address(this), amount);
    }

    function setLiquidityCap(uint256 cap) external {
        liquidityCap = cap;
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        uint256 natural = super.maxWithdraw(owner);
        return natural < liquidityCap ? natural : liquidityCap;
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        uint256 natural = super.maxRedeem(owner);
        if (liquidityCap == type(uint256).max) return natural;
        uint256 capped = convertToShares(liquidityCap);
        return natural < capped ? natural : capped;
    }
}

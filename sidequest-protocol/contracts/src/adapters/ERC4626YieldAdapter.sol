// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IYieldAdapter} from "../interfaces/IYieldAdapter.sol";

/// @title ERC4626YieldAdapter
/// @notice Routes YieldVault deposits into any ERC-4626 vault.
///
///         This is what replaces `StubYieldAdapter`, whose own comment concedes
///         "zero yield, zero risk" — a USDG yield vault that earns nothing is a
///         demo, not a product.
///
///         The target is deliberately "any ERC-4626" rather than "Morpho". On
///         Robinhood Chain the deepest stablecoin venue is Steakhouse USDG
///         (a MetaMorpho vault), which is plain ERC-4626, so no Morpho-specific
///         integration is required and none is written. That also means the same
///         adapter serves a mock vault on testnet, where none of these protocols
///         are deployed.
///
///         Trust assumptions worth stating plainly: depositors take on the
///         target vault's risk. Its curator can reallocate, its markets can go
///         bad, and its shares can lose value. Swapping this adapter out is
///         gated behind the Timelock on YieldVault for exactly that reason.
contract ERC4626YieldAdapter is IYieldAdapter, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Only the YieldVault that owns this adapter may move funds.
    bytes32 public constant VAULT_ROLE = keccak256("VAULT_ROLE");

    /// @notice The underlying this adapter accepts. Must equal `target.asset()`.
    IERC20 public immutable asset;

    /// @notice The ERC-4626 vault this adapter deposits into.
    IERC4626 public immutable target;

    error ZeroAddress();
    error AssetMismatch(address expected, address actual);

    /// @notice Emitted when a withdrawal could not be fully serviced.
    /// @dev Not an error. See `withdraw` for why this is a shortfall event
    ///      rather than a revert.
    event WithdrawShortfall(uint256 requested, uint256 delivered);

    event Deposited(uint256 assets, uint256 sharesReceived);
    event Withdrawn(uint256 assets);

    constructor(address asset_, address target_, address admin_) {
        if (asset_ == address(0) || target_ == address(0) || admin_ == address(0)) {
            revert ZeroAddress();
        }

        address targetAsset = IERC4626(target_).asset();
        if (targetAsset != asset_) revert AssetMismatch(asset_, targetAsset);

        asset = IERC20(asset_);
        target = IERC4626(target_);

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);

        // Approved once. The target is immutable, so there is no allowance to
        // revoke later and no second spender to worry about.
        IERC20(asset_).forceApprove(target_, type(uint256).max);
    }

    // ─── IYieldAdapter ───────────────────────────────────────────────────────

    /// @notice Underlying currently attributable to this adapter.
    /// @dev Reports the economic value of the position, which is what vault
    ///      shares are actually worth, plus anything sitting idle here. It does
    ///      NOT report only the immediately-liquid portion: understating NAV
    ///      whenever the target is temporarily illiquid would let anyone redeem
    ///      cheaply during a liquidity crunch and buy the discount back
    ///      afterwards. `maxWithdrawable()` is the view for liquidity.
    function totalAssets() external view override returns (uint256) {
        uint256 shares = target.balanceOf(address(this));
        uint256 inTarget = shares == 0 ? 0 : target.convertToAssets(shares);
        return inTarget + asset.balanceOf(address(this));
    }

    /// @notice Pull `amount` from the vault and deposit it into the target.
    function deposit(uint256 amount) external override onlyRole(VAULT_ROLE) nonReentrant {
        if (amount == 0) return;

        asset.safeTransferFrom(msg.sender, address(this), amount);

        // Deposit whatever is actually here, not just `amount`: a previous
        // partial withdrawal or a rounding remainder can leave dust behind, and
        // dust that is never redeposited is yield the depositors do not earn.
        uint256 toDeposit = asset.balanceOf(address(this));
        uint256 shares = target.deposit(toDeposit, address(this));

        emit Deposited(toDeposit, shares);
    }

    /// @notice Recall `amount` of underlying and send it back to the vault.
    /// @dev Delivers `min(amount, what can actually be realised)` rather than
    ///      reverting on a shortfall, for two reasons.
    ///
    ///      First, migration. `YieldVault.setAdapter` calls
    ///      `withdraw(totalAssets())`, and a hard revert on a one-wei rounding
    ///      difference would permanently brick the ability to move off this
    ///      adapter.
    ///
    ///      Second, a real shortfall is when you most need the exit to work at
    ///      all. Under-delivering is safe here because the depositor is still
    ///      protected one level up: YieldVault transfers the full redemption to
    ///      the user out of its own balance, so a short recall makes that
    ///      transfer revert and the redemption fails cleanly. Nobody is paid out
    ///      on assets that were never recovered.
    function withdraw(uint256 amount) external override onlyRole(VAULT_ROLE) nonReentrant {
        if (amount == 0) return;

        uint256 idle = asset.balanceOf(address(this));

        if (amount > idle) {
            uint256 need = amount - idle;
            uint256 shares = target.balanceOf(address(this));
            uint256 held = shares == 0 ? 0 : target.convertToAssets(shares);

            if (need >= held) {
                // Taking everything. Redeem by share count rather than asking
                // for an asset amount: `withdraw()` rounds the share cost UP and
                // can demand one more share than exists, which reverts on
                // exactly the full-exit path migration depends on.
                // slither-disable-next-line unused-return
                if (shares > 0) target.redeem(shares, address(this), address(this));
            } else {
                uint256 liquid = target.maxWithdraw(address(this));
                // Both branches ignore the return on purpose: what actually
                // arrived is measured by balance delta afterwards, which is the
                // only number a miscounting target cannot lie about.
                // slither-disable-next-line unused-return
                target.withdraw(need < liquid ? need : liquid, address(this), address(this));
            }
        }

        uint256 available = asset.balanceOf(address(this));
        uint256 delivered = amount < available ? amount : available;

        if (delivered < amount) emit WithdrawShortfall(amount, delivered);
        if (delivered > 0) asset.safeTransfer(msg.sender, delivered);

        emit Withdrawn(delivered);
    }

    // ─── Views ───────────────────────────────────────────────────────────────

    /// @notice What could actually be recalled right now, as opposed to what the
    ///         position is worth. Divergence means the target is illiquid.
    function maxWithdrawable() external view returns (uint256) {
        return target.maxWithdraw(address(this)) + asset.balanceOf(address(this));
    }
}

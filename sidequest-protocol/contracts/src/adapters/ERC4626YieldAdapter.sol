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
///         "zero yield, zero risk"; a USDG yield vault that earns nothing is a
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

    /// @notice How far below the deposited amount the received shares may be
    ///         valued before the deposit is refused. 10 bps.
    /// @dev    Wide enough for the wei-level rounding any ERC-4626 conversion
    ///         produces, and for a venue that has genuinely earned yield, which
    ///         also raises the share price. Tight enough that the 25% loss
    ///         measured on an inflated venue cannot pass.
    uint256 internal constant MAX_DEPOSIT_LOSS_BPS = 10;

    /// @notice Absolute floor for the tolerance, in asset units.
    uint256 internal constant MIN_ABS_TOLERANCE = 2;

    error ZeroAddress();
    error AssetMismatch(address expected, address actual);

    /// @notice A deposit bought shares worth materially less than was paid.
    error DepositValueLost(uint256 paid, uint256 worth);

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

        // Value the shares straight back and refuse if the deposit bought
        // materially less than it paid.
        //
        // Without this the share count was taken on trust. An ERC-4626 whose
        // price has been inflated -- donated to while supply was tiny, or just
        // nearly empty -- mints too few shares, and the shortfall goes to the
        // venue's existing holders. `totalAssets()` drops the instant the
        // deposit lands, so every YieldVault depositor eats it at once, and
        // nothing reverts to say so.
        //
        // Found on the testnet fixture, which reached this state through
        // ordinary drill runs rather than an attack: totalAssets 500000017
        // against totalSupply 1, where depositing 1e9 bought shares worth
        // 750000027. A quarter of the deposit, gone silently.
        //
        // Governance approving the venue bounds WHO the target is, not what
        // state it is in: a legitimate venue can be near-empty the day it is
        // approved, and a third party can inflate it afterwards with a plain
        // transfer that costs them nothing they do not recover from the next
        // depositor.
        //
        // Reverting is the safe direction. It propagates to YieldVault.deposit
        // and the would-be depositor keeps their money, rather than buying into
        // a vault that just lost a slice of their principal. It cannot brick
        // migration either -- `setAdapter` unwinds through `withdraw`, which
        // has no such guard by design.
        // Value RETAINED, not just the value of the shares: whatever the venue
        // did not take is still sitting here, still ours, and still counted by
        // `totalAssets()`.
        //
        // Comparing only `convertToAssets(shares)` against the amount paid
        // rejected a venue that partially filled -- the unfilled remainder
        // stays as idle balance in this contract, so no value was lost, but the
        // share leg alone looked short and the guard fired. That would have
        // blocked deposits into any venue with a deposit cap or a utilisation
        // limit, which is a normal thing for a curated vault to have.
        //
        // Reading the balance AFTER the call also answers slither's
        // reentrancy-balance finding on this function directly, rather than by
        // argument: the comparison no longer mixes a pre-call balance with a
        // post-call value.
        uint256 worth = target.convertToAssets(shares) + asset.balanceOf(address(this));
        // slither: reentrancy-balance on the comparison below, flagging
        // `toDeposit` as a balance read before the external call and used in a
        // condition after it.
        //
        // Inherent to the check rather than a defect in it. `toDeposit` is what
        // was PAID, which can only be measured before paying; `worth` is what
        // is HELD, which can only be measured after. A guard that compared two
        // post-call figures would not be measuring a loss at all.
        //
        // Not exploitable. `deposit` is nonReentrant and VAULT_ROLE-gated, so a
        // hostile target cannot re-enter it or `withdraw`. It does hold an
        // unlimited approval on this contract, granted in the constructor, so
        // it could pull more than `toDeposit` during its own call -- but the
        // adapter's balance at that moment IS `toDeposit`, having just received
        // exactly that from the vault, so there is nothing further to take. And
        // a target that pulled the assets without issuing shares makes `worth`
        // smaller, which trips the guard rather than evading it.
        uint256 tolerance = (toDeposit * MAX_DEPOSIT_LOSS_BPS) / 10_000;
        // A bps tolerance rounds to zero on dust, where one wei of ordinary
        // rounding would then trip the guard and block the deposit.
        if (tolerance < MIN_ABS_TOLERANCE) tolerance = MIN_ABS_TOLERANCE;
        // slither-disable-next-line reentrancy-balance
        if (worth + tolerance < toDeposit) revert DepositValueLost(toDeposit, worth);

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

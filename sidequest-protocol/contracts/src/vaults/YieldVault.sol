// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IYieldAdapter} from "../interfaces/IYieldAdapter.sol";
import {FirstLossEscrow} from "../leadership/FirstLossEscrow.sol";
import {ReceiptRenderer} from "../lib/ReceiptRenderer.sol";

/// @title YieldVault
/// @notice Zorpha V1 USDC yield-slot vault. Deposits USDC, routes through a
///         pluggable `IYieldAdapter`. V1 ships with `StubYieldAdapter` (zero
///         yield, zero risk); V2 drops in a Morpho/Pyth adapter.
contract YieldVault is ERC4626, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant RISK_COUNCIL_ROLE = keccak256("RISK_COUNCIL_ROLE");
    bytes32 public constant ADAPTER_SETTER_ROLE = keccak256("ADAPTER_SETTER_ROLE");

    IYieldAdapter public adapter;

    /// @notice The leader's subordinated capital, or zero for a vault without
    ///         one. When set, its balance stands between a loss and the
    ///         depositors, and performance fees are split through it.
    address public firstLossEscrow;

    uint256 public rebalanceCount;
    uint256 public performanceFee;
    uint256 public highWaterMark;
    uint256 public performanceFeeAccrued;
    address public feeRecipient;
    bool    public isCircuitBreakerActive;

    event AdapterSet(address indexed oldAdapter, address indexed newAdapter);
    event AdapterMigrated(address indexed oldAdapter, address indexed newAdapter, uint256 amount);
    event FeesClaimed(address indexed recipient, uint256 amount);
    event FeeRecipientSet(address indexed oldRecipient, address indexed newRecipient);
    event FirstLossEscrowSet(address indexed escrow);
    event Rebalanced(
        uint256 navPerShare,
        uint256 totalAssetsInAdapter,
        uint256 adapterBalance,
        uint256 nonce,
        bytes32 commitment
    );
    event CircuitBreakerSet(bool active);
    event HighWaterMarkReset(uint256 nav);
    event AccruedFeesWrittenDown(uint256 amount, uint256 remaining);

    error CircuitBreakerActive();
    error AdapterUnset();
    error BadWeights();

    constructor(
        address asset_,
        address adapter_,
        string memory name_,
        string memory symbol_,
        uint256 performanceFeeBps_,
        address feeRecipient_,
        address admin_
    ) ERC20(name_, symbol_) ERC4626(IERC20(asset_)) {
        require(asset_ != address(0), "zero asset");
        require(feeRecipient_ != address(0) && admin_ != address(0), "zero addr");
        require(performanceFeeBps_ <= 10000, "bad fee bps");

        adapter = IYieldAdapter(adapter_);
        performanceFee = performanceFeeBps_;
        feeRecipient = feeRecipient_;
        highWaterMark = 10 ** IERC20Metadata(asset_).decimals();

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);

        if (adapter_ != address(0)) {
            IERC20(asset_).forceApprove(adapter_, type(uint256).max);
        }
    }

    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    // ─── ERC-4626 hooks: route capital through the adapter ───────────────────
    //
    // AUDIT V-01. `totalAssets()` below values shares against the ADAPTER's
    // balance, but the vault previously never overrode these hooks. Deposited
    // funds therefore sat on the vault, the adapter balance stayed at zero, and
    // so `totalAssets()` returned 0 while `totalSupply()` was positive, share
    // price of zero. A depositor burned every share and received nothing, while
    // their principal stayed stranded on the vault. It also inflated share
    // issuance for the next depositor, diluting the first.
    //
    // The invariant these two overrides restore, and which the test suite now
    // asserts after every deposit and withdrawal:
    //
    //     adapter.totalAssets() == totalAssets() + performanceFeeAccrued
    //
    // i.e. every asset the vault accounts for is actually held where it is
    // being counted.

    // Reentrancy guards on all four ERC-4626 entrypoints.
    //
    // The hooks below make an external call to the adapter *after* shares have
    // been minted or burned. A malicious or compromised adapter re-entering at
    // that moment would observe `totalAssets()` mid-flight, funds already
    // debited from one side but not yet credited to the other; and mint shares
    // against a stale, understated NAV. Installing the adapter is timelocked,
    // so this needs a compromised governance action to reach; guarding it costs
    // one storage slot and removes the window entirely.

    // slither: reentrancy-no-eth on the `highWaterMark` write below.
    //
    // `_markFirstEntry` has to run AFTER `super.deposit`, and that is not a
    // style choice: it reads `getNavPerShare()`, which returns the
    // `10 ** decimals()` sentinel while supply is zero. Reading it before the
    // mint would record the sentinel as the mark and disable performance fees
    // for the life of the contract, which is the exact bug the early return in
    // `_evaluateFees` exists to prevent. So the order cannot be inverted.
    //
    // Unreachable as reported. Both entrypoints are `nonReentrant`, so an
    // adapter calling back into deposit/mint/withdraw/redeem reverts. The only
    // other readers of `highWaterMark` are `_evaluateFees` (reached solely
    // through those same guarded entrypoints and the keeper-only
    // `evaluateFees`) and `highWaterMarkValue`, a view.
    //
    // What remains is narrower and worth stating: a malicious adapter could
    // under-report `totalAssets()` during its own callback, so the mark records
    // a NAV lower than reality and future gains are overcharged. Installing an
    // adapter is timelocked, so that needs a compromised governance action --
    // the same precondition the block above already accepts for the hooks.
    // slither-disable-next-line reentrancy-no-eth
    function deposit(uint256 assets, address receiver)
        public
        override
        nonReentrant
        returns (uint256)
    {
        _evaluateFees();
        bool wasEmpty = totalSupply() == 0;
        uint256 shares = super.deposit(assets, receiver);
        if (wasEmpty) _markFirstEntry();
        return shares;
    }

    // slither: reentrancy-no-eth on the `highWaterMark` write below.
    //
    // `_markFirstEntry` has to run AFTER `super.deposit`, and that is not a
    // style choice: it reads `getNavPerShare()`, which returns the
    // `10 ** decimals()` sentinel while supply is zero. Reading it before the
    // mint would record the sentinel as the mark and disable performance fees
    // for the life of the contract, which is the exact bug the early return in
    // `_evaluateFees` exists to prevent. So the order cannot be inverted.
    //
    // Unreachable as reported. Both entrypoints are `nonReentrant`, so an
    // adapter calling back into deposit/mint/withdraw/redeem reverts. The only
    // other readers of `highWaterMark` are `_evaluateFees` (reached solely
    // through those same guarded entrypoints and the keeper-only
    // `evaluateFees`) and `highWaterMarkValue`, a view.
    //
    // What remains is narrower and worth stating: a malicious adapter could
    // under-report `totalAssets()` during its own callback, so the mark records
    // a NAV lower than reality and future gains are overcharged. Installing an
    // adapter is timelocked, so that needs a compromised governance action --
    // the same precondition the block above already accepts for the hooks.
    // slither-disable-next-line reentrancy-no-eth
    function mint(uint256 shares, address receiver)
        public
        override
        nonReentrant
        returns (uint256)
    {
        _evaluateFees();
        bool wasEmpty = totalSupply() == 0;
        uint256 assets = super.mint(shares, receiver);
        if (wasEmpty) _markFirstEntry();
        return assets;
    }

    /// @dev Set the high-water mark to the price the first depositor into an
    ///      empty vault actually paid.
    ///
    ///      `_evaluateFees` returns early while `totalSupply()` is zero, and it
    ///      has to: the empty-vault NAV is a `10 ** decimals()` sentinel a
    ///      million times any real price, and letting that reach the mark would
    ///      ratchet it out of reach and disable performance fees for the life of
    ///      the contract. The side effect is that the first depositor never
    ///      marks their own entry, so the mark stays wherever the previous
    ///      cohort left it.
    ///
    ///      That is fine on a vault that empties to nothing. It is not fine when
    ///      the vault holds a residue while empty -- rounding dust, a donation to
    ///      the venue, yield earned on the remainder -- because the ERC-4626
    ///      decimal offset then puts the incoming entry NAV ABOVE the stale mark,
    ///      and at redemption the fee is charged from the mark rather than from
    ///      where this depositor bought in. They pay a performance fee on
    ///      appreciation that happened before they arrived: measured at 12-20%
    ///      over on testnet 46630, deterministically, once per cycle. See
    ///      docs/FINDINGS-EQUALISATION.md.
    ///
    ///      The reset is unconditional rather than `if (nav > highWaterMark)`.
    ///      An empty vault has no holders for the mark to protect, so there is
    ///      nobody it can be lowered at the expense of, and doing it
    ///      unconditionally also closes the mirror-image case: an entry BELOW a
    ///      stale high mark used to ride free while the leader earned nothing on
    ///      real gains.
    ///
    ///      Reading `getNavPerShare()` is safe here where it is not in
    ///      `_evaluateFees`: supply is non-zero by this point, so it returns a
    ///      real price and not the sentinel.
    function _markFirstEntry() internal {
        uint256 nav = getNavPerShare();
        if (nav != highWaterMark) {
            highWaterMark = nav;
            emit HighWaterMarkReset(nav);
        }
    }

    function withdraw(uint256 assets, address receiver, address owner)
        public
        override
        nonReentrant
        returns (uint256)
    {
        _evaluateFees();
        return super.withdraw(assets, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner)
        public
        override
        nonReentrant
        returns (uint256)
    {
        _evaluateFees();
        return super.redeem(shares, receiver, owner);
    }

    /// @dev Pull assets in from the depositor, then forward them to the adapter.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares)
        internal
        override
    {
        super._deposit(caller, receiver, assets, shares);
        _pushToAdapter(assets);
    }

    /// @dev Recall assets from the adapter first, so the vault actually holds
    ///      what `super._withdraw` is about to transfer out.
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal override {
        _pullFromAdapter(assets);

        // Whatever the adapter could not return, the leader's capital covers,
        // up to its balance. This is the moment the subordination is real: the
        // depositor is paid out of the escrow before the vault reports a loss
        // to them.
        address esc = firstLossEscrow;
        if (esc != address(0)) {
            uint256 held = IERC20(asset()).balanceOf(address(this));
            // The amount absorbed is deliberately not checked. A buffer that
            // cannot cover the whole shortfall pays what it has, and the
            // depositor takes the remainder -- that is the designed waterfall,
            // not a failure. super._withdraw below transfers against the real
            // balance, so an underpaying escrow reverts there rather than
            // silently shorting anyone.
            // slither-disable-next-line unused-return
            if (held < assets) FirstLossEscrow(esc).absorb(assets - held);
        }

        super._withdraw(caller, receiver, owner, assets, shares);
    }

    /// @dev Forward idle underlying to the adapter. No-op when no adapter is
    ///      wired, in which case the vault holds the assets itself and
    ///      `totalAssets()` reads its own balance.
    function _pushToAdapter(uint256 amount) internal {
        if (amount == 0 || address(adapter) == address(0)) return;
        adapter.deposit(amount);
    }

    /// @dev Recall up to `amount` from the adapter, topping up from the vault's
    ///      own idle balance first. Clamped to what the adapter reports so a
    ///      partially-liquid adapter cannot make the whole withdrawal revert on
    ///      an arithmetic error rather than a clear shortfall.
    function _pullFromAdapter(uint256 amount) internal {
        if (amount == 0 || address(adapter) == address(0)) return;

        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (idle >= amount) return;

        uint256 needed = amount - idle;
        uint256 available = adapter.totalAssets();
        adapter.withdraw(needed < available ? needed : available);
    }

    /// @notice The vault's own assets, net of accrued fees and EXCLUDING any
    ///         support from the first-loss escrow.
    /// @dev The escrow measures its own coverage ratio against this. Measuring
    ///      against `totalAssets()` would be circular: the buffer would inflate
    ///      the denominator it is compared to and report better coverage than
    ///      actually exists.
    function rawAssets() public view returns (uint256) {
        uint256 held = heldAssets();
        return held > performanceFeeAccrued ? held - performanceFeeAccrued : 0;
    }

    /// @notice Everything the vault controls, gross of the accrued fee claim.
    /// @dev Extracted from `rawAssets` so the fee reconciliation below is capped
    ///      against exactly the figure `rawAssets` nets against, rather than a
    ///      second expression that has to be kept in step with it by hand.
    function heldAssets() public view returns (uint256) {
        return address(adapter) == address(0)
            ? IERC20(asset()).balanceOf(address(this))
            : adapter.totalAssets();
    }

    /// @notice Assets the high-water mark implies the vault should hold.
    function highWaterMarkValue() public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 0;
        return (highWaterMark * supply) / (10 ** decimals());
    }

    /// @notice How much of the escrow is currently standing behind depositors.
    ///
    /// @dev Capped at the drawdown below the high-water mark, so in normal
    ///      times this is zero and the leader's capital is NOT part of NAV.
    ///      That matters: counting it unconditionally would mean a new
    ///      depositor buys shares priced to include the leader's own money.
    ///
    ///      Support enters NAV rather than being paid out to whoever exits
    ///      first. Every share therefore carries its pro-rata slice of the
    ///      buffer and a redeeming holder draws only that slice. A buffer paid
    ///      first-come-first-served would be a run incentive wearing a safety
    ///      jacket.
    function escrowSupport() public view returns (uint256) {
        address esc = firstLossEscrow;
        if (esc == address(0)) return 0;

        uint256 raw = rawAssets();
        uint256 mark = highWaterMarkValue();
        if (raw >= mark) return 0;

        uint256 shortfall = mark - raw;
        uint256 avail = FirstLossEscrow(esc).available();
        return shortfall < avail ? shortfall : avail;
    }

    function totalAssets() public view override returns (uint256) {
        return rawAssets() + escrowSupport();
    }

    function getNavPerShare() public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 10 ** decimals();
        return (totalAssets() * (10 ** decimals())) / supply;
    }

    function maxDeposit(address) public view override returns (uint256) {
        if (isCircuitBreakerActive) return 0;
        if (totalSupply() > 0 && totalAssets() == 0) return 0;
        return type(uint256).max;
    }

    function maxMint(address) public view override returns (uint256) {
        if (isCircuitBreakerActive) return 0;
        if (totalSupply() > 0 && totalAssets() == 0) return 0;
        return type(uint256).max;
    }

    // NOT overridden, and that is a decision backed by mainnet.
    //
    // The inherited maxWithdraw/maxRedeem derive from the holder's share
    // balance and totalAssets(), so they describe what a position is WORTH and
    // not whether the venue can pay it. That is a real ERC-4626 imprecision: in
    // an illiquid venue a depositor is told a number their withdraw reverts on.
    //
    // The obvious fix -- bound them by what the adapter reports as liquid --
    // was implemented, went green against MockERC4626, and is WRONG. The real
    // Steakhouse USDG vault on Robinhood Chain mainnet reports:
    //
    //     maxDeposit(anyone)   0
    //     maxWithdraw(anyone)  0
    //     maxRedeem(anyone)    0
    //     totalAssets          434,407,278,580,972      (~434m USDG)
    //
    // while deposits and withdrawals through it demonstrably succeed -- the
    // fork tests in test/fork/MainnetAdapters.t.sol do both against the live
    // contract. Propagating those views capped maxRedeem at ZERO on the real
    // venue and froze every exit; test_FullVaultStackAgainstSteakhouse caught
    // it, and only because that suite had just been made to actually run.
    //
    // Rounding failed it independently: converting a liquidity figure into
    // shares floors, so maxRedeem came back a few wei under a holder's full
    // balance and redeeming everything reverted even with ample liquidity.
    //
    // So the imprecision is accepted deliberately. Overstating maxWithdraw
    // fails a transaction that should not have been offered; understating it
    // traps depositors in a vault that could have paid them. Between a view
    // that is optimistic and a view that lies in the direction of a freeze,
    // this vault takes the optimistic one -- and _withdraw still fails a
    // shortfall rather than underpaying anybody.

    /// @notice "Rebalance" the yield slot by re-pushing funds into / pulling
    ///         funds from the adapter. V1 with StubYieldAdapter this is a no-op
    ///         for accounting but still emits a receipt; the manager's record
    ///         of having reviewed the position.
    function rebalanceTo() external onlyRole(KEEPER_ROLE) nonReentrant {
        if (isCircuitBreakerActive) revert CircuitBreakerActive();

        rebalanceCount += 1;
        uint256 nav = getNavPerShare();
        uint256 adapterBal = address(adapter) == address(0)
            ? 0
            : IERC20(asset()).balanceOf(address(adapter));
        uint256 ta = totalAssets();

        bytes32 commit = ReceiptRenderer.commitment(
            msg.sender,
            address(this),
            0,
            nav,
            ta,
            adapterBal,
            rebalanceCount,
            block.timestamp,
            bytes32(0)
        );

        emit Rebalanced(nav, ta, adapterBal, rebalanceCount, commit);
    }

    /// @notice Swap the yield source, migrating the position in the same
    ///         transaction. Timelock-gated.
    ///
    ///         Migration is not optional: `totalAssets()` is measured against
    ///         whichever adapter is currently set, so repointing without moving
    ///         the capital would strand every deposit in the old adapter and
    ///         reprice every share to zero; the same class of failure as
    ///         audit finding V-01.
    ///         `nonReentrant` is load-bearing here, not decorative: between
    ///         `old.withdraw(...)` and the write of the new `adapter`, the
    ///         vault holds the capital while `totalAssets()` still reads the
    ///         old adapter; which is now drained, so NAV reads as zero. A
    ///         re-entrant deposit in that window would mint against a share
    ///         price of nothing.
    // slither: reaching the cross-function reentrancy this describes requires
    // the currently-installed adapter to be hostile, and installing one is
    // ADAPTER_SETTER_ROLE. The guard already blocks re-entry into every
    // state-changing path; what is left is rawAssets(), a view, which such an
    // adapter could only mislead itself with.
    // slither-disable-next-line reentrancy-no-eth
    function setAdapter(address newAdapter) external onlyRole(ADAPTER_SETTER_ROLE) nonReentrant {
        require(newAdapter != address(0), "YieldVault: zero adapter");

        IYieldAdapter old = adapter;
        uint256 migrating;
        if (address(old) != address(0)) {
            migrating = old.totalAssets();
            if (migrating > 0) {
                old.withdraw(migrating);
            }
            IERC20(asset()).forceApprove(address(old), 0);
        }

        adapter = IYieldAdapter(newAdapter);
        IERC20(asset()).forceApprove(newAdapter, type(uint256).max);

        // Push everything the vault now holds, including anything that was idle
        // before the swap, so the new adapter's balance is the full position.
        uint256 toPush = IERC20(asset()).balanceOf(address(this));
        if (toPush > 0) {
            IYieldAdapter(newAdapter).deposit(toPush);
        }

        emit AdapterSet(address(old), newAdapter);
        emit AdapterMigrated(address(old), newAdapter, migrating);
    }

    /// @notice Pay accrued performance fees to the fee recipient.
    ///
    ///         Without this, `performanceFeeAccrued` only ever subtracted from
    ///         `totalAssets()` and was never payable to anyone; it depressed
    ///         every holder's NAV in exchange for nothing, and `feeRecipient`
    ///         was a dead storage slot. Claiming leaves `totalAssets()`
    ///         unchanged: the accrual is zeroed at the same moment the assets
    ///         leave.
    function claimFees() external onlyRole(DEFAULT_ADMIN_ROLE) returns (uint256 amount) {
        amount = performanceFeeAccrued;
        if (amount == 0) return 0;

        performanceFeeAccrued = 0;
        _pullFromAdapter(amount);

        address esc = firstLossEscrow;
        if (esc == address(0)) {
            IERC20(asset()).safeTransfer(feeRecipient, amount);
            emit FeesClaimed(feeRecipient, amount);
        } else {
            // Split leader/protocol, and rebuild the buffer out of the
            // leader's share first if it is short. A leader who has taken a
            // drawdown restores the protection before they earn again.
            IERC20(asset()).forceApprove(esc, amount);
            FirstLossEscrow(esc).splitFees(amount);
            IERC20(asset()).forceApprove(esc, 0);
            emit FeesClaimed(esc, amount);
        }
    }

    function setFeeRecipient(address newRecipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newRecipient != address(0), "YieldVault: zero recipient");
        emit FeeRecipientSet(feeRecipient, newRecipient);
        feeRecipient = newRecipient;
    }

    /// @notice Install the leader's first-loss escrow. Settable once.
    /// @dev One-shot on purpose. A swappable escrow is a swappable promise:
    ///      an admin could point the vault at an empty contract the moment a
    ///      drawdown started and the protection would evaporate exactly when
    ///      it was being relied on.
    function setFirstLossEscrow(address escrow_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(firstLossEscrow == address(0), "YieldVault: escrow already set");
        require(escrow_ != address(0), "YieldVault: zero escrow");
        require(FirstLossEscrow(escrow_).vault() == address(this), "YieldVault: escrow vault mismatch");
        require(address(FirstLossEscrow(escrow_).asset()) == asset(), "YieldVault: escrow asset mismatch");
        firstLossEscrow = escrow_;
        emit FirstLossEscrowSet(escrow_);
    }

    function setCircuitBreaker(bool active) external onlyRole(RISK_COUNCIL_ROLE) {
        isCircuitBreakerActive = active;
        emit CircuitBreakerSet(active);
    }

    /// @notice Mark performance fees against the high-water mark.
    /// @dev Kept as a keeper entrypoint so fees can still be marked during a
    ///      long stretch with no deposits or withdrawals. It is no longer the
    ///      ONLY way fees accrue, see `_evaluateFees` for why that mattered.
    function evaluateFees() external onlyRole(KEEPER_ROLE) {
        _evaluateFees();
    }

    /// @dev Accrue the performance fee on any gain above the high-water mark.
    ///
    ///      This used to run only when a keeper called `evaluateFees`, which
    ///      left a hole big enough to drive the protocol's whole revenue model
    ///      through: a depositor could enter, wait for the position to earn,
    ///      and redeem before the keeper's next call, taking the entire gain
    ///      and paying nothing. Since half of every fee funds the $ZOR buyback,
    ///      "the keeper was late" and "the protocol earned nothing" were the
    ///      same sentence.
    ///
    ///      Marking on every deposit and withdrawal closes it. Anyone moving
    ///      value in or out of the vault first crystallises what has been
    ///      earned since the last mark, so the fee no longer depends on
    ///      off-chain punctuality.
    ///
    ///      It has to be called from the PUBLIC entrypoints, not the internal
    ///      `_deposit`/`_withdraw` hooks. ERC-4626 fixes the asset amount via
    ///      `previewRedeem` before those hooks run, so accruing inside them
    ///      lands after the number it is supposed to affect has already been
    ///      computed, and the exiting holder still pays nothing.
    ///
    ///      The mark is deliberately set to the PRE-fee NAV. Charging the fee
    ///      drops NAV per share, so the vault has to re-earn that drop before
    ///      it can charge again. That is conservative in the depositor's
    ///      favour, and it is the existing behaviour, left unchanged.
    /// @dev Cap the outstanding fee claim at the value actually behind it, but
    ///      only while the vault is empty.
    ///
    ///      `performanceFeeAccrued` is a fixed number in asset units and
    ///      `heldAssets()` is a live balance. Nothing binds them, so a venue loss
    ///      can leave the claim larger than the assets backing it. While
    ///      shareholders exist that gap is at least priced in: `rawAssets()` nets
    ///      the claim, so anyone entering buys at a NAV reflecting it.
    ///
    ///      Once the vault empties, that stops being true. `getNavPerShare()`
    ///      falls back to a `10 ** decimals()` sentinel that ignores the claim,
    ///      so an incoming depositor pays a price decoupled from an encumbrance
    ///      their own principal then settles. Worse, `_pullFromAdapter` takes
    ///      whatever is available rather than reverting, so `claimFees` goes from
    ///      failing to succeeding the moment that deposit lands: the stale claim
    ///      is paid in full out of the new depositor's money and the books
    ///      balance afterwards. Measured at 9% of the deposit in
    ///      `test_UnclaimedFee_AgainstAVenueLoss`.
    ///
    ///      So reconcile it here, while there are no shareholders to protect. A
    ///      claim larger than the assets behind it is not a claim on the vault,
    ///      it is a lien on whoever deposits next.
    ///
    ///      This deliberately does NOT touch the non-empty case, where the same
    ///      divergence leaves holders bearing a loss the fee recipient is
    ///      insulated from. That is unfair, but it is a dilution among parties
    ///      present when the fee was struck, and correcting it means denominating
    ///      the claim in shares -- a change to what the fee recipient owns. See
    ///      docs/FINDINGS-FEE-CLAIM-BACKING.md, option 3.
    function _reconcileFeeClaimWhenEmpty() internal {
        if (totalSupply() != 0) return;
        uint256 accrued = performanceFeeAccrued;
        uint256 backing = heldAssets();
        if (accrued <= backing) return;
        performanceFeeAccrued = backing;
        emit AccruedFeesWrittenDown(accrued - backing, backing);
    }

    function _evaluateFees() internal {
        // Runs before the early return below, which fires on exactly the case it
        // needs to act on.
        _reconcileFeeClaimWhenEmpty();

        // An empty vault has no NAV to mark and nothing to charge. The early
        // return is load-bearing, not tidiness: `getNavPerShare()` answers
        // `10 ** decimals()` for an empty vault, and share decimals are asset
        // decimals plus a 6-place offset, so that sentinel is a million times
        // larger than any NAV a funded vault will ever report. Letting it reach
        // the line below ratchets `highWaterMark` to a level the vault can
        // never exceed and silently disables performance fees for the life of
        // the contract; which, since half of every fee funds the buyback, also
        // disables $ZOR value accrual. Reachable by anyone able to touch an
        // empty vault, including a keeper calling `evaluateFees` once before
        // the first deposit.
        if (totalSupply() == 0) return;

        uint256 nav = getNavPerShare();
        if (nav <= highWaterMark) return;
        uint256 alpha = nav - highWaterMark;
        uint256 shareUnit = 10 ** decimals();
        uint256 fee = (alpha * totalSupply() * performanceFee) / (shareUnit * 10000);
        if (fee > 0) {
            performanceFeeAccrued += fee;
        }
        highWaterMark = nav;
    }
}

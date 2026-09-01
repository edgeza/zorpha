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
    event Rebalanced(
        uint256 navPerShare,
        uint256 totalAssetsInAdapter,
        uint256 adapterBalance,
        uint256 nonce,
        bytes32 commitment
    );
    event CircuitBreakerSet(bool active);

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
    // so `totalAssets()` returned 0 while `totalSupply()` was positive — share
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
    // that moment would observe `totalAssets()` mid-flight — funds already
    // debited from one side but not yet credited to the other — and mint shares
    // against a stale, understated NAV. Installing the adapter is timelocked,
    // so this needs a compromised governance action to reach; guarding it costs
    // one storage slot and removes the window entirely.

    function deposit(uint256 assets, address receiver)
        public
        override
        nonReentrant
        returns (uint256)
    {
        _evaluateFees();
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver)
        public
        override
        nonReentrant
        returns (uint256)
    {
        _evaluateFees();
        return super.mint(shares, receiver);
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

    function totalAssets() public view override returns (uint256) {
        if (address(adapter) == address(0)) {
            uint256 held = IERC20(asset()).balanceOf(address(this));
            return held > performanceFeeAccrued ? held - performanceFeeAccrued : 0;
        }
        uint256 adapterAssets = adapter.totalAssets();
        return adapterAssets > performanceFeeAccrued ? adapterAssets - performanceFeeAccrued : 0;
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

    /// @notice "Rebalance" the yield slot by re-pushing funds into / pulling
    ///         funds from the adapter. V1 with StubYieldAdapter this is a no-op
    ///         for accounting but still emits a receipt — the manager's record
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
    ///         reprice every share to zero — the same class of failure as
    ///         audit finding V-01.
    ///         `nonReentrant` is load-bearing here, not decorative: between
    ///         `old.withdraw(...)` and the write of the new `adapter`, the
    ///         vault holds the capital while `totalAssets()` still reads the
    ///         old adapter — which is now drained, so NAV reads as zero. A
    ///         re-entrant deposit in that window would mint against a share
    ///         price of nothing.
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
    ///         `totalAssets()` and was never payable to anyone — it depressed
    ///         every holder's NAV in exchange for nothing, and `feeRecipient`
    ///         was a dead storage slot. Claiming leaves `totalAssets()`
    ///         unchanged: the accrual is zeroed at the same moment the assets
    ///         leave.
    function claimFees() external onlyRole(DEFAULT_ADMIN_ROLE) returns (uint256 amount) {
        amount = performanceFeeAccrued;
        if (amount == 0) return 0;

        performanceFeeAccrued = 0;
        _pullFromAdapter(amount);
        IERC20(asset()).safeTransfer(feeRecipient, amount);

        emit FeesClaimed(feeRecipient, amount);
    }

    function setFeeRecipient(address newRecipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newRecipient != address(0), "YieldVault: zero recipient");
        emit FeeRecipientSet(feeRecipient, newRecipient);
        feeRecipient = newRecipient;
    }

    function setCircuitBreaker(bool active) external onlyRole(RISK_COUNCIL_ROLE) {
        isCircuitBreakerActive = active;
        emit CircuitBreakerSet(active);
    }

    /// @notice Mark performance fees against the high-water mark.
    /// @dev Kept as a keeper entrypoint so fees can still be marked during a
    ///      long stretch with no deposits or withdrawals. It is no longer the
    ///      ONLY way fees accrue — see `_evaluateFees` for why that mattered.
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
    function _evaluateFees() internal {
        // An empty vault has no NAV to mark and nothing to charge. The early
        // return is load-bearing, not tidiness: `getNavPerShare()` answers
        // `10 ** decimals()` for an empty vault, and share decimals are asset
        // decimals plus a 6-place offset, so that sentinel is a million times
        // larger than any NAV a funded vault will ever report. Letting it reach
        // the line below ratchets `highWaterMark` to a level the vault can
        // never exceed and silently disables performance fees for the life of
        // the contract — which, since half of every fee funds the buyback, also
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

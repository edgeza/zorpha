// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ISpotSwapAdapter} from "../adapters/RobinhoodChainRouterAdapter.sol";
import {AggregatorV3Interface} from "../oracle/MedianOracle.sol";
import {OracleWindow} from "../oracle/OracleWindow.sol";
import {ReceiptRenderer} from "../lib/ReceiptRenderer.sol";

/// @title SpotVaultMinimal
/// @notice Zorpha V1 long/flat spot vault. ERC-4626, denominated in the
///         underlying. The strategy is long/flat spot: hold the underlying
///         (LONG) or the cash asset (USDC, FLAT). NAV is measured in
///         underlying units, valuing the cash leg via a Chainlink-compatible
///         oracle. Every successful rebalance emits a `Rebalanced` event that
///         the Supabase indexer copies into the public receipts feed; the
///         manager's permanent onchain track record.
///
///         Slashed from the ZENTORY `SpotVault` for Zorpha V1:
///           - no perp-style accounting (no currentMarkPrice / currentDirection)
///           - no Per-vault HyperCoreAdapter
///           - no StrategyExecutor.executeSignal path (kept in StrategyExecutorMinimal)
///           - trimmed emergency path (kept core cooldown, simplified logic)
contract SpotVaultMinimal is ERC4626, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant RISK_COUNCIL_ROLE = keccak256("RISK_COUNCIL_ROLE");

    IERC20 public immutable cashAsset;
    AggregatorV3Interface public immutable oracle;
    uint256 public immutable maxOracleStaleness;
    ISpotSwapAdapter public swapAdapter;

    uint8 internal immutable _assetDec;
    uint8 internal immutable _cashDec;
    uint8 internal immutable _priceDec;

    uint16 public targetWeightBps;
    uint16 public immutable rebalanceThresholdBps;
    uint16 public immutable maxSlippageBps;

    /// @notice The exiting holder's own conversion cost, in bps of the amount
    ///         actually converted. Charged in `_deliverableAssets` (the cash-leg
    ///         haircut), `previewRedeem` and `previewWithdraw` (the net payout
    ///         and its inverse), `maxRedeem` and `maxWithdraw` (the same inverse
    ///         formula), and `_withdraw`'s cash gross-up. Never in a rebalance's
    ///         swap bound -- that stays `maxSlippageBps`'s job. See
    ///         docs/design/stock-vault-exit-paths.md, "Who bears the conversion
    ///         cost, settled".
    ///
    ///         Pricing exits near the venue's fee tier does NOT make exits free
    ///         of risk; it moves the failure. `_withdraw` grosses the cash draw
    ///         up by `10000/(10000 - exitCostBps)` and requires the fill to
    ///         cover the shortfall in full, so if the venue's REALISED cost --
    ///         fee plus price impact -- exceeds `exitCostBps`, the swap reverts
    ///         on `minOut` instead of silently overcharging the exiter.
    ///         `maxRedeem` shrinks by the same haircut, so the advertised bound
    ///         stays executable for the fee component, but price impact is not
    ///         visible to a view function and cannot be bounded in advance.
    ///
    ///         Set it too low and a large exit reverts under impact it never
    ///         priced in. Set it too high and every exit donates the difference
    ///         to whoever stays -- `redeemEmergency` is the in-kind, cost-free
    ///         escape either way. The right value sits above the venue's fee
    ///         tier and well below `maxSlippageBps`'s rebalance bound. It is
    ///         immutable, so this is a one-shot decision made at deploy time.
    uint16 public immutable exitCostBps;

    uint256 public immutable performanceFee;
    uint256 public highWaterMark;
    uint256 public performanceFeeAccrued;
    address public feeRecipient;
    bool public isCircuitBreakerActive;

    uint256 public rebalanceCount;

    /// @notice Per-address cooldown (seconds) between successive emergency redemptions.
    uint256 public emergencyRedeemCooldown;
    mapping(address => uint256) public lastEmergencyRedeemAt;

    event Rebalanced(
        uint16  targetBps,
        uint256 assetLeg,
        uint256 cashLeg,
        uint256 navPerShare,
        uint256 nonce,
        bytes32 commitment
    );
    event PerformanceFeeAccrued(uint256 fee, uint256 navBefore, uint256 navAfter);
    event HighWaterMarkReset(uint256 nav);
    event AccruedFeesWrittenDown(uint256 amount, uint256 remaining);
    event PerformanceFeeClaimed(address indexed recipient, uint256 paid, uint256 stillAccrued);
    event CircuitBreakerSet(bool active);
    /// @param paid       the asset leg paid out, net of the fee share
    /// @param paidCash    the cash leg paid out, in kind
    /// @param haircutAssets the fee share retained, in asset units. This used to
    ///        read zero on a total forfeiture of the cash leg, because
    ///        `grossOwed` was derived from the asset balance alone and so the
    ///        haircut could only ever equal the fee. Both legs are paid now, so
    ///        the fee is genuinely all that is withheld and the field means what
    ///        it says.
    event EmergencyRedeem(
        address indexed caller,
        address indexed receiver,
        address indexed owner,
        uint256 sharesBurned,
        uint256 paid,
        uint256 paidCash,
        uint256 haircutAssets
    );

    error CircuitBreakerActive();
    error BadWeight();
    error StaleOracle(uint256 updatedAt, uint256 nowTs);
    error InvalidOraclePrice(int256 answer);
    error EmergencyCooldownActive(uint256 nextAllowedAt);

    constructor(
        address asset_,
        address cashAsset_,
        address oracle_,
        uint256 maxOracleStaleness_,
        string memory name_,
        string memory symbol_,
        uint16 rebalanceThresholdBps_,
        uint16 maxSlippageBps_,
        uint16 exitCostBps_,
        uint256 performanceFeeBps_,
        address feeRecipient_,
        address admin_,
        uint256 emergencyRedeemCooldown_
    ) ERC20(name_, symbol_) ERC4626(IERC20(asset_)) {
        require(asset_ != address(0) && cashAsset_ != address(0) && oracle_ != address(0), "zero addr");
        require(feeRecipient_ != address(0) && admin_ != address(0), "zero addr");
        // exitCostBps is strictly LESS than 10000, not merely bounded by it:
        // _withdraw grosses up a shortfall by 10000/(10000-exitCostBps), and
        // previewWithdraw/maxRedeem invert that same formula, both of which
        // divide by zero at the boundary. A vault promising to price an exit at
        // its entire cash leg cannot function regardless, so excluding the
        // boundary here costs nothing real. maxSlippageBps keeps the same bound
        // as a sane cap on the slippage a rebalance may tolerate, even though it
        // no longer sits in a division itself.
        require(
            rebalanceThresholdBps_ <= 10000 && maxSlippageBps_ < 10000 && exitCostBps_ < 10000
                && performanceFeeBps_ <= 10000,
            "bad bps"
        );
        require(maxOracleStaleness_ > 0, "zero staleness");
        // Must not be TIGHTER than the oracle's own window, or a report living
        // in the gap drags updatedAt past what this vault accepts. See
        // OracleWindow for the measurement.
        OracleWindow.requireNotTighterThan(oracle_, maxOracleStaleness_);

        cashAsset = IERC20(cashAsset_);
        oracle = AggregatorV3Interface(oracle_);
        maxOracleStaleness = maxOracleStaleness_;
        _assetDec = IERC20Metadata(asset_).decimals();
        _cashDec = IERC20Metadata(cashAsset_).decimals();
        _priceDec = AggregatorV3Interface(oracle_).decimals();

        rebalanceThresholdBps = rebalanceThresholdBps_;
        maxSlippageBps = maxSlippageBps_;
        exitCostBps = exitCostBps_;
        performanceFee = performanceFeeBps_;
        feeRecipient = feeRecipient_;
        highWaterMark = 10 ** _assetDec;

        emergencyRedeemCooldown = emergencyRedeemCooldown_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    }

    /// @dev Inflation-attack mitigation (audit H-1).
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    // ─── ERC-4626 entrypoints ────────────────────────────────────────────────
    //
    // Overridden for two reasons: to mark fees before the preview maths runs
    // (see `_evaluateFees`), and to apply the `nonReentrant` guard this
    // contract already inherits but was not using on the paths that actually
    // move depositor funds.

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

    function _oraclePrice() internal view returns (uint256) {
        // Only startedAt is dropped; every other field is checked just below.
        // slither-disable-next-line unused-return
        (uint80 roundId, int256 answer, , uint256 updatedAt, uint80 answeredInRound) =
            oracle.latestRoundData();
        if (answer <= 0) revert InvalidOraclePrice(answer);
        if (answeredInRound < roundId) revert StaleOracle(updatedAt, block.timestamp);
        if (updatedAt == 0 || block.timestamp - updatedAt > maxOracleStaleness) {
            revert StaleOracle(updatedAt, block.timestamp);
        }
        return uint256(answer);
    }

    function cashToAsset(uint256 cashAmt) public view returns (uint256) {
        // LOAD-BEARING, do not remove as dead weight. This is what lets a vault
        // with no cash leg serve a withdrawal while the oracle is refusing: it
        // returns before _oraclePrice() is ever called. _cashLegValue has a
        // zero-guard of its own that looks like the protection but is not;
        // deleting this line leaves test_RefusingOracle_ZeroCashVaultStillExits
        // failing and that one green. Measured, not assumed.
        if (cashAmt == 0) return 0;
        uint256 p = _oraclePrice();
        return (cashAmt * (10 ** _assetDec) * (10 ** _priceDec)) / ((10 ** _cashDec) * p);
    }

    function assetToCash(uint256 assetAmt) public view returns (uint256) {
        if (assetAmt == 0) return 0;
        uint256 p = _oraclePrice();
        return (assetAmt * (10 ** _cashDec) * p) / ((10 ** _assetDec) * (10 ** _priceDec));
    }

    function grossValue() public view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) + cashToAsset(cashAsset.balanceOf(address(this)));
    }

    function totalAssets() public view override returns (uint256) {
        uint256 gross = grossValue();
        return gross > performanceFeeAccrued ? gross - performanceFeeAccrued : 0;
    }

    function getNavPerShare() public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 10 ** _assetDec;
        return (totalAssets() * (10 ** decimals())) / supply;
    }

    /// @dev Value the cash leg, or report that the oracle is refusing to price
    ///      it. The zero short-circuit is a gas saving and a statement of
    ///      intent, but not the guarantee that a vault needs no oracle.
    function _cashLegValue() internal view returns (uint256 value, bool priced) {
        uint256 cashBal = cashAsset.balanceOf(address(this));
        // A gas saving and a statement of intent, NOT the guarantee. cashToAsset
        // returns zero without touching the oracle anyway, so removing this line
        // changes cost and not behaviour. The property that a vault holding no
        // cash needs no oracle rests on cashToAsset's guard, not this one.
        if (cashBal == 0) return (0, true);
        try this.cashToAsset(cashBal) returns (uint256 v) {
            return (v, true);
        } catch {
            return (0, false);
        }
    }

    /// @dev What an exit could actually realise: the asset leg outright, plus
    ///      the cash leg net of the venue's cut for converting it.
    ///
    ///      `totalAssets()` values the cash leg at the oracle price, and
    ///      realising that value means crossing a venue that charges. The gap
    ///      between those two numbers is the whole defect this fixes, so the
    ///      bounds are computed from the realisable figure and never from
    ///      `totalAssets()`.
    function _deliverableAssets() internal view returns (uint256 amount, bool priced) {
        (uint256 cashValue, bool ok) = _cashLegValue();
        if (!ok) return (0, false);
        uint256 realisable = (cashValue * (10000 - exitCostBps)) / 10000;
        return (IERC20(asset()).balanceOf(address(this)) + realisable, true);
    }

    /// @notice The NET assets `shares` actually deliver through `redeem`: the
    ///         oracle NAV of those shares, less the exiting holder's own share
    ///         of the venue's cost for converting whatever the asset leg
    ///         cannot cover.
    ///
    ///         `gross` is what OpenZeppelin's default implementation returns --
    ///         the plain oracle-priced conversion, with no venue in the loop.
    ///         An exit the asset leg covers outright converts nothing and so
    ///         costs nothing: `net == gross` whenever `gross <= bal`. Otherwise
    ///         `net` is the closed-form solution of `net + cost(net) == gross`,
    ///         `cost(net) = (net - bal) * h / (10000 - h)`:
    ///
    ///             net = (gross * (10000 - h) + bal * h) / 10000
    ///
    ///         floored, so rounding favours the vault.
    ///
    ///         This is the fix itself. The withdrawer used to be paid `gross`
    ///         while the venue's cut on converting the cash leg came out of the
    ///         pool, landing on whoever stayed -- measured at 249bps of a
    ///         remaining holder's position for one stranger's exit. Now the
    ///         exiting holder's own shares pay for their own conversion. See
    ///         docs/design/stock-vault-exit-paths.md, "Who bears the
    ///         conversion cost, settled".
    ///
    ///         `gross` also nets `_pendingPerformanceFee()` out of `totalAssets()`
    ///         before converting, the same treatment `maxWithdraw` already
    ///         applies and for the identical reason: `redeem` calls
    ///         `_evaluateFees()` BEFORE OpenZeppelin's `redeem` re-derives this
    ///         same function internally to fix the payout, so an externally-read
    ///         quote taken while a gain sits unaccrued used to promise `gross`
    ///         computed against a `totalAssets()` that accrual was about to
    ///         shrink -- measured at 124bps of the quote on a pending 1000bps
    ///         fee. Once `_evaluateFees()` has actually run, `nav <= highWaterMark`
    ///         holds and `_pendingPerformanceFee()` answers 0, so this netting is
    ///         a no-op on the delivery path itself; it only corrects the
    ///         standalone view.
    function previewRedeem(uint256 shares) public view override returns (uint256) {
        uint256 netAssets = totalAssets();
        uint256 pendingFee = _pendingPerformanceFee();
        netAssets = netAssets > pendingFee ? netAssets - pendingFee : 0;
        uint256 gross = Math.mulDiv(shares, netAssets + 1, totalSupply() + 10 ** _decimalsOffset(), Math.Rounding.Floor);
        uint256 bal = IERC20(asset()).balanceOf(address(this));
        if (gross <= bal) return gross;
        return (gross * (10000 - exitCostBps) + bal * exitCostBps) / 10000;
    }

    /// @notice The shares `withdraw` must burn to deliver a NET payout of
    ///         `assets`.
    ///
    ///         The inverse of `previewRedeem`: a caller who wants `assets` net
    ///         must present shares worth `assets` plus that request's own
    ///         share of the conversion cost, i.e. the `gross` for which
    ///         `previewRedeem` would answer exactly `assets`:
    ///
    ///             gross = assets                                          if assets <= bal
    ///             gross = ceil((assets * 10000 - bal * h) / (10000 - h))   otherwise
    ///
    ///         Both the inverse and the final share conversion round UP, so
    ///         the vault is never left a wei short of the net payout it just
    ///         promised. The inverse used to floor, which rounded AGAINST the
    ///         vault instead of in its favour: measured,
    ///         `previewRedeem(previewWithdraw(a)) == a - 1` for every `a`
    ///         above `bal` tried, i.e. `withdraw` paid one wei more than the
    ///         shares it burned were worth. See
    ///         test_PreviewWithdraw_RoundsInTheVaultsFavour.
    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        uint256 bal = IERC20(asset()).balanceOf(address(this));
        uint256 gross;
        if (assets <= bal) {
            gross = assets;
        } else {
            gross = Math.ceilDiv(assets * 10000 - bal * exitCostBps, 10000 - exitCostBps);
        }
        return _convertToShares(gross, Math.Rounding.Ceil);
    }

    /// @notice Shares this owner can redeem through the standard path right now.
    ///
    ///         Previously inherited, which returned `balanceOf(owner)` and
    ///         reported shares as redeemable while `redeem` reverted.
    ///
    ///         The bound is now the largest share amount whose `previewRedeem`
    ///         (NET of the exiting holder's own conversion cost) is at most
    ///         `_deliverableAssets()`. Because that cost is charged to the
    ///         exiter rather than the pool, the bound reaches the whole holding
    ///         at every position -- see docs/design/stock-vault-exit-paths.md,
    ///         "It also removes the capacity limit".
    function maxRedeem(address owner) public view override returns (uint256) {
        if (isCircuitBreakerActive) return 0;
        (uint256 deliverable, bool priced) = _deliverableAssets();
        if (!priced) return 0;
        uint256 held = balanceOf(owner);
        // Exact case first, and this is not an optimisation. Deriving the bound
        // by conversion alone loses wei to the virtual-share offset: measured
        // 501 wei below the supply, which refused a full exit on a vault
        // holding no cash at all.
        if (previewRedeem(held) <= deliverable) return held;
        // Otherwise invert previewRedeem's formula for the target net payout
        // `deliverable`, the same way previewWithdraw does, and convert THAT
        // gross figure to shares -- not `deliverable` itself, which is an
        // asset amount already net of the cash leg's own haircut and would
        // double-charge it if fed to _convertToShares directly.
        uint256 bal = IERC20(asset()).balanceOf(address(this));
        uint256 gross = deliverable <= bal
            ? deliverable
            : (deliverable * 10000 - bal * exitCostBps) / (10000 - exitCostBps);
        return _convertToShares(gross, Math.Rounding.Floor);
    }

    /// @dev The performance fee `_evaluateFees` would accrue if it ran right
    ///      now, without mutating any state. Mirrors that function's
    ///      computation exactly (the `fee` derivation and the room cap), so it
    ///      must be kept in sync by hand if `_evaluateFees` ever changes.
    ///
    ///      Skips `_reconcileFeeClaimWhenEmpty`, which only matters while
    ///      `totalSupply() == 0`; every holder's balance is 0 in that state too,
    ///      so `maxWithdraw` returns 0 regardless of what this helper answers.
    function _pendingPerformanceFee() internal view returns (uint256) {
        uint256 nav = getNavPerShare();
        if (nav <= highWaterMark) return 0;
        uint256 alpha = nav - highWaterMark;
        uint256 shareUnit = 10 ** decimals();
        uint256 fee = (alpha * totalSupply() * performanceFee) / (shareUnit * 10000);
        if (fee == 0) return 0;

        uint256 gross = grossValue();
        uint256 room = gross > performanceFeeAccrued + 1 ? gross - performanceFeeAccrued - 1 : 0;
        return fee > room ? room : fee;
    }

    /// @notice The maximum NET assets this owner can withdraw through the
    ///         standard path: `min(previewRedeem(balanceOf(owner)), deliverable)`.
    ///
    ///         Not literally that call, for a timing reason that predates the
    ///         conversion-cost fix and is unrelated to it: `withdraw` accrues
    ///         fees via `_evaluateFees()` BEFORE OpenZeppelin re-reads this
    ///         function to check the caller's request against it. That accrual
    ///         lowers `totalAssets()`, so a caller who read this view first and
    ///         then withdrew exactly that amount could have the floor drop out
    ///         from under them mid-call: measured, a pending 1000bps
    ///         performance fee made `withdraw(maxWithdraw(owner))` revert
    ///         `ERC4626ExceededMaxWithdraw` on a 0.74% gap.
    ///
    ///         `maxRedeem` needs no equivalent treatment: accrual only relaxes
    ///         both of its branches, so it never becomes stale in the direction
    ///         that matters. This function's asset-denominated bound moves the
    ///         other way, so it nets the pending fee here instead, computing
    ///         `gross` the way `previewRedeem` would once the fee has landed,
    ///         then applying the SAME net-of-conversion-cost formula to it
    ///         before taking the deliverable ceiling.
    function maxWithdraw(address owner) public view override returns (uint256) {
        if (isCircuitBreakerActive) return 0;
        (uint256 deliverable, bool priced) = _deliverableAssets();
        if (!priced) return 0;
        uint256 netAssets = totalAssets();
        uint256 pendingFee = _pendingPerformanceFee();
        netAssets = netAssets > pendingFee ? netAssets - pendingFee : 0;
        uint256 gross =
            Math.mulDiv(balanceOf(owner), netAssets + 1, totalSupply() + 10 ** _decimalsOffset(), Math.Rounding.Floor);
        uint256 bal = IERC20(asset()).balanceOf(address(this));
        uint256 net = gross <= bal ? gross : (gross * (10000 - exitCostBps) + bal * exitCostBps) / 10000;
        return net < deliverable ? net : deliverable;
    }

    /// @notice Refuse deposits when halted, when the share price is undefined,
    ///         or when the cash leg cannot be priced.
    ///
    ///         The last case used to REVERT rather than answer, because
    ///         `totalAssets()` reads the oracle and the oracle is built to
    ///         refuse. A caller could not find out whether the vault was open.
    ///         Returning zero says "closed right now", which is the truth and
    ///         is a thing an integrator can act on.
    function maxDeposit(address) public view override returns (uint256) {
        if (isCircuitBreakerActive) return 0;
        (, bool priced) = _cashLegValue();
        if (!priced) return 0;
        if (totalSupply() > 0 && totalAssets() == 0) return 0;
        return type(uint256).max;
    }

    function maxMint(address) public view override returns (uint256) {
        if (isCircuitBreakerActive) return 0;
        (, bool priced) = _cashLegValue();
        if (!priced) return 0;
        if (totalSupply() > 0 && totalAssets() == 0) return 0;
        return type(uint256).max;
    }

    /// @notice Rebalance the vault to hold `targetBps`/10000 of value in the underlying.
    function rebalanceTo(uint16 targetBps) external onlyRole(KEEPER_ROLE) nonReentrant {
        if (isCircuitBreakerActive) revert CircuitBreakerActive();
        if (targetBps > 10000) revert BadWeight();

        uint256 tvl = grossValue();
        if (tvl == 0) { targetWeightBps = targetBps; return; }

        uint256 desiredAsset = (tvl * targetBps) / 10000;
        uint256 curAsset = IERC20(asset()).balanceOf(address(this));

        uint256 diff = desiredAsset > curAsset ? desiredAsset - curAsset : curAsset - desiredAsset;
        if (diff * 10000 < uint256(rebalanceThresholdBps) * tvl) {
            targetWeightBps = targetBps;
            return;
        }

        if (desiredAsset > curAsset) {
            uint256 cashIn = assetToCash(desiredAsset - curAsset);
            uint256 cashBal = cashAsset.balanceOf(address(this));
            if (cashIn > cashBal) cashIn = cashBal;
            uint256 minOut = ((desiredAsset - curAsset) * (10000 - maxSlippageBps)) / 10000;
            _swap(address(cashAsset), asset(), cashIn, minOut);
        } else {
            uint256 assetIn = curAsset - desiredAsset;
            uint256 minOut = (assetToCash(assetIn) * (10000 - maxSlippageBps)) / 10000;
            _swap(asset(), address(cashAsset), assetIn, minOut);
        }

        rebalanceCount += 1;
        targetWeightBps = targetBps;
        uint256 nav = getNavPerShare();
        uint256 assetLeg = IERC20(asset()).balanceOf(address(this));
        uint256 cashLeg = cashAsset.balanceOf(address(this));

        bytes32 commit = ReceiptRenderer.commitment(
            msg.sender,
            address(this),
            targetBps,
            nav,
            assetLeg,
            cashLeg,
            rebalanceCount,
            block.timestamp,
            bytes32(0) // txHash filled in by the indexer off-chain; this is the canonical hash slot
        );

        emit Rebalanced(targetBps, assetLeg, cashLeg, nav, rebalanceCount, commit);
    }

    /// @dev The slippage bound is checked against the balance this vault
    ///      ACTUALLY gained, not against the number the adapter returned.
    ///
    ///      It used to be the return value:
    ///
    ///          uint256 out = swapAdapter.swap(...);
    ///          require(out >= minOut, "slippage");
    ///
    ///      which asks the counterparty to report on its own performance and
    ///      then believes the answer. An adapter that returns `minOut` while
    ///      transferring less passes that check, and the vault books a trade it
    ///      did not receive. `minOut` exists precisely to bound what this vault
    ///      is willing to lose on a swap, so verifying it against the swapper's
    ///      self-report is circular.
    ///
    ///      Not only reachable through a malicious adapter. A fee-on-transfer
    ///      tokenOut, or a router whose reported output is gross of a transfer
    ///      fee, produces the same gap with every party behaving honestly. The
    ///      adapter is set by DEFAULT_ADMIN, which is the timelock, so this is
    ///      defence in depth rather than a hole an attacker can reach today --
    ///      but the balance delta is the only figure that means anything here,
    ///      and it costs two SLOADs.
    ///
    ///      The allowance is also cleared. An adapter that consumes less than
    ///      `amountIn` would otherwise leave this vault standing approval to a
    ///      contract governance may later replace or find compromised.
    function _swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut) internal {
        if (amountIn == 0) return;
        require(address(swapAdapter) != address(0), "SpotVaultMinimal: adapter unset");

        uint256 before = IERC20(tokenOut).balanceOf(address(this));
        IERC20(tokenIn).forceApprove(address(swapAdapter), amountIn);

        // The return value is deliberately not the thing being checked; see above.
        // slither-disable-next-line unused-return
        swapAdapter.swap(tokenIn, tokenOut, amountIn, minOut);

        IERC20(tokenIn).forceApprove(address(swapAdapter), 0);
        uint256 received = IERC20(tokenOut).balanceOf(address(this)) - before;
        require(received >= minOut, "slippage");
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        // The conversion must FULLY cover the shortfall or revert. The old
        // version rounded the cash input down and accepted a fill up to
        // maxSlippageBps short, then transferred the full amount anyway, so the
        // tolerance that kept the swap from reverting was exactly what made the
        // transfer revert. Measured on mainnet: a 50% exit from a 50/50
        // position came up 9,181,117,677 wei short on a 0.0277 NVDA leg.
        //
        // Three changes. Round the cash input UP, so the dust case cannot ask
        // the venue for zero. Gross it up by the INVERSE of the haircut
        // `_deliverableAssets` applies to the cash leg -- 10000/(10000-h), not
        // (10000+h)/10000 -- so the venue's actual cut is paid out of the cash
        // leg rather than out of the depositor's delivery. The breakeven this
        // buys is exitCostBps itself: cover holds while the venue's REALISED
        // cost -- fee plus price impact -- is at most exitCostBps, and the
        // measured cliff sits exactly one basis point above that, at
        // exitCostBps + 1. The deployed value is 250. And
        // set minOut to the whole shortfall, so a fill that cannot cover fails
        // inside _swap's slippage check rather than at the transfer below --
        // true whenever there is a cash leg to attempt a swap with. When the
        // cash leg is zero, `cashIn` clamps to zero a few lines down and _swap
        // returns before checking minOut at all, so the failure would still be
        // ERC20InsufficientBalance at the transfer. That state is unreachable
        // through withdraw/redeem today: a zero cash leg makes
        // `_deliverableAssets` equal the asset leg exactly, so neither
        // entrypoint can advertise more than this contract's own asset balance
        // in the first place, and `bal < assets` above is never true.
        //
        // minOut is the guarantee, not the gross-up. _swap ends in
        // require(received >= minOut, "slippage"), so under-delivery is
        // impossible whatever the arithmetic above does; the gross-up only
        // makes the fill LIKELY to clear that bound. Note the revert is a plain
        // Error(string) and not a custom error, which is what an integrator
        // will actually see.
        uint256 bal = IERC20(asset()).balanceOf(address(this));
        if (bal < assets) {
            uint256 shortfall = assets - bal;
            uint256 cashIn = assetToCash(shortfall);
            if (cashToAsset(cashIn) < shortfall) cashIn += 1;
            cashIn = (cashIn * 10000) / (10000 - exitCostBps) + 1;
            uint256 cashBal = cashAsset.balanceOf(address(this));
            if (cashIn > cashBal) cashIn = cashBal;
            _swap(address(cashAsset), asset(), cashIn, shortfall);
        }
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    /// @notice Mark performance fees against the high-water mark.
    /// @dev Kept as a keeper entrypoint so fees can still be marked through a
    ///      long stretch with no deposits or withdrawals. It is no longer the
    ///      only path to accrual: see `_evaluateFees`.
    function evaluateFees() external onlyRole(KEEPER_ROLE) {
        _evaluateFees();
    }

    /// @dev Accrue the performance fee on any gain above the high-water mark.
    ///
    ///      This used to run only when a keeper called `evaluateFees`, which
    ///      left the protocol's revenue depending on off-chain punctuality: a
    ///      depositor could enter, wait for the position to appreciate, and
    ///      redeem before the next keeper call, taking the entire gain and
    ///      paying nothing.
    ///
    ///      It is now also called from the four ERC-4626 entrypoints, so anyone
    ///      moving value in or out first crystallises what has been earned.
    ///      Note those call sites are the PUBLIC functions, not the internal
    ///      `_deposit`/`_withdraw` hooks: ERC-4626 fixes the asset amount via
    ///      `previewRedeem` before those hooks run, so accruing inside them
    ///      lands after the number it is meant to affect has been computed.
    /// @dev Re-mark the high-water mark to the price the first depositor into an
    ///      empty vault actually paid.
    ///
    ///      The mark only ever ratchets upward, and `_evaluateFees` returns early
    ///      while supply is zero because the empty-vault NAV is a `10 ** _assetDec`
    ///      sentinel rather than a real price. Together those leave the mark
    ///      wherever the last depositor's high point was, so the next depositor
    ///      into an emptied vault pays no performance fee until they have climbed
    ///      back to a gain that was somebody else's. Proven in
    ///      `test_FeeAccrual_AfterEmptying_ChargesTheNextDepositor`, where the
    ///      mark stood at 2.0 while the incoming depositor had bought in at 0.9.
    ///
    ///      Reading `getNavPerShare()` is safe here and not in `_evaluateFees`:
    ///      supply is non-zero by the time this runs, so it returns a real price.
    function _markFirstEntry() internal {
        uint256 nav = getNavPerShare();
        if (nav != highWaterMark) {
            highWaterMark = nav;
            emit HighWaterMarkReset(nav);
        }
    }

    /// @dev Cap the outstanding fee claim at the value actually behind it, but
    ///      only while the vault is empty.
    ///
    ///      `performanceFeeAccrued` is a fixed number in asset units and
    ///      `grossValue()` is a live balance. Nothing binds them, so a price move
    ///      against the leg a fee was struck in can leave the claim larger than
    ///      the assets backing it. While shareholders exist that gap is at least
    ///      priced in: `totalAssets()` nets the claim, so anyone entering buys at
    ///      a NAV that already reflects it.
    ///
    ///      Once the vault empties, that stops being true. `getNavPerShare()`
    ///      falls back to a `10 ** _assetDec` sentinel that ignores the claim
    ///      entirely, so an incoming depositor pays a price decoupled from an
    ///      encumbrance their own principal then settles -- measured at 10% of
    ///      the deposit in `test_UnclaimedFee_DilutesTheNextDepositor`. The floor
    ///      in `totalAssets()` is where the information is lost, and no share
    ///      price can carry it because there are no shares.
    ///
    ///      So reconcile it here. There are no shareholders left to protect, and
    ///      a claim larger than the assets behind it is not a claim on the vault,
    ///      it is a lien on whoever deposits next.
    ///
    ///      This deliberately does NOT touch the non-empty case, where the same
    ///      divergence leaves holders bearing a loss the fee recipient is
    ///      insulated from. That is unfair but it is a dilution among parties who
    ///      were present when the fee was struck, and correcting it means
    ///      denominating the claim in shares -- a change to what the fee
    ///      recipient owns. See docs/FINDINGS-FEE-CLAIM-BACKING.md, option 3.
    function _reconcileFeeClaimWhenEmpty() internal {
        if (totalSupply() != 0) return;
        uint256 accrued = performanceFeeAccrued;
        uint256 backing = grossValue();
        if (accrued <= backing) return;
        performanceFeeAccrued = backing;
        emit AccruedFeesWrittenDown(accrued - backing, backing);
    }

    function _evaluateFees() internal {
        // Before the early return below, which fires on every empty vault.
        _reconcileFeeClaimWhenEmpty();
        uint256 nav = getNavPerShare();
        if (nav <= highWaterMark) return;
        uint256 alpha = nav - highWaterMark;
        uint256 shareUnit = 10 ** decimals();
        uint256 fee = (alpha * totalSupply() * performanceFee) / (shareUnit * 10000);

        if (fee > 0) {
            uint256 gross = grossValue();
            uint256 room = gross > performanceFeeAccrued + 1 ? gross - performanceFeeAccrued - 1 : 0;
            if (fee > room) fee = room;
        }

        if (fee > 0) {
            performanceFeeAccrued += fee;
            emit PerformanceFeeAccrued(fee, highWaterMark, nav);
        }
        highWaterMark = nav;
    }

    function claimFees() external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant returns (uint256 paid) {
        uint256 accrued = performanceFeeAccrued;
        require(accrued > 0, "SpotVaultMinimal: nothing accrued");
        uint256 bal = IERC20(asset()).balanceOf(address(this));
        paid = accrued <= bal ? accrued : bal;
        require(paid > 0, "SpotVaultMinimal: no underlying liquidity");
        performanceFeeAccrued = accrued - paid;
        IERC20(asset()).safeTransfer(feeRecipient, paid);
        emit PerformanceFeeClaimed(feeRecipient, paid, performanceFeeAccrued);
    }

    /// @notice Forgive part of the outstanding performance-fee claim.
    /// @dev This is the only lever that can reconcile a claim which has outgrown
    ///      the value backing it -- see docs/FINDINGS-FEE-CLAIM-BACKING.md. It
    ///      previously emitted nothing, so an admin could reduce the protocol's
    ///      claim to zero leaving no trace an indexer or a depositor could
    ///      follow. The write-down is legitimate; its invisibility was not.
    function writeDownAccruedFees(uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 accrued = performanceFeeAccrued;
        require(amount > 0 && amount <= accrued, "SpotVaultMinimal: bad write-down");
        uint256 remaining = accrued - amount;
        performanceFeeAccrued = remaining;
        emit AccruedFeesWrittenDown(amount, remaining);
    }

    function setSwapAdapter(address adapter_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(adapter_ != address(0), "zero adapter");
        swapAdapter = ISpotSwapAdapter(adapter_);
    }

    event FeeRecipientChanged(address indexed oldRecipient, address indexed newRecipient);

    function setFeeRecipient(address newRecipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newRecipient != address(0), "SpotVaultMinimal: zero fee recipient");
        emit FeeRecipientChanged(feeRecipient, newRecipient);
        feeRecipient = newRecipient;
    }

    function setCircuitBreaker(bool active) external onlyRole(RISK_COUNCIL_ROLE) {
        isCircuitBreakerActive = active;
        emit CircuitBreakerSet(active);
    }

    /// @return paid     the asset leg transferred to `receiver`
    /// @return paidCash  the cash leg transferred to `receiver`, in kind
    function redeemEmergency(uint256 shares, address receiver, address owner)
        external
        nonReentrant
        returns (uint256 paid, uint256 paidCash)
    {
        // Deliberately NOT gated on isCircuitBreakerActive. This is the only
        // path that reads no oracle and calls no venue, and it pays both legs
        // exactly pro-rata, so it is the one thing a breaker should preserve
        // rather than remove. The per-owner cooldown below still applies.
        require(shares > 0, "SpotVaultMinimal: zero shares");
        require(receiver != address(0) && owner != address(0), "SpotVaultMinimal: zero addr");

        uint256 cooldown = emergencyRedeemCooldown;
        uint256 lastTs = lastEmergencyRedeemAt[owner];
        if (lastTs != 0 && cooldown != 0) {
            uint256 nextAllowed = lastTs + cooldown;
            if (block.timestamp < nextAllowed) revert EmergencyCooldownActive(nextAllowed);
        }
        lastEmergencyRedeemAt[owner] = block.timestamp;

        if (owner != msg.sender) {
            _spendAllowance(owner, msg.sender, shares);
        }

        uint256 supply = totalSupply();
        require(supply > 0, "SpotVaultMinimal: empty vault");
        uint256 bal = IERC20(asset()).balanceOf(address(this));
        uint256 cashBal = cashAsset.balanceOf(address(this));

        uint256 grossOwed = (shares * bal) / supply;
        uint256 feeShare = (shares * performanceFeeAccrued) / supply;
        uint256 owed = grossOwed > feeShare ? grossOwed - feeShare : 0;

        // The cash leg is paid IN KIND: a pro-rata slice of the balance, with no
        // oracle read and no venue call, which is what keeps this function usable
        // in exactly the conditions it exists for.
        //
        // It used to pay the asset leg only and silently forfeit this. That
        // stranded the cash permanently -- there is no sweep or rescue on this
        // contract -- while `totalAssets()` went on counting it, so it also
        // mispriced the next depositor's entry. A depositor reading the receipt
        // saw `haircut: 0` on a total forfeiture of half their position. See
        // docs/FINDINGS-EMERGENCY-EXIT.md; this is option 3.
        //
        // The cost is that the depositor receives two tokens instead of one. That
        // is a UX cost, not a safety one, and it is strictly preferable to
        // confiscation.
        uint256 cashOwed = (shares * cashBal) / supply;

        _burn(owner, shares);
        uint256 accrued = performanceFeeAccrued;
        if (feeShare > accrued) feeShare = accrued;
        performanceFeeAccrued = accrued - feeShare;
        paid = owed;
        if (paid > 0) IERC20(asset()).safeTransfer(receiver, paid);
        if (cashOwed > 0) cashAsset.safeTransfer(receiver, cashOwed);

        uint256 haircut = grossOwed > paid ? grossOwed - paid : 0;
        emit EmergencyRedeem(msg.sender, receiver, owner, shares, paid, cashOwed, haircut);
        return (paid, cashOwed);
    }

    function setEmergencyRedeemCooldown(uint256 cooldown) external onlyRole(RISK_COUNCIL_ROLE) {
        emergencyRedeemCooldown = cooldown;
    }
}

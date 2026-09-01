// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ISpotSwapAdapter} from "../adapters/RobinhoodChainRouterAdapter.sol";
import {AggregatorV3Interface} from "../oracle/MedianOracle.sol";
import {ReceiptRenderer} from "../lib/ReceiptRenderer.sol";

/// @title SpotVaultMinimal
/// @notice Zorpha V1 long/flat spot vault. ERC-4626, denominated in the
///         underlying. The strategy is long/flat spot: hold the underlying
///         (LONG) or the cash asset (USDC, FLAT). NAV is measured in
///         underlying units, valuing the cash leg via a Chainlink-compatible
///         oracle. Every successful rebalance emits a `Rebalanced` event that
///         the Supabase indexer copies into the public receipts feed — the
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
    event PerformanceFeeClaimed(address indexed recipient, uint256 paid, uint256 stillAccrued);
    event CircuitBreakerSet(bool active);
    event EmergencyRedeem(
        address indexed caller,
        address indexed receiver,
        address indexed owner,
        uint256 sharesBurned,
        uint256 paid,
        uint256 haircutAssets
    );

    error CircuitBreakerActive();
    error BadWeight();
    error StaleOracle(uint256 updatedAt, uint256 nowTs);
    error InvalidOraclePrice(int256 answer);
    error EmergencyBreakerActive();
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
        uint256 performanceFeeBps_,
        address feeRecipient_,
        address admin_,
        uint256 emergencyRedeemCooldown_
    ) ERC20(name_, symbol_) ERC4626(IERC20(asset_)) {
        require(asset_ != address(0) && cashAsset_ != address(0) && oracle_ != address(0), "zero addr");
        require(feeRecipient_ != address(0) && admin_ != address(0), "zero addr");
        require(rebalanceThresholdBps_ <= 10000 && maxSlippageBps_ <= 10000 && performanceFeeBps_ <= 10000, "bad bps");
        require(maxOracleStaleness_ > 0, "zero staleness");

        cashAsset = IERC20(cashAsset_);
        oracle = AggregatorV3Interface(oracle_);
        maxOracleStaleness = maxOracleStaleness_;
        _assetDec = IERC20Metadata(asset_).decimals();
        _cashDec = IERC20Metadata(cashAsset_).decimals();
        _priceDec = AggregatorV3Interface(oracle_).decimals();

        rebalanceThresholdBps = rebalanceThresholdBps_;
        maxSlippageBps = maxSlippageBps_;
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

    function _oraclePrice() internal view returns (uint256) {
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

    /// @notice Refuse deposits when halted or when share price is undefined.
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

    function _swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut) internal {
        if (amountIn == 0) return;
        require(address(swapAdapter) != address(0), "SpotVaultMinimal: adapter unset");
        IERC20(tokenIn).forceApprove(address(swapAdapter), amountIn);
        uint256 out = swapAdapter.swap(tokenIn, tokenOut, amountIn, minOut);
        require(out >= minOut, "slippage");
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        uint256 bal = IERC20(asset()).balanceOf(address(this));
        if (bal < assets) {
            uint256 shortfall = assets - bal;
            uint256 cashIn = assetToCash(shortfall);
            uint256 cashBal = cashAsset.balanceOf(address(this));
            if (cashIn > cashBal) cashIn = cashBal;
            uint256 minOut = (shortfall * (10000 - maxSlippageBps)) / 10000;
            _swap(address(cashAsset), asset(), cashIn, minOut);
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
    function _evaluateFees() internal {
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

    function writeDownAccruedFees(uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 accrued = performanceFeeAccrued;
        require(amount > 0 && amount <= accrued, "SpotVaultMinimal: bad write-down");
        performanceFeeAccrued = accrued - amount;
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

    function redeemEmergency(uint256 shares, address receiver, address owner)
        external
        nonReentrant
        returns (uint256 paid)
    {
        if (isCircuitBreakerActive) revert EmergencyBreakerActive();
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

        uint256 grossOwed = (shares * bal) / supply;
        uint256 feeShare = (shares * performanceFeeAccrued) / supply;
        uint256 owed = grossOwed > feeShare ? grossOwed - feeShare : 0;

        _burn(owner, shares);
        uint256 accrued = performanceFeeAccrued;
        if (feeShare > accrued) feeShare = accrued;
        performanceFeeAccrued = accrued - feeShare;
        paid = owed;
        if (paid > 0) IERC20(asset()).safeTransfer(receiver, paid);

        uint256 haircut = grossOwed > paid ? grossOwed - paid : 0;
        emit EmergencyRedeem(msg.sender, receiver, owner, shares, paid, haircut);
    }

    function setEmergencyRedeemCooldown(uint256 cooldown) external onlyRole(RISK_COUNCIL_ROLE) {
        emergencyRedeemCooldown = cooldown;
    }
}

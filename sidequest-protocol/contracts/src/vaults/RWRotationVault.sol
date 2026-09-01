// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {AggregatorV3Interface} from "../oracle/MedianOracle.sol";
import {ReceiptRenderer} from "../lib/ReceiptRenderer.sol";

/// @title RWRotationVault
/// @notice Zorpha V1 RWA rotation vault. Holds a basket of N Robinhood Stock
///         Tokens (e.g. HOOD, NVDA, AAPL) rotated by signed rebalance commands.
///         NAV is measured in a designated `baseAsset` (e.g. USDC), valuing
///         each token leg via its own Chainlink-compatible oracle.
///
///         The signed rebalance target is a uint16 array of weights in bps
///         (sum must equal 10000). A rebalance walks the diff between the
///         current and target weights and emits a `Rebalanced` event with
///         the full target distribution — the manager's rotation choice is
///         the receipt.
contract RWRotationVault is ERC4626, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant RISK_COUNCIL_ROLE = keccak256("RISK_COUNCIL_ROLE");

    /// @notice The cash / base asset in which NAV is measured (e.g. USDC).
    IERC20 public immutable baseAsset;
    uint8  public immutable baseDecimals;

    /// @notice The token basket. tokens[0] is also the underlying for ERC-4626
    ///         semantics — depositors deposit `tokens[0]` and receive shares.
    IERC20[] public tokens;

    /// @notice One oracle per token. oracles[i] prices `tokens[i]` in 1e8 USD.
    AggregatorV3Interface[] public oracles;
    uint8[] public oracleDecimals;

    uint256 public immutable maxOracleStaleness;

    uint16[] public targetWeightsBps;
    uint256 public rebalanceCount;
    uint256 public performanceFee;
    uint256 public highWaterMark;
    uint256 public performanceFeeAccrued;
    address public feeRecipient;
    bool    public isCircuitBreakerActive;

    event Rebalanced(
        uint16[] targetBps,
        uint256 navInBase,
        uint256[] tokenLegs,
        uint256 baseLeg,
        uint256 nonce,
        bytes32 commitment
    );
    event CircuitBreakerSet(bool active);
    event PerformanceFeeAccrued(uint256 fee, uint256 navBefore, uint256 navAfter);
    event PerformanceFeeClaimed(address indexed recipient, uint256 paid, uint256 stillAccrued);
    event FeeRecipientChanged(address indexed oldRecipient, address indexed newRecipient);

    error CircuitBreakerActive();
    error BadWeights();
    error StaleOracle(uint256 updatedAt, uint256 nowTs);
    error InvalidOraclePrice(int256 answer);

    constructor(
        address baseAsset_,
        address[] memory tokens_,
        address[] memory oracles_,
        uint256 maxOracleStaleness_,
        uint16[] memory initialWeightsBps_,
        string memory name_,
        string memory symbol_,
        uint256 performanceFeeBps_,
        address feeRecipient_,
        address admin_
    ) ERC20(name_, symbol_) ERC4626(IERC20(tokens_[0])) {
        require(baseAsset_ != address(0), "zero base");
        require(tokens_.length >= 2 && tokens_.length <= 5, "basket size 2..5");
        require(tokens_.length == oracles_.length, "tokens/oracles length mismatch");
        require(tokens_.length == initialWeightsBps_.length, "tokens/weights length mismatch");
        require(performanceFeeBps_ <= 10000, "bad fee bps");
        require(feeRecipient_ != address(0) && admin_ != address(0), "zero addr");
        require(maxOracleStaleness_ > 0, "zero staleness");

        uint16 weightSum;
        for (uint256 i = 0; i < initialWeightsBps_.length; i++) {
            weightSum += initialWeightsBps_[i];
        }
        require(weightSum == 10000, "weights must sum to 10000");

        baseAsset = IERC20(baseAsset_);
        baseDecimals = IERC20Metadata(baseAsset_).decimals();

        for (uint256 i = 0; i < tokens_.length; i++) {
            require(tokens_[i] != address(0) && oracles_[i] != address(0), "zero addr");
            tokens.push(IERC20(tokens_[i]));
            oracles.push(AggregatorV3Interface(oracles_[i]));
            oracleDecimals.push(AggregatorV3Interface(oracles_[i]).decimals());
        }

        maxOracleStaleness = maxOracleStaleness_;
        for (uint256 i = 0; i < initialWeightsBps_.length; i++) {
            targetWeightsBps.push(initialWeightsBps_[i]);
        }
        performanceFee = performanceFeeBps_;
        feeRecipient = feeRecipient_;
        highWaterMark = 10 ** baseDecimals;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    }

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

    function _readPrice(uint256 i) internal view returns (uint256) {
        AggregatorV3Interface o = oracles[i];
        (uint80 roundId, int256 answer, , uint256 updatedAt, uint80 answeredInRound) =
            o.latestRoundData();
        if (answer <= 0) revert InvalidOraclePrice(answer);
        if (answeredInRound < roundId) revert StaleOracle(updatedAt, block.timestamp);
        if (updatedAt == 0 || block.timestamp - updatedAt > maxOracleStaleness) {
            revert StaleOracle(updatedAt, block.timestamp);
        }
        return uint256(answer);
    }

    /// @notice Convert `amount` of `tokens[i]` to baseAsset units using the oracle.
    function tokenToBase(uint256 i, uint256 amount) public view returns (uint256) {
        if (amount == 0) return 0;
        uint256 p = _readPrice(i);
        uint8 tDec = IERC20Metadata(address(tokens[i])).decimals();
        uint8 pDec = oracleDecimals[i];
        return (amount * (10 ** baseDecimals) * p) / ((10 ** tDec) * (10 ** pDec));
    }

    function baseToToken(uint256 i, uint256 baseAmt) public view returns (uint256) {
        if (baseAmt == 0) return 0;
        uint256 p = _readPrice(i);
        uint8 tDec = IERC20Metadata(address(tokens[i])).decimals();
        uint8 pDec = oracleDecimals[i];
        return (baseAmt * (10 ** tDec) * (10 ** pDec)) / ((10 ** baseDecimals) * p);
    }

    /// @notice Total vault value in baseAsset units (sum of all token legs + base leg).
    function grossValue() public view returns (uint256) {
        uint256 v = baseAsset.balanceOf(address(this));
        for (uint256 i = 0; i < tokens.length; i++) {
            v += tokenToBase(i, tokens[i].balanceOf(address(this)));
        }
        return v;
    }

    function totalAssets() public view override returns (uint256) {
        uint256 gross = grossValue();
        return gross > performanceFeeAccrued ? gross - performanceFeeAccrued : 0;
    }

    function getNavPerShare() public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 10 ** baseDecimals;
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

    /// @notice Set a new target weight distribution. The signed rebalance target
    ///         is the array itself — each receipt carries the manager's chosen
    ///         allocation across the basket.
    /// @dev    V1 does NOT actually execute swaps between token legs (no live
    ///         DEX for stock tokens yet). The receipt records the intended
    ///         allocation. V2 adds the swap leg.
    function rebalanceTo(uint16[] calldata newWeightsBps) external onlyRole(KEEPER_ROLE) nonReentrant {
        if (isCircuitBreakerActive) revert CircuitBreakerActive();
        require(newWeightsBps.length == tokens.length, "RWRotationVault: length mismatch");
        uint16 sum;
        for (uint256 i = 0; i < newWeightsBps.length; i++) {
            sum += newWeightsBps[i];
        }
        if (sum != 10000) revert BadWeights();

        // Replace stored target weights
        delete targetWeightsBps;
        for (uint256 i = 0; i < newWeightsBps.length; i++) {
            targetWeightsBps.push(newWeightsBps[i]);
        }

        rebalanceCount += 1;
        uint256 nav = getNavPerShare();
        uint256 baseLeg = baseAsset.balanceOf(address(this));
        uint256[] memory tokenLegs = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            tokenLegs[i] = tokens[i].balanceOf(address(this));
        }

        // Binds the basket weights and every token leg, so the emitted receipt
        // can actually be reproduced and checked off-chain.
        bytes32 commit = ReceiptRenderer.basketCommitment(
            msg.sender,
            address(this),
            newWeightsBps,
            nav,
            tokenLegs,
            baseLeg,
            rebalanceCount,
            block.timestamp,
            bytes32(0)
        );

        emit Rebalanced(newWeightsBps, nav, tokenLegs, baseLeg, rebalanceCount, commit);
    }

    function setCircuitBreaker(bool active) external onlyRole(RISK_COUNCIL_ROLE) {
        isCircuitBreakerActive = active;
        emit CircuitBreakerSet(active);
    }

    // ─── Performance fee ────────────────────────────────────────────────────
    //
    // This vault stored `performanceFee`, `highWaterMark` and
    // `performanceFeeAccrued`, and the deploy script configured a 20% fee — but
    // nothing ever wrote to the accrual. Slither flagged
    // `performanceFeeAccrued` as assignable-to-constant, which is how a
    // never-charged fee looks from the outside. The protocol therefore earned
    // zero revenue from this vault while the site advertised 20%, so the fee is
    // implemented here rather than the claim being quietly dropped.

    /// @notice Accrue performance fee on new high-water-mark NAV.
    ///         Charged only on gains above the previous high, so a recovery back
    ///         to a prior level is not billed twice.
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
            // Never accrue more than the vault actually holds, leaving a wei of
            // headroom so `totalAssets()` cannot be driven to exactly zero
            // while shares are outstanding.
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

    /// @notice Pay accrued fees to the fee recipient, in the base asset.
    function claimFees()
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
        returns (uint256 paid)
    {
        uint256 accrued = performanceFeeAccrued;
        require(accrued > 0, "RWRotationVault: nothing accrued");

        uint256 bal = baseAsset.balanceOf(address(this));
        paid = accrued <= bal ? accrued : bal;
        require(paid > 0, "RWRotationVault: no base liquidity");

        performanceFeeAccrued = accrued - paid;
        baseAsset.safeTransfer(feeRecipient, paid);

        emit PerformanceFeeClaimed(feeRecipient, paid, performanceFeeAccrued);
    }

    function setFeeRecipient(address newRecipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newRecipient != address(0), "RWRotationVault: zero fee recipient");
        emit FeeRecipientChanged(feeRecipient, newRecipient);
        feeRecipient = newRecipient;
    }

    function basketLength() external view returns (uint256) {
        return tokens.length;
    }
}

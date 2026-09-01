// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IRawAssets {
    /// @notice Vault assets EXCLUDING any support from this escrow.
    function rawAssets() external view returns (uint256);
}

/// @title FirstLossEscrow
/// @notice The vault leader's capital, subordinated to depositors'.
///
///         This is the one thing here that nobody else in onchain vaults does.
///         Hyperliquid requires a vault leader to hold 5% of TVL, which took
///         its user vaults to roughly $80M against dHEDGE's $12M with no such
///         requirement. But that stake is *pari passu*: the leader loses
///         proportionally, alongside everyone else.
///
///         This escrow is subordinated. The leader's capital absorbs losses
///         FIRST, and depositors are not touched until it is gone. In one
///         sentence: the manager loses first.
///
///         Two properties make that claim mean something rather than being
///         marketing.
///
///         It is continuously checkable. `coverageRatioBps()` is a public view
///         over real balances, not an assertion in a document.
///
///         It is self-healing. Performance fees route through here, and while
///         coverage sits below the minimum the leader's share of those fees is
///         retained to rebuild the buffer instead of being paid out. A leader
///         who has taken a drawdown works to restore the protection before
///         they earn again.
///
///         Loss absorption is deliberately PRO RATA rather than
///         first-come-first-served. The vault counts `available()` toward its
///         NAV, so every share already carries its slice of the buffer and a
///         redeeming holder draws only that slice. A buffer paid out to
///         whoever exits first would be a run incentive wearing a safety
///         jacket.
contract FirstLossEscrow is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Asset the vault is denominated in. The escrow is held in the
    ///         SAME asset, never in the protocol token.
    /// @dev That is not a stylistic choice. A buffer denominated in a token
    ///      whose price is correlated with the protocol's fortunes evaporates
    ///      exactly when it is needed, which is a death spiral rather than a
    ///      design.
    IERC20 public immutable asset;

    /// @notice The vault this escrow backs.
    address public immutable vault;

    /// @notice Where the leader's share of fees is paid.
    address public immutable leader;

    /// @notice Where the protocol's share of fees is paid.
    address public immutable protocolTreasury;

    /// @notice Leader's share of performance fees, in bps of the fee.
    uint16 public immutable leaderFeeShareBps;

    /// @notice Minimum escrow as bps of vault raw assets, e.g. 500 = 5%.
    uint16 public immutable minCoverageBps;

    /// @notice Delay between requesting and taking a withdrawal.
    /// @dev Long enough that a leader cannot see a loss coming and exit the
    ///      buffer ahead of it. Anything shorter makes the protection optional
    ///      at exactly the moment it matters.
    uint256 public constant WITHDRAWAL_DELAY = 7 days;

    uint256 public escrow;
    uint256 public totalAbsorbed;
    uint256 public totalFeesRetained;

    uint256 public pendingWithdrawal;
    uint256 public withdrawalReadyAt;

    error NotVault();
    error NotLeader();
    error ZeroAddress();
    error BadParams();
    error NothingPending();
    error TooEarly(uint256 readyAt);
    error WouldBreachMinimum(uint256 coverageAfterBps, uint256 minimumBps);

    event Funded(address indexed from, uint256 amount, uint256 escrowAfter);
    event Absorbed(uint256 requested, uint256 paid, uint256 escrowAfter);
    event FeesSplit(uint256 total, uint256 toLeader, uint256 toProtocol, uint256 retained);
    event WithdrawalRequested(uint256 amount, uint256 readyAt);
    event WithdrawalExecuted(uint256 amount, uint256 escrowAfter);
    event WithdrawalCancelled(uint256 amount);

    modifier onlyVault() {
        if (msg.sender != vault) revert NotVault();
        _;
    }

    modifier onlyLeader() {
        if (msg.sender != leader) revert NotLeader();
        _;
    }

    constructor(
        address asset_,
        address vault_,
        address leader_,
        address protocolTreasury_,
        uint16 leaderFeeShareBps_,
        uint16 minCoverageBps_
    ) {
        if (
            asset_ == address(0) || vault_ == address(0) || leader_ == address(0)
                || protocolTreasury_ == address(0)
        ) revert ZeroAddress();
        // A leader fee share of 100% would leave the protocol with no revenue
        // and therefore no buyback. A minimum coverage of 100% would mean the
        // leader funds the entire vault themselves.
        if (leaderFeeShareBps_ > 10_000 || minCoverageBps_ > 10_000) revert BadParams();

        asset = IERC20(asset_);
        vault = vault_;
        leader = leader_;
        protocolTreasury = protocolTreasury_;
        leaderFeeShareBps = leaderFeeShareBps_;
        minCoverageBps = minCoverageBps_;
    }

    // ─── Funding ─────────────────────────────────────────────────────────────

    /// @notice Add first-loss capital. Permissionless: anyone may strengthen a
    ///         vault's buffer, though in practice it is the leader.
    function fund(uint256 amount) external nonReentrant {
        if (amount == 0) return;
        asset.safeTransferFrom(msg.sender, address(this), amount);
        escrow += amount;
        emit Funded(msg.sender, amount, escrow);
    }

    // ─── Loss absorption ─────────────────────────────────────────────────────

    /// @notice What the vault may currently count toward its NAV, and draw on.
    function available() public view returns (uint256) {
        // A pending withdrawal is NOT subtracted. Until it is actually taken
        // the capital is still present and still absorbing: a leader must not
        // be able to switch off the protection by merely announcing an exit.
        return escrow;
    }

    /// @notice Pay `amount` of underlying to the vault to cover a shortfall.
    /// @return paid What was actually available and sent, which may be less.
    function absorb(uint256 amount) external onlyVault nonReentrant returns (uint256 paid) {
        paid = amount < escrow ? amount : escrow;
        if (paid == 0) return 0;

        escrow -= paid;
        totalAbsorbed += paid;
        asset.safeTransfer(vault, paid);

        emit Absorbed(amount, paid, escrow);
    }

    // ─── Fees ────────────────────────────────────────────────────────────────

    /// @notice Split a performance fee between leader and protocol, rebuilding
    ///         the buffer first if it is short.
    /// @dev Pulls from `msg.sender`, who must have approved this contract. The
    ///      vault calls this when it claims fees.
    function splitFees(uint256 amount) external nonReentrant {
        if (amount == 0) return;
        asset.safeTransferFrom(msg.sender, address(this), amount);

        // Split the WHOLE fee first, then take retention out of the leader's
        // half alone.
        //
        // Doing it the other way round — retaining, then splitting whatever
        // survived — silently charges the protocol for the leader's drawdown.
        // At an 80/20 split with an undercovered leader it paid the treasury
        // 20% of the remainder instead of 20% of the fee, which on a measured
        // case was $40 where $200 was owed. Half of the protocol's cut funds
        // the buyback, so that shortfall came straight out of the burn.
        uint256 leaderShare = (amount * leaderFeeShareBps) / 10_000;
        uint256 toProtocol = amount - leaderShare;

        uint256 shortfall = coverageShortfall();
        uint256 retained;
        if (shortfall > 0) {
            retained = shortfall < leaderShare ? shortfall : leaderShare;
            escrow += retained;
        }

        uint256 toLeader = leaderShare - retained;

        if (toLeader > 0) asset.safeTransfer(leader, toLeader);
        if (toProtocol > 0) asset.safeTransfer(protocolTreasury, toProtocol);

        emit FeesSplit(amount, toLeader, toProtocol, retained);
        if (retained > 0) totalFeesRetained += retained;
    }

    // ─── Coverage ────────────────────────────────────────────────────────────

    /// @notice Escrow as bps of the vault's raw assets.
    /// @dev Measured against `rawAssets()`, which excludes this escrow's own
    ///      support. Measuring against `totalAssets()` would be circular: the
    ///      buffer would inflate the denominator it is being compared to and
    ///      report better coverage than exists.
    function coverageRatioBps() public view returns (uint256) {
        uint256 raw = IRawAssets(vault).rawAssets();
        if (raw == 0) return type(uint256).max; // nothing at risk
        return (escrow * 10_000) / raw;
    }

    function requiredEscrow() public view returns (uint256) {
        uint256 raw = IRawAssets(vault).rawAssets();
        return (raw * minCoverageBps) / 10_000;
    }

    function coverageShortfall() public view returns (uint256) {
        uint256 required = requiredEscrow();
        return escrow >= required ? 0 : required - escrow;
    }

    function isAdequatelyCovered() external view returns (bool) {
        return coverageShortfall() == 0;
    }

    // ─── Leader withdrawal ───────────────────────────────────────────────────

    /// @notice Begin withdrawing first-loss capital. Takes effect after the
    ///         delay, and only if coverage still clears the minimum then.
    function requestWithdrawal(uint256 amount) external onlyLeader {
        if (amount == 0 || amount > escrow) revert BadParams();
        pendingWithdrawal = amount;
        withdrawalReadyAt = block.timestamp + WITHDRAWAL_DELAY;
        emit WithdrawalRequested(amount, withdrawalReadyAt);
    }

    function cancelWithdrawal() external onlyLeader {
        uint256 amount = pendingWithdrawal;
        if (amount == 0) revert NothingPending();
        pendingWithdrawal = 0;
        withdrawalReadyAt = 0;
        emit WithdrawalCancelled(amount);
    }

    /// @notice Take a matured withdrawal.
    /// @dev Coverage is re-checked HERE, not at request time. The vault may
    ///      have grown, or the buffer may have absorbed a loss, in the days
    ///      since. Checking only at request would let a leader queue an exit
    ///      while well covered and take it while not.
    function executeWithdrawal() external onlyLeader nonReentrant {
        uint256 amount = pendingWithdrawal;
        if (amount == 0) revert NothingPending();
        if (block.timestamp < withdrawalReadyAt) revert TooEarly(withdrawalReadyAt);
        if (amount > escrow) amount = escrow;

        uint256 remaining = escrow - amount;
        uint256 raw = IRawAssets(vault).rawAssets();
        if (raw > 0) {
            uint256 after_ = (remaining * 10_000) / raw;
            if (after_ < minCoverageBps) revert WouldBreachMinimum(after_, minCoverageBps);
        }

        pendingWithdrawal = 0;
        withdrawalReadyAt = 0;
        escrow = remaining;
        asset.safeTransfer(leader, amount);

        emit WithdrawalExecuted(amount, remaining);
    }
}

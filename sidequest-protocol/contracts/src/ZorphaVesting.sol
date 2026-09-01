// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title ZorphaVesting
/// @notice Linear vesting with a cliff for $ZOR contributor and backer
///         allocations. Tokens are pre-deposited at funding time, so a claim
///         can never fail for lack of funds.
///
///         Schedule semantics (these are the conventional ones, and they are
///         what the published allocation table means):
///           - `vestDuration` is the TOTAL vesting period measured from
///             `startTime`. It is NOT additive with the cliff.
///           - Nothing is claimable before `startTime + cliffDuration`.
///           - At the cliff, the amount accrued over the elapsed period
///             unlocks at once; thereafter it accrues linearly per second
///             until `startTime + vestDuration`.
///
///         So "12-month cliff, 48-month vest" releases 25% at month 12 and the
///         remaining 75% linearly across months 12-48. A previous revision
///         treated `vestDuration` as additive with the cliff, which silently
///         stretched every schedule and changed the cliff release fraction.
///
///         Voting weight: $ZOR is an ERC20Votes token and this contract never
///         delegates. Unvested tokens therefore carry ZERO voting weight, by
///         construction, so contributors cannot vote with tokens they have not
///         yet earned. There is deliberately no delegate() escape hatch.
contract ZorphaVesting {
    using SafeCast for uint256;
    using SafeERC20 for IERC20;

    event ScheduleCreated(
        address indexed beneficiary,
        uint256 totalAmount,
        uint64 startTime,
        uint64 cliffDuration,
        uint64 vestDuration,
        bool revocable
    );
    event Claimed(address indexed beneficiary, uint256 amount);
    event Revoked(address indexed beneficiary, uint256 vestedKept, uint256 unvestedReturned);
    event Funded(address indexed from, uint256 amount);

    struct VestingSchedule {
        uint128 totalAmount;
        uint128 claimed;
        uint64 startTime;
        uint64 cliffDuration;
        uint64 vestDuration;
        bool revocable;
        bool revoked;
    }

    /// @notice The $ZOR token.
    IERC20 public immutable zor;

    /// @notice Admin able to create and revoke schedules. Intended to be the
    ///         protocol Safe / Timelock, never a hot EOA.
    address public immutable admin;

    /// @notice Longest backdating allowed for `startTime`, so a schedule cannot
    ///         be created already fully vested.
    uint64 public constant MAX_BACKDATE = 90 days;

    mapping(address => VestingSchedule) public schedules;
    address[] public beneficiaries;

    error NotAdmin();
    error LengthMismatch();
    error ZeroAddressInput();
    error ZeroAmount();
    error ZeroDuration();
    error CliffExceedsVest();
    error ScheduleExists(address beneficiary);
    error StartTimeTooEarly();
    error NothingToClaim();
    error NotRevocable();
    error AlreadyRevoked();

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    constructor(address zor_, address admin_) {
        if (zor_ == address(0) || admin_ == address(0)) revert ZeroAddressInput();
        zor = IERC20(zor_);
        admin = admin_;
    }

    /// @notice Create schedules for a batch of beneficiaries and pull the total
    ///         from the caller in the same transaction.
    function fund(
        address[] calldata scheduleBeneficiaries,
        uint256[] calldata scheduleAmounts,
        uint64[] calldata scheduleCliffs,
        uint64[] calldata scheduleVestDurations,
        bool[] calldata scheduleRevocables,
        uint64 startTime_
    ) external onlyAdmin {
        uint256 n = scheduleBeneficiaries.length;
        if (
            n != scheduleAmounts.length || n != scheduleCliffs.length
                || n != scheduleVestDurations.length || n != scheduleRevocables.length
        ) revert LengthMismatch();

        if (uint256(startTime_) + MAX_BACKDATE < block.timestamp) revert StartTimeTooEarly();

        uint256 totalToFund;
        for (uint256 i = 0; i < n; i++) {
            address b = scheduleBeneficiaries[i];
            if (b == address(0)) revert ZeroAddressInput();
            if (scheduleAmounts[i] == 0) revert ZeroAmount();
            if (scheduleVestDurations[i] == 0) revert ZeroDuration();
            if (scheduleCliffs[i] > scheduleVestDurations[i]) revert CliffExceedsVest();

            // Writing the schedule inside this single pass makes the mapping
            // itself the duplicate check, covering both pre-existing schedules
            // and repeats within this batch. The previous revision used a
            // nested loop for the in-batch case, which was O(n^2) gas.
            if (schedules[b].totalAmount != 0) revert ScheduleExists(b);

            schedules[b] = VestingSchedule({
                totalAmount: scheduleAmounts[i].toUint128(),
                claimed: 0,
                startTime: startTime_,
                cliffDuration: scheduleCliffs[i],
                vestDuration: scheduleVestDurations[i],
                revocable: scheduleRevocables[i],
                revoked: false
            });
            beneficiaries.push(b);
            totalToFund += scheduleAmounts[i];

            emit ScheduleCreated(
                b,
                scheduleAmounts[i],
                startTime_,
                scheduleCliffs[i],
                scheduleVestDurations[i],
                scheduleRevocables[i]
            );
        }

        emit Funded(msg.sender, totalToFund);
        zor.safeTransferFrom(msg.sender, address(this), totalToFund);
    }

    function beneficiaryCount() external view returns (uint256) {
        return beneficiaries.length;
    }

    /// @notice Full schedule for a beneficiary, for portal display.
    function scheduleOf(address beneficiary) external view returns (VestingSchedule memory) {
        return schedules[beneficiary];
    }

    /// @notice Total vested to date, including what has already been claimed.
    function vestedTotal(address beneficiary) external view returns (uint256) {
        return _vestedTotal(schedules[beneficiary], block.timestamp);
    }

    /// @notice Amount claimable right now.
    function claimable(address beneficiary) public view returns (uint256) {
        VestingSchedule memory s = schedules[beneficiary];
        if (s.totalAmount == 0) return 0;
        uint256 vested = _vestedTotal(s, block.timestamp);
        if (vested <= s.claimed) return 0;
        return vested - s.claimed;
    }

    /// @notice Alias for `claimable`, kept so the indexer and any existing
    ///         integration keep working across the rename.
    function vestedAmount(address beneficiary) external view returns (uint256) {
        return claimable(beneficiary);
    }

    function claim() external returns (uint256 amount) {
        amount = claimable(msg.sender);
        if (amount == 0) revert NothingToClaim();

        schedules[msg.sender].claimed =
            (uint256(schedules[msg.sender].claimed) + amount).toUint128();

        emit Claimed(msg.sender, amount);
        zor.safeTransfer(msg.sender, amount);
    }

    /// @notice Freeze a revocable schedule at its currently vested amount and
    ///         return the unvested remainder to the admin.
    function revoke(address beneficiary) external onlyAdmin {
        VestingSchedule storage s = schedules[beneficiary];
        if (!s.revocable) revert NotRevocable();
        if (s.revoked) revert AlreadyRevoked();

        uint256 vested = _vestedTotal(s, block.timestamp);
        uint256 unvested = uint256(s.totalAmount) - vested;

        s.totalAmount = vested.toUint128();
        s.revoked = true;

        emit Revoked(beneficiary, vested, unvested);
        if (unvested > 0) {
            zor.safeTransfer(admin, unvested);
        }
    }

    /// @dev Linear accrual from `startTime` over `vestDuration`, gated by the
    ///      cliff. A revoked schedule has `totalAmount` already clamped to its
    ///      vested value, so it reads as fully vested from that point on.
    function _vestedTotal(VestingSchedule memory s, uint256 timestamp)
        internal
        pure
        returns (uint256)
    {
        if (s.totalAmount == 0) return 0;
        if (s.revoked) return s.totalAmount;

        uint256 start = s.startTime;
        if (timestamp < start + s.cliffDuration) return 0;

        uint256 elapsed = timestamp - start;
        if (elapsed >= s.vestDuration) return s.totalAmount;

        return (uint256(s.totalAmount) * elapsed) / s.vestDuration;
    }
}

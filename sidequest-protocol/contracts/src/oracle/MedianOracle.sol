// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @notice Chainlink-compatible price feed interface.
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title MedianOracle
/// @notice Production, self-operated NAV price oracle for SpotVault: a Chainlink-
///         compatible (AggregatorV3) feed whose answer is the MEDIAN of fresh
///         reports from a set of INDEPENDENT updater keys.
///
///         Guarantees consumed by SpotVault's fail-closed `_oraclePrice`:
///           - every report is bounded to [minAnswer, maxAnswer];
///           - `latestRoundData` REVERTS unless at least `minQuorum` reports are
///             fresh;
///           - it returns the OLDEST contributing timestamp.
contract MedianOracle is AccessControl, AggregatorV3Interface {
    bytes32 public constant UPDATER_ROLE = keccak256("UPDATER_ROLE");

    uint8 private immutable _decimals;
    uint256 public immutable maxStaleness;
    int256 public immutable minAnswer;
    int256 public immutable maxAnswer;
    uint256 public immutable minQuorum;

    struct Report { int256 price; uint64 timestamp; }
    mapping(address => Report) public reports;
    address[] public updaters;
    uint80 private _round;

    event Reported(address indexed updater, int256 price, uint256 timestamp, uint80 round);
    event UpdaterAdded(address indexed updater);
    event UpdaterRemoved(address indexed updater);

    error OutOfBounds(int256 price);
    error InsufficientFreshReports(uint256 fresh, uint256 required);

    constructor(
        uint8 decimals_,
        uint256 maxStaleness_,
        int256 minAnswer_,
        int256 maxAnswer_,
        uint256 minQuorum_,
        address admin_
    ) {
        require(decimals_ > 0 && decimals_ <= 18, "bad decimals");
        require(maxStaleness_ > 0, "zero staleness");
        require(minAnswer_ > 0 && maxAnswer_ > minAnswer_, "bad bounds");
        require(minQuorum_ > 0, "zero quorum");
        require(admin_ != address(0), "zero admin");
        _decimals = decimals_;
        maxStaleness = maxStaleness_;
        minAnswer = minAnswer_;
        maxAnswer = maxAnswer_;
        minQuorum = minQuorum_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    }

    function decimals() external view override returns (uint8) { return _decimals; }

    function updaterCount() external view returns (uint256) { return updaters.length; }

    function addUpdater(address u) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(u != address(0), "zero updater");
        require(!hasRole(UPDATER_ROLE, u), "already updater");
        _grantRole(UPDATER_ROLE, u);
        updaters.push(u);
        emit UpdaterAdded(u);
    }

    function removeUpdater(address u) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(hasRole(UPDATER_ROLE, u), "not updater");
        require(updaters.length > minQuorum, "MedianOracle: would break quorum");
        _revokeRole(UPDATER_ROLE, u);
        uint256 n = updaters.length;
        for (uint256 i = 0; i < n; i++) {
            if (updaters[i] == u) {
                updaters[i] = updaters[n - 1];
                updaters.pop();
                break;
            }
        }
        delete reports[u];
        emit UpdaterRemoved(u);
    }

    function report(int256 price) external onlyRole(UPDATER_ROLE) {
        if (price < minAnswer || price > maxAnswer) revert OutOfBounds(price);
        reports[msg.sender] = Report(price, uint64(block.timestamp));
        unchecked { _round++; }
        emit Reported(msg.sender, price, block.timestamp, _round);
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        uint256 n = updaters.length;
        int256[] memory fresh = new int256[](n);
        uint256 count;
        uint256 oldest = block.timestamp;
        for (uint256 i = 0; i < n; i++) {
            Report memory r = reports[updaters[i]];
            if (r.timestamp != 0 && block.timestamp - r.timestamp <= maxStaleness) {
                fresh[count] = r.price;
                count++;
                if (r.timestamp < oldest) oldest = r.timestamp;
            }
        }
        if (count < minQuorum) revert InsufficientFreshReports(count, minQuorum);
        int256 med = _median(fresh, count);
        return (_round, med, oldest, oldest, _round);
    }

    function _median(int256[] memory a, uint256 count) internal pure returns (int256) {
        for (uint256 i = 1; i < count; i++) {
            int256 key = a[i];
            uint256 j = i;
            while (j > 0 && a[j - 1] > key) {
                a[j] = a[j - 1];
                j--;
            }
            a[j] = key;
        }
        if (count % 2 == 1) return a[count / 2];
        return (a[count / 2 - 1] + a[count / 2]) / 2;
    }
}

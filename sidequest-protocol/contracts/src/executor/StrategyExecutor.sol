// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @notice Minimal interface for the vault's rebalance entrypoint.
interface ISpotRebalancer {
    function rebalanceTo(uint16 targetWeightBps) external;
}

/// @title StrategyExecutor
/// @notice Zorpha V1 EIP-712 rebalance verifier. Validates a signed rebalance
///         command from the manager's `authorizedSigner` and calls
///         `ISpotRebalancer.rebalanceTo(targetWeightBps)` on the target vault.
///
///         Drop-in replacement for the ZENTORY `StrategyExecutor` for Zorpha:
///           - no `HyperCoreAdapter` (no perp path on Robinhood Chain V1)
///           - no `executeSignal` / `SIGNAL_TYPEHASH` (single rebalance path only)
///           - no `MaxPositionSize` / `MaxLeverageBPS` (no leverage / spot-only)
///           - one typehash: `REBALANCE_TYPEHASH`
contract StrategyExecutor is AccessControl {
    bytes32 public constant KEEPER_ROLE    = keccak256("KEEPER_ROLE");
    bytes32 public constant GUARDIAN_ROLE  = keccak256("GUARDIAN_ROLE");

    /// @notice Cached domain separator — rebuilt on chain fork.
    bytes32 private immutable _CACHED_DOMAIN_SEPARATOR;
    uint256 private immutable _CACHED_CHAIN_ID;

    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        if (block.chainid == _CACHED_CHAIN_ID) return _CACHED_DOMAIN_SEPARATOR;
        return _buildDomainSeparator(block.chainid);
    }

    function _buildDomainSeparator(uint256 chainId) private view returns (bytes32) {
        return keccak256(abi.encode(
            keccak256("EIP712Domain(uint256 chainId,address executor)"),
            chainId,
            address(this)
        ));
    }

    /// @notice EIP-712 type hash for a SpotVault target-weight rebalance command.
    bytes32 public constant REBALANCE_TYPEHASH =
        keccak256("Rebalance(address vault,uint16 targetWeightBps,uint256 nonce,uint256 expiry)");

    /// @notice Authorized strategy signer. Initialized to deployer; governance
    ///         transfers via `setAuthorizedSigner`.
    address public authorizedSigner;

    /// @notice Maximum rebalance-expiry window (7 days).
    uint256 public constant MAX_SIGNAL_EXPIRY = 7 days;

    /// @notice Per-vault monotonic nonce (replay guard).
    mapping(address => uint256) public nonces;

    /// @notice Per-vault max rebalances per day (sliding window). 0 = unlimited.
    mapping(address => uint256) public dailyLimit;

    /// @notice Sliding-window nonce timestamps for the daily limit check.
    mapping(address => uint256[]) public recentRebalanceTimestamps;

    bool public paused;

    event RebalanceExecuted(
        address indexed vault,
        uint16          targetWeightBps,
        uint256         nonce,
        address indexed keeper
    );
    event SignalRejected(address indexed vault, string reason);
    event PausedSet(bool paused);
    event AuthorizedSignerSet(address indexed newSigner);

    error PausedError();
    error InvalidSignature();
    error SignalExpired(uint256 expiry, uint256 now_);
    error NonceAlreadyUsed(address vault, uint256 nonce);
    error InvalidWeight(uint16 weight);
    error ExpiryTooFar(uint256 expiry, uint256 maxExpiry);
    error DailyLimitExceeded(uint256 count, uint256 limit);
    error ZeroVault();

    modifier whenNotPaused() {
        if (paused) revert PausedError();
        _;
    }

    constructor(address governor_) {
        require(governor_ != address(0), "StrategyExecutor: zero governor");

        _CACHED_CHAIN_ID = block.chainid;
        _CACHED_DOMAIN_SEPARATOR = _buildDomainSeparator(block.chainid);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(DEFAULT_ADMIN_ROLE, governor_);
        _grantRole(GUARDIAN_ROLE, governor_);

        authorizedSigner = msg.sender;
    }

    function transferAdmin(address newAdmin) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newAdmin != address(0), "StrategyExecutor: zero admin");
        require(newAdmin != msg.sender, "StrategyExecutor: same admin");
        grantRole(DEFAULT_ADMIN_ROLE, newAdmin);
        renounceRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /// @notice Validate and execute a signed target-weight rebalance.
    function executeRebalance(
        address vault,
        uint16  targetWeightBps,
        uint256 nonce,
        uint256 expiry,
        bytes   calldata signature
    )
        external
        whenNotPaused
        onlyRole(KEEPER_ROLE)
        returns (bool)
    {
        if (vault == address(0)) revert ZeroVault();
        if (targetWeightBps > 10000) revert InvalidWeight(targetWeightBps);
        if (block.timestamp > expiry) revert SignalExpired(expiry, block.timestamp);
        uint256 maxExpiryReb = block.timestamp + MAX_SIGNAL_EXPIRY;
        if (expiry > maxExpiryReb) revert ExpiryTooFar(expiry, maxExpiryReb);
        if (nonces[vault] >= nonce) revert NonceAlreadyUsed(vault, nonce);

        // Sliding 24h rate limit.
        uint256 limit = dailyLimit[vault];
        if (limit > 0) {
            uint256[] storage ts = recentRebalanceTimestamps[vault];
            uint256 cutoff = _windowCutoff();

            // Entries are appended in timestamp order, so anything expired sits
            // at the front. Compact in place preserving order, then pop the
            // tail. The previous revision did `delete` followed by re-push,
            // which zeroes every slot and then pays to write each survivor a
            // second time.
            uint256 write;
            for (uint256 read = 0; read < ts.length; read++) {
                if (ts[read] > cutoff) {
                    if (write != read) ts[write] = ts[read];
                    write++;
                }
            }
            while (ts.length > write) ts.pop();

            if (ts.length >= limit) revert DailyLimitExceeded(ts.length, limit);
        }

        bytes32 structHash = keccak256(
            abi.encode(REBALANCE_TYPEHASH, vault, targetWeightBps, nonce, expiry)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));
        _verifySignature(digest, signature);

        // CEI: mark nonce consumed before the external call.
        nonces[vault] = nonce;
        recentRebalanceTimestamps[vault].push(block.timestamp);

        ISpotRebalancer(vault).rebalanceTo(targetWeightBps);

        emit RebalanceExecuted(vault, targetWeightBps, nonce, msg.sender);
        return true;
    }

    // ─── Admin functions ─────────────────────────────────────────────────

    function setPaused(bool paused_) external onlyRole(GUARDIAN_ROLE) {
        paused = paused_;
        emit PausedSet(paused_);
    }

    function setAuthorizedSigner(address signer) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(signer != address(0), "StrategyExecutor: zero signer");
        authorizedSigner = signer;
        emit AuthorizedSignerSet(signer);
    }

    function setDailyLimit(address vault, uint256 limit) external onlyRole(DEFAULT_ADMIN_ROLE) {
        dailyLimit[vault] = limit;
    }

    function getNonce(address vault) external view returns (uint256) {
        return nonces[vault];
    }

    function getRecentRebalanceCount(address vault) external view returns (uint256) {
        uint256 cutoff = _windowCutoff();
        uint256[] storage ts = recentRebalanceTimestamps[vault];
        uint256 count;
        for (uint256 i = 0; i < ts.length; i++) {
            if (ts[i] > cutoff) count++;
        }
        return count;
    }

    // ─── Internal ────────────────────────────────────────────────────────

    /// @dev Start of the sliding 24h window, clamped at zero.
    ///
    ///      `block.timestamp - 1 days` reverts with an arithmetic underflow on
    ///      any chain whose timestamp is below 86400 — which is precisely the
    ///      state a fresh Foundry or Anvil instance starts in, where
    ///      `block.timestamp` is 1. That made every rate-limited rebalance
    ///      revert and hid the entire EIP-712 path from the test suite
    ///      (audit finding V-02).
    function _windowCutoff() internal view returns (uint256) {
        return block.timestamp > 1 days ? block.timestamp - 1 days : 0;
    }

    function _verifySignature(bytes32 digest, bytes calldata signature) internal view {
        if (signature.length != 65) revert InvalidSignature();

        bytes32 r;
        bytes32 s;
        uint8   v;

        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }

        if (v < 27) v += 27;
        if (v != 27 && v != 28) revert InvalidSignature();

        // Enforce low-s (EIP-2) to block signature malleability.
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
            revert InvalidSignature();
        }

        address signer = ecrecover(digest, v, r, s);
        if (signer == address(0)) revert InvalidSignature();
        if (signer != authorizedSigner) revert InvalidSignature();
    }
}

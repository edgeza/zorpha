// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @notice Minimal interface for a single-weight vault's rebalance entrypoint.
interface ISpotRebalancer {
    function rebalanceTo(uint16 targetWeightBps) external;
}

/// @notice And for a basket vault's, which takes a weight per token.
/// @dev    RWRotationVault exposes this form. It is a different selector from
///         ISpotRebalancer.rebalanceTo, which is why calling the latter against
///         a rotation vault reverts with empty data.
interface IBasketRebalancer {
    function rebalanceTo(uint16[] calldata weightsBps) external;
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

    /// @notice EIP-712 type hash for a basket rebalance command.
    /// @dev    A distinct type, not a variant of the one above: signing over a
    ///         weight array is a different authorisation from signing over a
    ///         single weight, and sharing a typehash would let a signature for
    ///         one be replayed as the other.
    bytes32 public constant BASKET_REBALANCE_TYPEHASH =
        keccak256("BasketRebalance(address vault,uint16[] weightsBps,uint256 nonce,uint256 expiry)");

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
    event BasketRebalanceExecuted(
        address indexed vault,
        uint16[] weightsBps,
        uint256 nonce,
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
        // Shared with executeBasketRebalance, so the two paths cannot drift.
        _checkTimingAndNonce(vault, nonce, expiry);
        _enforceRateLimit(vault);

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
    /// @notice Validate and execute a signed basket rebalance.
    ///
    ///         The reason this exists: `RWRotationVault.rebalanceTo` takes
    ///         `uint16[]`, not `uint16`. `executeRebalance` above calls
    ///         `ISpotRebalancer.rebalanceTo(uint16)`, a different selector, so
    ///         it reverts with empty data against a rotation vault. And since
    ///         the deploy grants `KEEPER_ROLE` on each vault only to this
    ///         executor, nothing else could call the array form either: the
    ///         rotation vault shipped unable to rebalance by any route, while
    ///         the portal advertised it as rotating on a signed mandate.
    ///
    ///         Deliberately does NOT validate the basket. The vault owns that:
    ///         it requires `length == tokens.length` and `sum == 10000`, and
    ///         this contract cannot know the token count without a call. A
    ///         partial check here -- the sum but not the length -- would look
    ///         like validation while still letting a mismatched basket through
    ///         to revert deeper. A vault revert unwinds the whole transaction
    ///         including the nonce and rate-limit writes, so nothing is
    ///         consumed by a rejected basket.
    function executeBasketRebalance(
        address vault,
        uint16[] calldata weightsBps,
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
        _checkTimingAndNonce(vault, nonce, expiry);
        _enforceRateLimit(vault);

        bytes32 structHash = keccak256(
            abi.encode(BASKET_REBALANCE_TYPEHASH, vault, _hashWeights(weightsBps), nonce, expiry)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));
        _verifySignature(digest, signature);

        // CEI: consume before the external call, same as the spot path.
        nonces[vault] = nonce;
        recentRebalanceTimestamps[vault].push(block.timestamp);

        IBasketRebalancer(vault).rebalanceTo(weightsBps);

        emit BasketRebalanceExecuted(vault, weightsBps, nonce, msg.sender);
        return true;
    }

    /// @dev EIP-712 hash of a `uint16[]`.
    ///
    ///      An array's encodeData is the keccak of its elements' encodeData
    ///      concatenated, and each element is encoded to a full 32 bytes.
    ///      Widening to uint256 first is what produces that padding:
    ///      `abi.encodePacked` on a `uint16[]` would emit two bytes per
    ///      element and hash to something no compliant signer would ever
    ///      produce.
    function _hashWeights(uint16[] calldata weightsBps) internal pure returns (bytes32) {
        uint256[] memory padded = new uint256[](weightsBps.length);
        for (uint256 i = 0; i < weightsBps.length; i++) {
            padded[i] = weightsBps[i];
        }
        return keccak256(abi.encodePacked(padded));
    }

    /// @dev Expiry, expiry cap and nonce. Shared so the two entrypoints cannot
    ///      drift apart -- the bug this whole change addresses came from two
    ///      call paths that were meant to match and did not.
    function _checkTimingAndNonce(address vault, uint256 nonce, uint256 expiry) internal view {
        if (block.timestamp > expiry) revert SignalExpired(expiry, block.timestamp);
        uint256 maxExpiry = block.timestamp + MAX_SIGNAL_EXPIRY;
        if (expiry > maxExpiry) revert ExpiryTooFar(expiry, maxExpiry);
        if (nonces[vault] >= nonce) revert NonceAlreadyUsed(vault, nonce);
    }

    /// @dev Sliding 24h window: compact out anything older than the cutoff,
    ///      then refuse if the survivors already fill the limit.
    function _enforceRateLimit(address vault) internal {
        uint256 limit = dailyLimit[vault];
        if (limit == 0) return;

        uint256[] storage ts = recentRebalanceTimestamps[vault];
        uint256 cutoff = _windowCutoff();

        // Entries are appended in timestamp order, so anything expired sits at
        // the front. Compact in place preserving order, then pop the tail. An
        // earlier revision did `delete` followed by re-push, which zeroes every
        // slot and then pays to write each survivor a second time.
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

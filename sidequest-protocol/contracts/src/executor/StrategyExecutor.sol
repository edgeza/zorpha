// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

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
contract StrategyExecutor is AccessControl, EIP712 {
    bytes32 public constant KEEPER_ROLE    = keccak256("KEEPER_ROLE");
    bytes32 public constant GUARDIAN_ROLE  = keccak256("GUARDIAN_ROLE");

    /// @notice EIP-712 domain name and version, as signed.
    /// @dev    Passed to OpenZeppelin's `EIP712` constructor. Changing either
    ///         silently invalidates every outstanding signature, so both are
    ///         constants: it takes a redeploy, not a transaction.
    string public constant EIP712_NAME = "Zorpha Strategy Executor";
    string public constant EIP712_VERSION = "1";

    /// @notice The EIP-712 domain separator, as used in every rebalance digest.
    ///
    /// @dev    Delegates to OpenZeppelin's `EIP712`, which caches the separator
    ///         against the deploying chain id and rebuilds it if `block.chainid`
    ///         changes -- so a forked chain cannot accept signatures minted for
    ///         the original.
    ///
    ///         This used to be hand-rolled, over a non-standard domain:
    ///         `EIP712Domain(uint256 chainId,address executor)`. Two fields
    ///         present, two absent, the address field renamed. That was
    ///         cryptographically sound -- chainId stops a signature crossing
    ///         chains and the contract address stops it crossing contracts,
    ///         which is the entire replay surface -- but no wallet could render
    ///         it. Wallets match on the standard type string to decide whether a
    ///         payload is structured data they can display, so a manager
    ///         authorising a rebalance saw 32 bytes of hex, on the exact
    ///         mechanism this protocol asks people to trust.
    ///
    ///         Kept as a named public getter because four drill scripts read it
    ///         to cross-check their own encoding, and because `DOMAIN_SEPARATOR`
    ///         is the conventional name for it. ERC-5267 `eip712Domain()` comes
    ///         from the library, so tooling can discover the domain rather than
    ///         copying the type string out of this file by hand.
    ///
    ///         Changed before mainnet deliberately: it invalidates any signature
    ///         built against the old domain, which costs nothing while the only
    ///         such signatures are in testnet drills. Afterwards it would strand
    ///         whatever was in flight. See docs/FINDINGS-EIP712-DOMAIN.md.
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return _domainSeparatorV4();
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

    /// @notice Per-vault trading window, in UTC minutes of the day.
    ///
    ///         A tokenised equity trades 24/7 on this chain while its reference
    ///         market is shut sixteen hours a day and all weekend. Chainlink's
    ///         deviation trigger guards against acting on a stale price only
    ///         while there IS a live price to deviate from; overnight the feed
    ///         is frozen because the market is closed, not because the price is
    ///         steady. Without this, a manager who knows the stock gapped after
    ///         hours can sign a rebalance against the previous close and every
    ///         other check here passes.
    ///
    ///         Unset means unrestricted, so 24/7 assets and every vault that
    ///         existed before this are unaffected.
    struct TradingWindow {
        uint16 openMinuteUTC;   // 0..1439
        uint16 closeMinuteUTC;  // 0..1439; below open means the window wraps midnight
        uint8  weekdayMask;     // bit d set => day d allowed, 0 = Sunday
        bool   enforced;
    }
    mapping(address => TradingWindow) public tradingWindow;

    /// @notice Holiday override: rebalances refused until this timestamp.
    ///
    ///         Separate from the weekly schedule because market holidays do not
    ///         follow one, and half-days are a closure like any other. Governance
    ///         sets it; nothing off-chain is trusted to.
    mapping(address => uint64) public closedUntil;

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
    event TradingWindowSet(address indexed vault, uint16 openMinuteUTC, uint16 closeMinuteUTC, uint8 weekdayMask);
    event TradingWindowCleared(address indexed vault);
    event ClosedUntilSet(address indexed vault, uint64 until);

    error PausedError();
    error InvalidSignature();
    error SignalExpired(uint256 expiry, uint256 now_);
    error NonceAlreadyUsed(address vault, uint256 nonce);
    error InvalidWeight(uint16 weight);
    error ExpiryTooFar(uint256 expiry, uint256 maxExpiry);
    error DailyLimitExceeded(uint256 count, uint256 limit);
    error ZeroVault();
    error MarketClosed(address vault, uint256 minuteUTC, uint256 dayOfWeek);
    error MarketHalted(address vault, uint64 until);
    error BadTradingWindow();

    modifier whenNotPaused() {
        if (paused) revert PausedError();
        _;
    }

    constructor(address governor_) EIP712(EIP712_NAME, EIP712_VERSION) {
        require(governor_ != address(0), "StrategyExecutor: zero governor");

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
        _checkTradingWindow(vault);
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
        _checkTradingWindow(vault);
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
    /// @dev Refuse while the vault's reference market is shut.
    ///
    ///      DST IS NOT HANDLED, DELIBERATELY. The schedule is fixed UTC, and a
    ///      market keeping local hours moves by an hour twice a year: US equities
    ///      run 13:30-20:00 UTC in summer and 14:30-21:00 in winter. Governance
    ///      must reset the window at each transition -- two transactions a year,
    ///      explicit and auditable through TradingWindowSet.
    ///
    ///      The alternative is encoding one jurisdiction's DST rules on chain,
    ///      where they are wrong for every other market and wrong again whenever
    ///      a legislature changes them. A schedule that is visibly an hour off
    ///      for a fortnight is recoverable; one that is confidently wrong is not.
    function _checkTradingWindow(address vault) internal view {
        TradingWindow memory w = tradingWindow[vault];
        if (!w.enforced) return;

        uint64 until = closedUntil[vault];
        if (block.timestamp < until) revert MarketHalted(vault, until);

        // Slither flags both of these as weak-prng, and both are calendar
        // arithmetic rather than randomness: a modulo of a Unix timestamp is
        // how a day of week and a minute of day are derived, and there is no
        // other way to get them on chain.
        //
        // The adversarial question is whether a validator can bias the result
        // usefully. They can nudge block.timestamp by seconds, which can move a
        // rebalance a few seconds either side of an open or a close. The
        // property this defends is that a manager cannot trade against a price
        // frozen because the market shut sixteen hours ago -- so seconds of
        // slop at a boundary is immaterial to it, and is the accepted residual.
        //
        // Nothing here allocates, prices or selects on the value; it is
        // compared against a schedule governance set in advance.
        //
        // Unix epoch day 0 was a Thursday, so +4 lands 0 on Sunday.
        // slither-disable-next-line weak-prng
        uint256 dayOfWeek = ((block.timestamp / 1 days) + 4) % 7;
        // slither-disable-next-line weak-prng
        uint256 minuteUTC = (block.timestamp % 1 days) / 60;

        if (((w.weekdayMask >> dayOfWeek) & 1) == 0) {
            revert MarketClosed(vault, minuteUTC, dayOfWeek);
        }

        bool open = w.openMinuteUTC < w.closeMinuteUTC
            ? (minuteUTC >= w.openMinuteUTC && minuteUTC < w.closeMinuteUTC)
            : (minuteUTC >= w.openMinuteUTC || minuteUTC < w.closeMinuteUTC);
        if (!open) revert MarketClosed(vault, minuteUTC, dayOfWeek);
    }

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

    /// @notice Restrict a vault's rebalances to its reference market's hours.
    /// @param  weekdayMask bit d set => day d allowed, 0 = Sunday. Mon-Fri is 0x3E.
    function setTradingWindow(
        address vault,
        uint16  openMinuteUTC,
        uint16  closeMinuteUTC,
        uint8   weekdayMask
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (vault == address(0)) revert ZeroVault();
        // Each rejection is a configuration that would silently never open:
        // an out-of-range minute, an empty mask, or a zero-length window. Use
        // clearTradingWindow to lift the restriction and setClosedUntil or
        // setPaused to halt -- none of them should be spelled as a schedule
        // that can never match.
        if (openMinuteUTC > 1439 || closeMinuteUTC > 1439) revert BadTradingWindow();
        if (weekdayMask == 0 || weekdayMask > 0x7F) revert BadTradingWindow();
        if (openMinuteUTC == closeMinuteUTC) revert BadTradingWindow();

        tradingWindow[vault] = TradingWindow({
            openMinuteUTC: openMinuteUTC,
            closeMinuteUTC: closeMinuteUTC,
            weekdayMask: weekdayMask,
            enforced: true
        });
        emit TradingWindowSet(vault, openMinuteUTC, closeMinuteUTC, weekdayMask);
    }

    /// @notice Lift the restriction entirely. For 24/7 assets.
    function clearTradingWindow(address vault) external onlyRole(DEFAULT_ADMIN_ROLE) {
        delete tradingWindow[vault];
        emit TradingWindowCleared(vault);
    }

    /// @notice Refuse rebalances until `until`, over and above the weekly schedule.
    function setClosedUntil(address vault, uint64 until) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (vault == address(0)) revert ZeroVault();
        closedUntil[vault] = until;
        emit ClosedUntilSet(vault, until);
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

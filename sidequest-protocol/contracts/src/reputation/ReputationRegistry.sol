// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title ReputationRegistry
/// @notice Zorpha V1 opt-in onchain stats commitment for vault managers.
///         The dApp computes manager stats (Sharpe, drawdown, alpha vs benchmark,
///         total rebalances) off-chain from the Supabase index of rebalance
///         events, then the manager signs and publishes a keccak256 commitment
///         to those stats. Anyone can challenge the commitment within a window
///         by supplying a counter-proof.
///
///         This is a CHEAP, OFFCHAIN-VERIFIABLE reputation primitive; it does
///         NOT store numerical stats on chain. It only stores a hash and a
///         small public struct so off-chain observers can verify a manager's
///         claim matches their actual receipts history.
contract ReputationRegistry is AccessControl {
    struct StatsCommitment {
        bytes32 commitment;
        uint64  publishedAt;
        uint64  challengeDeadline; // == publishedAt + CHALLENGE_WINDOW
        uint256 windowStart;
        uint256 windowEnd;
        uint256 nonce;
        bool    challenged;
        bool    upheld; // true if challenged-and-upheld, false if challenged-and-overturned
    }

    uint256 public constant CHALLENGE_WINDOW = 7 days;

    /// @notice Per-manager monotonic nonce.
    mapping(address => uint256) public nonces;

    /// @notice Full publish history per manager. This is the ONLY copy of a
    ///         commitment's state.
    ///
    ///         A separate `latest` mapping used to hold a duplicate of the most
    ///         recent entry, but `challenge` only ever wrote to `history`. The
    ///         two therefore diverged the moment anything was challenged, and
    ///         `getLatest`; which is what the portal reads, kept reporting a
    ///         disputed commitment as unchallenged. Derived state cannot drift
    ///         from its source, so `latest` is gone.
    mapping(address => StatsCommitment[]) public history;

    /// @notice Who challenged a given entry, if anyone.
    mapping(address => mapping(uint256 => address)) public challengerOf;

    event StatsPublished(
        address indexed manager,
        bytes32 commitment,
        uint256 windowStart,
        uint256 windowEnd,
        uint256 nonce,
        uint256 challengeDeadline
    );
    event StatsChallenged(
        address indexed manager,
        uint256 index,
        address indexed challenger,
        bytes32 counterCommitment
    );
    event StatsUpheld(address indexed manager, uint256 index, address indexed arbiter);
    event StatsOverturned(address indexed manager, uint256 index, address indexed arbiter);

    error CommitmentMismatch();
    error ChallengeWindowClosed();
    error AlreadyChallenged();
    error BadWindow();
    error NoDispute();
    error NotChallenged();
    error NoHistory();

    constructor(address admin_) {
        require(admin_ != address(0), "ReputationRegistry: zero admin");
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    }

    /// @notice Publish a stats commitment for a manager. Anyone can submit on
    ///         behalf of the manager; the off-chain signed message proves intent.
    function publish(
        address manager,
        bytes32 commitment,
        uint256 windowStart,
        uint256 windowEnd
    ) external {
        require(manager != address(0), "ReputationRegistry: zero manager");
        require(windowEnd > windowStart, "ReputationRegistry: bad window");
        require(block.timestamp >= windowStart && block.timestamp <= windowEnd, "ReputationRegistry: bad window");
        require(commitment != bytes32(0), "ReputationRegistry: zero commitment");

        uint256 nonce = nonces[manager] + 1;
        nonces[manager] = nonce;

        StatsCommitment memory c = StatsCommitment({
            commitment: commitment,
            publishedAt: uint64(block.timestamp),
            challengeDeadline: uint64(block.timestamp + CHALLENGE_WINDOW),
            windowStart: windowStart,
            windowEnd: windowEnd,
            nonce: nonce,
            challenged: false,
            upheld: false
        });

        history[manager].push(c);

        emit StatsPublished(manager, commitment, windowStart, windowEnd, nonce, c.challengeDeadline);
    }

    /// @notice Raise a dispute against a published commitment by supplying the
    ///         commitment the challenger independently computed from the public
    ///         rebalance index.
    ///
    ///         Only a MISMATCH is a dispute. If the challenger reproduces the
    ///         published hash there is nothing to arbitrate and the call
    ///         reverts, leaving the entry untouched and the window open.
    ///
    ///         The previous revision instead marked a matching challenge as
    ///         `upheld = true`. That made the positive status trivially
    ///         self-mintable: a manager could publish any hash at all, chase it
    ///         with a self-challenge quoting that same hash, and be recorded as
    ///         upheld, while `!challenged` then permanently blocked a genuine
    ///         challenge from anyone else. The portal renders `upheld` as a
    ///         green "Upheld" badge, so the flag actively misled readers about
    ///         stats nobody had verified.
    function challenge(
        address manager,
        uint256 index,
        bytes32 counterCommitment
    ) external {
        if (index >= history[manager].length) revert NoHistory();
        StatsCommitment storage c = history[manager][index];
        if (block.timestamp > c.challengeDeadline) revert ChallengeWindowClosed();
        if (c.challenged) revert AlreadyChallenged();
        if (c.commitment == counterCommitment) revert NoDispute();

        c.challenged = true;
        c.upheld = false;
        challengerOf[manager][index] = msg.sender;

        emit StatsChallenged(manager, index, msg.sender, counterCommitment);
    }

    /// @notice Resolve an open dispute. Governance is the arbiter: deciding
    ///         which of two off-chain stats computations is correct is not
    ///         something the chain can do, and a hash comparison the disputing
    ///         parties supply themselves cannot settle it either.
    ///
    ///         This is what gives `upheld` any meaning. Until an arbiter calls
    ///         this, a challenged entry reads as disputed and unresolved, which
    ///         is the honest state.
    function resolveChallenge(address manager, uint256 index, bool managerUpheld)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (index >= history[manager].length) revert NoHistory();
        StatsCommitment storage c = history[manager][index];
        if (!c.challenged) revert NotChallenged();

        c.upheld = managerUpheld;

        if (managerUpheld) {
            emit StatsUpheld(manager, index, msg.sender);
        } else {
            emit StatsOverturned(manager, index, msg.sender);
        }
    }

    function getHistoryLength(address manager) external view returns (uint256) {
        return history[manager].length;
    }

    /// @notice Most recent commitment for a manager, derived from history so it
    ///         can never disagree with it. Returns a zeroed struct when the
    ///         manager has never published.
    function getLatest(address manager) external view returns (StatsCommitment memory) {
        uint256 len = history[manager].length;
        if (len == 0) return StatsCommitment(bytes32(0), 0, 0, 0, 0, 0, false, false);
        return history[manager][len - 1];
    }

    /// @notice One entry by index.
    function getAt(address manager, uint256 index)
        external
        view
        returns (StatsCommitment memory)
    {
        if (index >= history[manager].length) revert NoHistory();
        return history[manager][index];
    }
}

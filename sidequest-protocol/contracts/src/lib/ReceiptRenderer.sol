// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title ReceiptRenderer
/// @notice Pure-function helper that produces a deterministic keccak256 commitment
///         used by both the `Rebalanced` event and the `ReputationRegistry`
///         publish flow. Same inputs → same hash, so off-chain observers can
///         verify that a published reputation claim refers to a specific
///         rebalance receipt.
library ReceiptRenderer {
    /// @notice Build the receipt commitment hash for a manager rebalance.
    /// @param manager         The signer address.
    /// @param vault           The vault address being rebalanced.
    /// @param targetBps       The target underlying weight in bps (0..10000).
    /// @param navPerShare     NAV/share at the moment of rebalance (in asset units).
    /// @param assetLeg        Underlying balance after rebalance.
    /// @param cashLeg         Cash balance after rebalance.
    /// @param nonce           Per-vault monotonic nonce.
    /// @param blockTimestamp  Block timestamp of the rebalance.
    /// @param txHash          Transaction hash (the receipt's identifier).
    function commitment(
        address manager,
        address vault,
        uint16  targetBps,
        uint256 navPerShare,
        uint256 assetLeg,
        uint256 cashLeg,
        uint256 nonce,
        uint256 blockTimestamp,
        bytes32 txHash
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(
            manager,
            vault,
            targetBps,
            navPerShare,
            assetLeg,
            cashLeg,
            nonce,
            blockTimestamp,
            txHash
        ));
    }

    /// @notice Build the receipt commitment for a multi-asset basket rebalance.
    ///
    ///         The single-asset `commitment` above cannot express a basket: it
    ///         takes one `targetBps` and one `cashLeg`. `RWRotationVault`
    ///         previously squeezed itself into that shape by passing
    ///         `rebalanceCount % 65536` as the target weight and the constant
    ///         10000 (the weight checksum) as the cash leg, so the resulting
    ///         hash bound neither the basket weights nor the per-token legs.
    ///         Those are precisely the fields a rotation receipt exists to
    ///         attest, which made the commitment unverifiable for the one vault
    ///         type that needed it most.
    ///
    ///         Uses `abi.encode`, not `abi.encodePacked`: two dynamic arrays
    ///         packed together are ambiguous and admit collisions.
    /// @param manager        The signer address.
    /// @param vault          The vault being rebalanced.
    /// @param targetWeights  Target weight per basket slot, in bps.
    /// @param navPerShare    NAV/share at the moment of rebalance.
    /// @param tokenLegs      Post-rebalance balance of each basket token.
    /// @param baseLeg        Post-rebalance balance of the base asset.
    /// @param nonce          Per-vault monotonic nonce.
    /// @param blockTimestamp Block timestamp of the rebalance.
    /// @param txHash         Transaction hash slot, filled by the indexer.
    function basketCommitment(
        address manager,
        address vault,
        uint16[] memory targetWeights,
        uint256 navPerShare,
        uint256[] memory tokenLegs,
        uint256 baseLeg,
        uint256 nonce,
        uint256 blockTimestamp,
        bytes32 txHash
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(
            manager,
            vault,
            targetWeights,
            navPerShare,
            tokenLegs,
            baseLeg,
            nonce,
            blockTimestamp,
            txHash
        ));
    }

    /// @notice Build the reputation publish hash from off-chain-computed stats.
    /// @param manager            Manager address.
    /// @param totalRebalances    Total rebalances submitted by this manager.
    /// @param sharpeBps          Sharpe ratio scaled by 10000.
    /// @param maxDrawdownBps     Max drawdown in basis points (0..10000).
    /// @param alphaVsBenchmarkBps Alpha vs benchmark, scaled by 10000. Can be negative.
    /// @param windowStart        Start timestamp of the stats window.
    /// @param windowEnd          End timestamp of the stats window.
    /// @param nonce              Per-manager monotonically increasing nonce.
    function reputationHash(
        address manager,
        uint256 totalRebalances,
        uint256 sharpeBps,
        uint256 maxDrawdownBps,
        int256  alphaVsBenchmarkBps,
        uint256 windowStart,
        uint256 windowEnd,
        uint256 nonce
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(
            manager,
            totalRebalances,
            sharpeBps,
            maxDrawdownBps,
            alphaVsBenchmarkBps,
            windowStart,
            windowEnd,
            nonce
        ));
    }
}

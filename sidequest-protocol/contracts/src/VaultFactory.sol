// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {SpotVaultMinimal} from "./vaults/SpotVaultMinimal.sol";
import {RWRotationVault} from "./vaults/RWRotationVault.sol";
import {YieldVault} from "./vaults/YieldVault.sol";

// SIZE: this contract compiles to ~45,085 bytes of runtime code, about 41,000
// of which is the three vault creationCodes inlined by the type(...) reads
// below. That is 20kB past the 24,576-byte EIP-170 limit, so it CANNOT be
// deployed to Ethereum L1 or to any chain that enforces that limit on raw
// bytecode. It deploys on Robinhood Chain only because Arbitrum Nitro applies
// the limit to brotli-COMPRESSED code, and these three blobs compress well.
//
// The headroom is therefore in compressed bytes, which nothing local measures.
// Adding a fourth vault type could cross the real limit while `forge build
// --sizes` shows nothing new -- the first sign would be a reverted mainnet
// deploy. Before adding one, split this into per-vault-type factories
// (VaultLauncher only ever calls deployYieldVault, so it would follow the
// yield one) rather than assuming the next blob also fits.

/// @notice Vault deployment params for SpotVaultMinimal.
struct SpotVaultParams {
    address asset;
    address cashAsset;
    address oracle;
    uint256 maxOracleStaleness;
    string  name;
    string  symbol;
    uint16  rebalanceThresholdBps;
    uint16  maxSlippageBps;
    uint256 performanceFeeBps;
    address feeRecipient;
    address admin;
    uint256 emergencyRedeemCooldown;
}

/// @notice Vault deployment params for RWRotationVault.
struct RWRotationVaultParams {
    address baseAsset;
    address[] tokens;
    address[] oracles;
    uint256 maxOracleStaleness;
    uint16[] initialWeightsBps;
    string  name;
    string  symbol;
    uint256 performanceFeeBps;
    address feeRecipient;
    address admin;
}

/// @notice Vault deployment params for YieldVault.
struct YieldVaultParams {
    address asset;
    address adapter;
    string  name;
    string  symbol;
    uint256 performanceFeeBps;
    address feeRecipient;
    address admin;
}

/// @title VaultFactory
/// @notice Zorpha V1 gated vault factory. Deploys any of the three curated
///         vault types. Owner-gated in V1; the deployer-only gate is dropped
///         in V2 (when manager bonding + slashing land).
///
///         All deployments use CREATE2 with the caller's salt so the same
///         deployer can produce deterministic addresses for re-deployment.
contract VaultFactory is AccessControl {
    bytes32 public constant DEPLOYER_ROLE = keccak256("DEPLOYER_ROLE");

    /// @notice Per-vault-type deployment counters (for CREATE2 salt uniqueness
    ///         across same-typed deployments from the same caller).
    uint256 public spotDeployCount;
    uint256 public rotationDeployCount;
    uint256 public yieldDeployCount;

    event SpotVaultDeployed(address indexed vault, address indexed deployer, bytes32 salt);
    event RotationVaultDeployed(address indexed vault, address indexed deployer, bytes32 salt);
    event YieldVaultDeployed(address indexed vault, address indexed deployer, bytes32 salt);

    constructor(address admin_) {
        require(admin_ != address(0), "VaultFactory: zero admin");
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(DEPLOYER_ROLE, admin_);
    }

    function deploySpotVault(SpotVaultParams calldata p, bytes32 salt)
        external
        onlyRole(DEPLOYER_ROLE)
        returns (address vault)
    {
        spotDeployCount += 1;
        vault = Create2.deploy(
            0,
            salt,
            abi.encodePacked(
                type(SpotVaultMinimal).creationCode,
                abi.encode(
                    p.asset,
                    p.cashAsset,
                    p.oracle,
                    p.maxOracleStaleness,
                    p.name,
                    p.symbol,
                    p.rebalanceThresholdBps,
                    p.maxSlippageBps,
                    p.performanceFeeBps,
                    p.feeRecipient,
                    p.admin,
                    p.emergencyRedeemCooldown
                )
            )
        );
        emit SpotVaultDeployed(vault, msg.sender, salt);
    }

    function deployRotationVault(RWRotationVaultParams calldata p, bytes32 salt)
        external
        onlyRole(DEPLOYER_ROLE)
        returns (address vault)
    {
        rotationDeployCount += 1;
        vault = Create2.deploy(
            0,
            salt,
            abi.encodePacked(
                type(RWRotationVault).creationCode,
                abi.encode(
                    p.baseAsset,
                    p.tokens,
                    p.oracles,
                    p.maxOracleStaleness,
                    p.initialWeightsBps,
                    p.name,
                    p.symbol,
                    p.performanceFeeBps,
                    p.feeRecipient,
                    p.admin
                )
            )
        );
        emit RotationVaultDeployed(vault, msg.sender, salt);
    }

    function deployYieldVault(YieldVaultParams calldata p, bytes32 salt)
        external
        onlyRole(DEPLOYER_ROLE)
        returns (address vault)
    {
        yieldDeployCount += 1;
        vault = Create2.deploy(
            0,
            salt,
            abi.encodePacked(
                type(YieldVault).creationCode,
                abi.encode(
                    p.asset,
                    p.adapter,
                    p.name,
                    p.symbol,
                    p.performanceFeeBps,
                    p.feeRecipient,
                    p.admin
                )
            )
        );
        emit YieldVaultDeployed(vault, msg.sender, salt);
    }

    /// @notice Predict a CREATE2 address for a Spot vault deployment.
    function predictSpotVault(SpotVaultParams calldata p, bytes32 salt) external view returns (address) {
        return Create2.computeAddress(
            salt,
            keccak256(
                abi.encodePacked(
                    type(SpotVaultMinimal).creationCode,
                    abi.encode(
                        p.asset, p.cashAsset, p.oracle, p.maxOracleStaleness,
                        p.name, p.symbol,
                        p.rebalanceThresholdBps, p.maxSlippageBps,
                        p.performanceFeeBps, p.feeRecipient, p.admin,
                        p.emergencyRedeemCooldown
                    )
                )
            ),
            address(this)
        );
    }

    function predictRotationVault(RWRotationVaultParams calldata p, bytes32 salt) external view returns (address) {
        return Create2.computeAddress(
            salt,
            keccak256(
                abi.encodePacked(
                    type(RWRotationVault).creationCode,
                    abi.encode(
                        p.baseAsset, p.tokens, p.oracles, p.maxOracleStaleness,
                        p.initialWeightsBps, p.name, p.symbol,
                        p.performanceFeeBps, p.feeRecipient, p.admin
                    )
                )
            ),
            address(this)
        );
    }

    function predictYieldVault(YieldVaultParams calldata p, bytes32 salt) external view returns (address) {
        return Create2.computeAddress(
            salt,
            keccak256(
                abi.encodePacked(
                    type(YieldVault).creationCode,
                    abi.encode(
                        p.asset, p.adapter, p.name, p.symbol,
                        p.performanceFeeBps, p.feeRecipient, p.admin
                    )
                )
            ),
            address(this)
        );
    }
}

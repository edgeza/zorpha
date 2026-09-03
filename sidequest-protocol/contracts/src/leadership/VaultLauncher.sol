// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {VaultFactory, YieldVaultParams} from "../VaultFactory.sol";
import {YieldVault} from "../vaults/YieldVault.sol";
import {FirstLossEscrow} from "./FirstLossEscrow.sol";
import {ERC4626YieldAdapter} from "../adapters/ERC4626YieldAdapter.sol";

/// @title VaultLauncher
/// @notice Permissionless vault creation, with the guardrails in the launcher
///         rather than in a role.
///
///         `VaultFactory` stays gated on `DEPLOYER_ROLE`; this contract holds
///         that role and is the only thing that uses it. Opening the factory
///         directly would mean anyone could deploy a vault with a 100% fee
///         pointed at an adapter they control. Opening it *through* here means
///         anyone can launch a vault, but only one that has posted a bond,
///         subordinated the leader's capital, and allocates to a venue
///         governance has vetted.
///
///         What a leader can and cannot do is the whole design:
///
///           can    launch a vault, choose among approved venues, reallocate
///                  between them, earn a share of the performance fee
///           cannot become vault admin, change the fee, install an adapter of
///                  their own making, disable the escrow, or move depositor
///                  funds anywhere except an approved venue
///
///         The bond is denominated in $ZOR and is a bond, not a toll. It buys
///         no access to the product — depositors never need it — it is capital
///         at risk for the right to operate a vault, forfeitable for
///         misconduct. First-loss capital is deliberately NOT in $ZOR: a
///         buffer whose price falls with the protocol's fortunes evaporates
///         exactly when it is needed.
contract VaultLauncher is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");

    IERC20 public immutable zor;
    VaultFactory public immutable factory;
    address public immutable protocolTreasury;
    address public immutable vaultAdmin;

    /// @notice ERC-4626 venues a vault may allocate to.
    /// @dev An allowlist, not a free choice. Without it a leader points the
    ///      vault at a contract they wrote and the depositors' money is gone in
    ///      one transaction, escrow or not.
    mapping(address => bool) public approvedTarget;

    uint256 public bondAmount;
    uint256 public minSeedEscrow;
    uint16 public minCoverageBps;
    uint16 public leaderFeeShareBps;
    uint256 public performanceFeeBps;

    struct Launch {
        address vault;
        address escrow;
        address adapter;
        address leader;
        address asset;
        uint256 bond;
        uint64 createdAt;
        bool bondReleased;
        bool bondSlashed;
    }

    Launch[] public launches;
    mapping(address => uint256) public launchIdOfVault; // 1-indexed; 0 = unknown
    mapping(address => uint256[]) internal _launchesOfLeader;

    error NotLeader();
    error UnknownVault();
    error TargetNotApproved(address target);
    error SeedTooSmall(uint256 provided, uint256 required);
    error BondAlreadyResolved();
    error VaultNotEmpty(uint256 remaining);
    error AssetMismatch();
    error BadParams();

    event TargetApproved(address indexed target, bool approved);
    event ParamsUpdated(
        uint256 bondAmount, uint256 minSeedEscrow, uint16 minCoverageBps, uint16 leaderFeeShareBps
    );
    event VaultLaunched(
        uint256 indexed launchId,
        address indexed leader,
        address indexed vault,
        address escrow,
        address adapter,
        address target,
        uint256 bond,
        uint256 seed
    );
    event Reallocated(uint256 indexed launchId, address oldTarget, address newTarget, address newAdapter);
    event BondSlashed(uint256 indexed launchId, uint256 amount, string reason);
    event BondReleased(uint256 indexed launchId, uint256 amount);

    constructor(
        address zor_,
        address factory_,
        address protocolTreasury_,
        address vaultAdmin_,
        address governance_
    ) {
        if (
            zor_ == address(0) || factory_ == address(0) || protocolTreasury_ == address(0)
                || vaultAdmin_ == address(0) || governance_ == address(0)
        ) revert BadParams();

        zor = IERC20(zor_);
        factory = VaultFactory(factory_);
        protocolTreasury = protocolTreasury_;
        vaultAdmin = vaultAdmin_;

        _grantRole(DEFAULT_ADMIN_ROLE, governance_);
        _grantRole(GOVERNANCE_ROLE, governance_);

        bondAmount = 10_000e18; // 10k ZOR
        minSeedEscrow = 1_000e6; // 1,000 units of a 6dp asset
        // 5%, the level Hyperliquid settled on. Note that the RISK parameter
        // was benchmarked against that comparable and the FEE was not -- the
        // spot and rotation vaults charge twice Hyperliquid's 10%. That is a
        // leader-recruitment decision rather than a revenue one: with
        // leaderFeeShareBps at 8000, a 20% fee pays the leader 16 points and
        // the protocol 4. Reasoning in docs/FEE-DESIGN.md.
        minCoverageBps = 500;
        leaderFeeShareBps = 8000; // 80% of the fee to the leader
        performanceFeeBps = 1000; // 10%
    }

    // ─── Governance ──────────────────────────────────────────────────────────

    function setTargetApproved(address target, bool approved) external onlyRole(GOVERNANCE_ROLE) {
        approvedTarget[target] = approved;
        emit TargetApproved(target, approved);
    }

    function setParams(
        uint256 bondAmount_,
        uint256 minSeedEscrow_,
        uint16 minCoverageBps_,
        uint16 leaderFeeShareBps_,
        uint256 performanceFeeBps_
    ) external onlyRole(GOVERNANCE_ROLE) {
        if (
            minCoverageBps_ > 10_000 || leaderFeeShareBps_ > 10_000 || performanceFeeBps_ > 10_000
        ) revert BadParams();
        bondAmount = bondAmount_;
        minSeedEscrow = minSeedEscrow_;
        minCoverageBps = minCoverageBps_;
        leaderFeeShareBps = leaderFeeShareBps_;
        performanceFeeBps = performanceFeeBps_;
        emit ParamsUpdated(bondAmount_, minSeedEscrow_, minCoverageBps_, leaderFeeShareBps_);
    }

    // ─── Launching ───────────────────────────────────────────────────────────

    /// @notice Launch a yield vault. Caller becomes its leader.
    /// @param target An approved ERC-4626 venue the vault allocates to.
    /// @param seedEscrow First-loss capital, in the vault's asset, posted now.
    /// @param name,symbol Vault share token metadata.
    /// @param salt CREATE2 salt, so a leader can pre-compute their address.
    function launchYieldVault(
        address target,
        uint256 seedEscrow,
        string calldata name,
        string calldata symbol,
        bytes32 salt
    ) external nonReentrant returns (address vault, address escrow) {
        if (!approvedTarget[target]) revert TargetNotApproved(target);
        if (seedEscrow < minSeedEscrow) revert SeedTooSmall(seedEscrow, minSeedEscrow);

        address asset = IERC4626(target).asset();

        // Bond first: everything after this costs gas on the leader's behalf.
        uint256 bond = bondAmount;
        if (bond > 0) zor.safeTransferFrom(msg.sender, address(this), bond);

        // The adapter is deployed by THIS contract, so its target is whatever
        // the allowlist says and nothing else.
        ERC4626YieldAdapter adapter =
            new ERC4626YieldAdapter(asset, target, address(this));

        vault = factory.deployYieldVault(
            YieldVaultParams({
                asset: asset,
                adapter: address(adapter),
                name: name,
                symbol: symbol,
                performanceFeeBps: performanceFeeBps,
                // Overwritten in practice: fees are claimed into the escrow,
                // which performs the split. Set to the treasury so an
                // escrow-less path still pays somewhere sane.
                feeRecipient: protocolTreasury,
                admin: address(this)
            }),
            // Namespaced per leader. A bare caller-supplied salt is a griefing
            // vector: CREATE2 reverts on a collision, so anyone watching the
            // mempool could burn a leader's chosen address by front-running it
            // with the same salt. Hashing in the sender makes each leader's
            // salt space their own.
            keccak256(abi.encode(msg.sender, salt))
        );

        adapter.grantRole(adapter.VAULT_ROLE(), vault);

        escrow = address(
            new FirstLossEscrow(
                asset, vault, msg.sender, protocolTreasury, leaderFeeShareBps, minCoverageBps
            )
        );

        YieldVault(vault).setFirstLossEscrow(escrow);

        // Seed the buffer from the leader before anyone can deposit, so the
        // vault is never briefly live and unprotected.
        IERC20(asset).safeTransferFrom(msg.sender, address(this), seedEscrow);
        IERC20(asset).forceApprove(escrow, seedEscrow);
        FirstLossEscrow(escrow).fund(seedEscrow);

        // Hand the vault to governance, keeping only the ability to swap
        // between approved venues on the leader's instruction.
        IAccessControl(vault).grantRole(0x00, vaultAdmin);
        IAccessControl(vault).grantRole(YieldVault(vault).RISK_COUNCIL_ROLE(), vaultAdmin);
        IAccessControl(vault).grantRole(YieldVault(vault).KEEPER_ROLE(), vaultAdmin);
        IAccessControl(vault).grantRole(
            YieldVault(vault).ADAPTER_SETTER_ROLE(), address(this)
        );

        // Keep ADAPTER_SETTER_ROLE, give up everything else. This contract
        // needs exactly one power over a launched vault — swapping the adapter
        // between allowlisted venues on the leader's instruction — and holding
        // DEFAULT_ADMIN_ROLE as well would leave it able to change the fee or
        // the fee recipient on every vault ever launched, with no function
        // that does so and no reason to be able to.
        IAccessControl(vault).renounceRole(0x00, address(this));

        launches.push(
            Launch({
                vault: vault,
                escrow: escrow,
                adapter: address(adapter),
                leader: msg.sender,
                asset: asset,
                bond: bond,
                createdAt: uint64(block.timestamp),
                bondReleased: false,
                bondSlashed: false
            })
        );
        uint256 id = launches.length; // 1-indexed
        launchIdOfVault[vault] = id;
        _launchesOfLeader[msg.sender].push(id);

        emit VaultLaunched(id, msg.sender, vault, escrow, address(adapter), target, bond, seedEscrow);
    }

    // ─── Leader actions ──────────────────────────────────────────────────────

    /// @notice Move the vault to a different approved venue.
    /// @dev This is the leader's actual job, and the reason the launcher keeps
    ///      `ADAPTER_SETTER_ROLE` rather than handing it over: the new adapter
    ///      is constructed here, against an allowlisted target, so a leader can
    ///      express an allocation view without ever being able to name the
    ///      contract that holds the money.
    function reallocate(uint256 launchId, address newTarget)
        external
        nonReentrant
        returns (address newAdapter)
    {
        Launch storage l = _launch(launchId);
        if (msg.sender != l.leader) revert NotLeader();
        if (!approvedTarget[newTarget]) revert TargetNotApproved(newTarget);
        if (IERC4626(newTarget).asset() != l.asset) revert AssetMismatch();

        address oldTarget = address(ERC4626YieldAdapter(l.adapter).target());

        ERC4626YieldAdapter adapter = new ERC4626YieldAdapter(l.asset, newTarget, address(this));
        adapter.grantRole(adapter.VAULT_ROLE(), l.vault);

        YieldVault(l.vault).setAdapter(address(adapter));
        l.adapter = address(adapter);
        newAdapter = address(adapter);

        emit Reallocated(launchId, oldTarget, newTarget, newAdapter);
    }

    // ─── Bond ────────────────────────────────────────────────────────────────

    /// @notice Forfeit a leader's bond to the treasury.
    /// @dev Governance-only and deliberately not automatic. There is no on-chain
    ///      test for "misconduct" that a market drawdown does not also trip, and
    ///      slashing a leader for beta would make bonding irrational.
    function slashBond(uint256 launchId, string calldata reason)
        external
        onlyRole(GOVERNANCE_ROLE)
    {
        Launch storage l = _launch(launchId);
        if (l.bondReleased || l.bondSlashed) revert BondAlreadyResolved();
        l.bondSlashed = true;
        if (l.bond > 0) zor.safeTransfer(protocolTreasury, l.bond);
        emit BondSlashed(launchId, l.bond, reason);
    }

    /// @notice Reclaim the bond once the vault holds no depositor money.
    function reclaimBond(uint256 launchId) external nonReentrant {
        Launch storage l = _launch(launchId);
        if (msg.sender != l.leader) revert NotLeader();
        if (l.bondReleased || l.bondSlashed) revert BondAlreadyResolved();

        uint256 remaining = YieldVault(l.vault).totalSupply();
        if (remaining != 0) revert VaultNotEmpty(remaining);

        l.bondReleased = true;
        if (l.bond > 0) zor.safeTransfer(l.leader, l.bond);
        emit BondReleased(launchId, l.bond);
    }

    // ─── Views for the leaderboard ───────────────────────────────────────────

    function launchCount() external view returns (uint256) {
        return launches.length;
    }

    function launchesOfLeader(address leader) external view returns (uint256[] memory) {
        return _launchesOfLeader[leader];
    }

    /// @notice Everything a leaderboard row needs, in one call.
    function vaultSummary(uint256 launchId)
        external
        view
        returns (
            address vault,
            address leader,
            uint256 totalAssets,
            uint256 escrowBalance,
            uint256 coverageBps,
            bool adequatelyCovered
        )
    {
        Launch storage l = _launch(launchId);
        FirstLossEscrow esc = FirstLossEscrow(l.escrow);
        return (
            l.vault,
            l.leader,
            YieldVault(l.vault).totalAssets(),
            esc.escrow(),
            esc.coverageRatioBps(),
            esc.coverageShortfall() == 0
        );
    }

    function _launch(uint256 launchId) internal view returns (Launch storage) {
        if (launchId == 0 || launchId > launches.length) revert UnknownVault();
        return launches[launchId - 1];
    }
}

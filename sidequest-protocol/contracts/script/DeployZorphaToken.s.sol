// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";

import {Zorpha} from "../src/Zorpha.sol";
import {ZorphaVesting} from "../src/ZorphaVesting.sol";
import {ZorphaBuyback} from "../src/ZorphaBuyback.sol";
import {ProtocolTreasury} from "../src/ProtocolTreasury.sol";
import {InsuranceFund} from "../src/InsuranceFund.sol";
import {MerkleDistributor} from "../src/MerkleDistributor.sol";
import {Timelock} from "../src/governance/Timelock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title DeployZorphaToken
/// @notice Token-layer deployment for $ZOR: token, timelock, treasury, buyback,
///         insurance fund, airdrop distributor and vesting vault — followed by
///         an ATOMIC distribution of the entire 1,000,000,000 supply and a full
///         handover of every privileged role to the governance Safe.
///
///         The previous pipeline left 100% of supply sitting in the deployer EOA
///         and left `ProtocolTreasury` / buyback owned by that same hot key,
///         which contradicted the access-control matrix in docs/SECURITY.md.
///         This script ends with three hard assertions:
///
///           1. the deployer holds exactly 0 ZOR;
///           2. the sum of all buckets equals MAX_SUPPLY;
///           3. no contract deployed here is still owned by the deployer.
///
///         Anything less and the run reverts rather than half-launching.
///
///         Split of responsibility. This script only performs the trustless
///         part of the distribution. Contributor and backer vesting schedules
///         contain real people's addresses and amounts, so they are NOT put in
///         a committed env file: the script forwards that tranche to the
///         governance Safe, which calls `ZorphaVesting.fund` itself. See
///         docs/RUNBOOK.md step 4.
contract DeployZorphaToken is Script {
    // ─── Published allocation (docs/TOKENOMICS.md) ──────────────────────────
    // Basis points of MAX_SUPPLY. Must sum to 10_000.
    uint256 internal constant BPS_COMMUNITY  = 3800; // 38% ecosystem + airdrop
    uint256 internal constant BPS_TREASURY   = 2000; // 20% DAO treasury
    uint256 internal constant BPS_CONTRIB    = 1700; // 17% core contributors
    uint256 internal constant BPS_LIQUIDITY  = 1300; // 13% protocol-owned liquidity
    uint256 internal constant BPS_BACKERS    =  800; //  8% early backers
    uint256 internal constant BPS_INSURANCE  =  400; //  4% insurance fund

    /// @dev Of the 38% community bucket, this much unlocks at TGE as the
    ///      Season 1 airdrop. The remainder is ecosystem emissions held by
    ///      governance and released per season.
    uint256 internal constant BPS_AIRDROP_TGE = 800; // 8% of supply

    struct Deployed {
        Zorpha zor;
        Timelock timelock;
        ProtocolTreasury treasury;
        ZorphaBuyback buyback;
        InsuranceFund insurance;
        MerkleDistributor distributor;
        ZorphaVesting vesting;
    }

    function run() external returns (Deployed memory d) {
        // PRIVATE_KEY is optional. When it is absent the run authenticates with
        // `--account <keystore>` (plus `--sender`), and forge resolves both the
        // signer and `msg.sender` from it -- verified by probe.
        //
        // A raw key means the deployer sits in an environment variable and in
        // shell history, which is how both keys in docs/BURNED-KEYS.md were
        // burned. A keystore is the only form that should ever touch mainnet, so
        // it must be the form these scripts support.
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", uint256(0));
        address deployer = deployerKey != 0 ? vm.addr(deployerKey) : msg.sender;
        require(deployer != address(0), "no deployer: set PRIVATE_KEY or use --account with --sender");

        // Governance Safe. Deliberately has no `deployer` fallback: launching
        // with governance pointed at a hot key is the failure this script
        // exists to prevent.
        address gov = vm.envAddress("GOVERNANCE");
        require(gov != address(0), "GOVERNANCE unset");
        require(gov != deployer, "GOVERNANCE must not be the deployer EOA");

        // Robinhood Chain's stablecoin is Paxos USDG, not USDC: the canonical
        // USDC addresses have no code on 4663. USDC_TOKEN is still honoured so
        // an in-flight runbook keeps working.
        address usdc = vm.envOr("USDG_TOKEN", address(0));
        if (usdc == address(0)) usdc = vm.envAddress("USDC_TOKEN");
        address liquidityRecipient = vm.envAddress("LIQUIDITY_RECIPIENT");
        bytes32 airdropRoot = vm.envBytes32("AIRDROP_MERKLE_ROOT");
        uint256 claimDeadline = vm.envUint("AIRDROP_CLAIM_DEADLINE");
        uint256 timelockDelay = vm.envOr("TIMELOCK_DELAY", uint256(48 hours));
        // BUYBACK_THRESHOLD_USDG, with the old USDC spelling still honoured so a
        // saved .env or an in-flight runbook does not break on the rename. Same
        // pattern as USDG_TOKEN / USDC_TOKEN in deploy-and-verify.sh.
        uint256 buybackThreshold = vm.envOr(
            "BUYBACK_THRESHOLD_USDG",
            vm.envOr("BUYBACK_THRESHOLD_USDC", uint256(1_000 * 1e6))
        );

        require(liquidityRecipient != address(0), "LIQUIDITY_RECIPIENT unset");
        require(airdropRoot != bytes32(0), "AIRDROP_MERKLE_ROOT unset");
        require(claimDeadline > block.timestamp, "AIRDROP_CLAIM_DEADLINE in the past");

        if (deployerKey != 0) {
            vm.startBroadcast(deployerKey);
        } else {
            vm.startBroadcast();
        }

        // ─── 1. Token. Full supply to the deployer, spent entirely below. ────
        d.zor = new Zorpha(deployer);
        uint256 supply = d.zor.MAX_SUPPLY();

        // ─── 2. Governance timelock. Safe proposes and executes; the Safe is
        //        also the timelock admin so it can rotate its own roles.
        address[] memory proposers = new address[](1);
        proposers[0] = gov;
        address[] memory executors = new address[](1);
        executors[0] = gov;
        d.timelock = new Timelock(timelockDelay, proposers, executors, gov);

        // ─── 3. Fee plumbing.
        //        Buyback and treasury are owned by the TIMELOCK, not the Safe
        //        directly and never the deployer, so changing the swap route or
        //        pulling fee revenue is a delayed, publicly visible action.
        d.buyback = new ZorphaBuyback(address(d.zor), usdc, buybackThreshold, address(d.timelock));
        d.insurance = new InsuranceFund(address(d.timelock));
        d.treasury = new ProtocolTreasury(address(d.buyback), gov);
        d.treasury.transferOwnership(address(d.timelock));

        // ─── 4. Airdrop distributor. Sweep authority is the timelock, so
        //        unclaimed supply cannot be pulled early or by one key.
        d.distributor = new MerkleDistributor(
            IERC20(address(d.zor)), airdropRoot, claimDeadline, address(d.timelock)
        );

        // ─── 5. Vesting vault. Admin is the Safe, which funds the real
        //        contributor and backer schedules post-deploy.
        d.vesting = new ZorphaVesting(address(d.zor), gov);

        // ─── 6. Atomic distribution of the entire supply. ────────────────────
        uint256 airdropAmount   = (supply * BPS_AIRDROP_TGE) / 10_000;
        uint256 liquidityAmount = (supply * BPS_LIQUIDITY)   / 10_000;
        uint256 insuranceAmount = (supply * BPS_INSURANCE)   / 10_000;

        // Everything still held by governance at the end of this tx: the
        // ecosystem emissions tail, the DAO treasury tranche, and the
        // contributor + backer tranche awaiting real vesting schedules.
        uint256 govAmount = supply - airdropAmount - liquidityAmount - insuranceAmount;

        d.zor.transfer(address(d.distributor), airdropAmount);
        d.zor.transfer(liquidityRecipient, liquidityAmount);
        d.zor.transfer(address(d.insurance), insuranceAmount);
        d.zor.transfer(gov, govAmount);

        vm.stopBroadcast();

        // ─── 7. Launch-blocking assertions. ─────────────────────────────────
        require(
            BPS_COMMUNITY + BPS_TREASURY + BPS_CONTRIB + BPS_LIQUIDITY + BPS_BACKERS
                + BPS_INSURANCE == 10_000,
            "allocation bps do not sum to 100%"
        );
        require(
            airdropAmount + liquidityAmount + insuranceAmount + govAmount == supply,
            "distribution does not sum to MAX_SUPPLY"
        );
        require(d.zor.balanceOf(deployer) == 0, "deployer still holds ZOR");
        require(d.zor.totalSupply() == supply, "supply drifted");
        require(d.treasury.pendingOwner() == address(d.timelock), "treasury handover missing");
        require(d.buyback.owner() == address(d.timelock), "buyback not timelocked");
        require(d.insurance.owner() == address(d.timelock), "insurance not timelocked");
        require(d.vesting.admin() == gov, "vesting admin wrong");

        _report(d, gov, airdropAmount, liquidityAmount, insuranceAmount, govAmount);
    }

    function _report(
        Deployed memory d,
        address gov,
        uint256 airdropAmount,
        uint256 liquidityAmount,
        uint256 insuranceAmount,
        uint256 govAmount
    ) internal pure {
        console2.log("=== Zorpha token layer deployed ===");
        console2.log("ZOR              ", address(d.zor));
        console2.log("Timelock         ", address(d.timelock));
        console2.log("Treasury         ", address(d.treasury));
        console2.log("Buyback          ", address(d.buyback));
        console2.log("InsuranceFund    ", address(d.insurance));
        console2.log("MerkleDistributor", address(d.distributor));
        console2.log("Vesting          ", address(d.vesting));
        console2.log("Governance Safe  ", gov);
        console2.log("--- distribution (wei) ---");
        console2.log("airdrop @ TGE    ", airdropAmount);
        console2.log("liquidity        ", liquidityAmount);
        console2.log("insurance        ", insuranceAmount);
        console2.log("governance held  ", govAmount);
        console2.log("");
        console2.log("ACTION REQUIRED: ProtocolTreasury ownership is a two-step");
        console2.log("transfer. The Timelock must queue acceptOwnership().");
        console2.log("ACTION REQUIRED: Safe must call ZorphaVesting.fund() with");
        console2.log("the real contributor + backer schedules (runbook step 4),");
        console2.log("and ZorphaBuyback.setRouter() once a ZOR route is live.");
    }
}

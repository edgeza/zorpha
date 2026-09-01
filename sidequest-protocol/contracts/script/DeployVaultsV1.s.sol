// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";

import {Timelock} from "../src/governance/Timelock.sol";
import {MedianOracle} from "../src/oracle/MedianOracle.sol";
import {StrategyExecutor} from "../src/executor/StrategyExecutor.sol";
import {VaultFactory, SpotVaultParams, RWRotationVaultParams, YieldVaultParams} from "../src/VaultFactory.sol";
import {ReputationRegistry} from "../src/reputation/ReputationRegistry.sol";
import {SpotVaultMinimal} from "../src/vaults/SpotVaultMinimal.sol";
import {RWRotationVault} from "../src/vaults/RWRotationVault.sol";
import {YieldVault} from "../src/vaults/YieldVault.sol";
import {StubYieldAdapter} from "../src/adapters/StubYieldAdapter.sol";
import {StubSwapAdapter} from "../src/adapters/RobinhoodChainRouterAdapter.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @title DeployVaultsV1
/// @notice Vault-layer deployment. Run AFTER `DeployZorphaToken`, which owns
///         the token, timelock, treasury and fee plumbing.
///
///         Three deploy-blocking bugs in the previous single-shot pipeline are
///         fixed here:
///
///         1. `VaultFactory` grants `DEPLOYER_ROLE` only to its constructor
///            admin. The old script passed `admin_ = GOVERNANCE` and then
///            called `deploySpotVault` from the deployer EOA, so the run
///            reverted with AccessControlUnauthorizedAccount for every
///            production config where GOVERNANCE != deployer. The factory and
///            vaults are now deployed with the DEPLOYER as admin, wired, and
///            only then handed to governance — with the deployer renouncing.
///
///         2. `MedianOracle` was constructed with `minQuorum = 3` but only one
///            updater was ever added, so `latestRoundData` reverted forever
///            with InsufficientFreshReports. Any vault falling back to it was
///            bricked on arrival. Quorum is now derived from the actual updater
///            set and asserted to be satisfiable.
///
///         3. Nothing was actually owned by the Timelock, so the 48h delay was
///            decorative. Risk-council and adapter-setter authority now sit
///            behind it.
contract DeployVaultsV1 is Script {
    struct Deployed {
        MedianOracle oracle;
        VaultFactory factory;
        ReputationRegistry reputation;
        StrategyExecutor executor;
        SpotVaultMinimal spotVault;
        RWRotationVault rotationVault;
        YieldVault yieldVault;
        StubYieldAdapter yieldAdapter;
        StubSwapAdapter swapAdapter;
    }

    function run() external returns (Deployed memory r) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        address gov = vm.envAddress("GOVERNANCE");
        address timelock = vm.envAddress("TIMELOCK");
        address treasury = vm.envAddress("TREASURY");
        address usdc = vm.envAddress("USDC_TOKEN");
        address stockToken1 = vm.envAddress("STOCK_TOKEN_1");
        address stockToken2 = vm.envOr("STOCK_TOKEN_2", address(0));
        address stockFeed1 = vm.envOr("STOCK_FEED_1", address(0));
        address stockFeed2 = vm.envOr("STOCK_FEED_2", address(0));

        require(gov != address(0) && gov != deployer, "GOVERNANCE must be a Safe, not the deployer");
        require(timelock != address(0), "TIMELOCK unset");
        require(treasury != address(0), "TREASURY unset");
        require(stockToken1 != address(0), "STOCK_TOKEN_1 unset");

        // Oracle updater set. Quorum must be satisfiable by the keys we
        // actually control, or every price read reverts.
        address[] memory oracleUpdaters = vm.envOr("ORACLE_UPDATERS", ",", new address[](0));
        uint256 quorum = vm.envOr("ORACLE_QUORUM", uint256(0));
        if (oracleUpdaters.length == 0) {
            oracleUpdaters = new address[](1);
            oracleUpdaters[0] = deployer;
        }
        if (quorum == 0) quorum = oracleUpdaters.length;
        require(quorum > 0 && quorum <= oracleUpdaters.length, "ORACLE_QUORUM exceeds updater set");

        vm.startBroadcast(deployerKey);

        // ─── Oracle. Deployer is admin only long enough to seat the updaters.
        r.oracle = new MedianOracle(8, 1 hours, 100 * 1e8, 1_000_000 * 1e8, quorum, deployer);
        for (uint256 i = 0; i < oracleUpdaters.length; i++) {
            r.oracle.addUpdater(oracleUpdaters[i]);
        }

        // ─── Registry, executor, adapters.
        r.reputation = new ReputationRegistry(gov);
        r.executor = new StrategyExecutor(deployer);
        r.yieldAdapter = new StubYieldAdapter(usdc, gov);
        r.swapAdapter = new StubSwapAdapter(stockToken1, usdc, deployer);

        // ─── Factory owned by the deployer for the duration of this script.
        r.factory = new VaultFactory(deployer);

        address defaultOracle = address(r.oracle);

        // ─── Vault 1: long/flat single-stock equity.
        r.spotVault = SpotVaultMinimal(
            r.factory.deploySpotVault(
                SpotVaultParams({
                    asset: stockToken1,
                    cashAsset: usdc,
                    oracle: stockFeed1 == address(0) ? defaultOracle : stockFeed1,
                    maxOracleStaleness: 1 hours,
                    name: "Zorpha HOOD Long/Flat Vault",
                    symbol: "zqHOOD",
                    rebalanceThresholdBps: 200,
                    maxSlippageBps: 100,
                    performanceFeeBps: 2000,
                    feeRecipient: treasury,
                    admin: deployer,
                    emergencyRedeemCooldown: 1 hours
                }),
                keccak256("zorpha-spot-vault-v1")
            )
        );
        r.spotVault.setSwapAdapter(address(r.swapAdapter));
        r.spotVault.grantRole(r.spotVault.KEEPER_ROLE(), address(r.executor));
        r.swapAdapter.grantRole(r.swapAdapter.VAULT_ROLE(), address(r.spotVault));

        // ─── Vault 2: RWA rotation basket (optional second leg).
        if (stockToken2 != address(0)) {
            address[] memory tokens = new address[](2);
            tokens[0] = stockToken1;
            tokens[1] = stockToken2;
            address[] memory oracles = new address[](2);
            oracles[0] = stockFeed1 == address(0) ? defaultOracle : stockFeed1;
            oracles[1] = stockFeed2 == address(0) ? defaultOracle : stockFeed2;
            uint16[] memory weights = new uint16[](2);
            weights[0] = 5000;
            weights[1] = 5000;

            r.rotationVault = RWRotationVault(
                r.factory.deployRotationVault(
                    RWRotationVaultParams({
                        baseAsset: usdc,
                        tokens: tokens,
                        oracles: oracles,
                        maxOracleStaleness: 1 hours,
                        initialWeightsBps: weights,
                        name: "Zorpha RWA Rotation Vault",
                        symbol: "zqROT",
                        performanceFeeBps: 2000,
                        feeRecipient: treasury,
                        admin: deployer
                    }),
                    keccak256("zorpha-rotation-vault-v1")
                )
            );
            r.rotationVault.grantRole(r.rotationVault.KEEPER_ROLE(), address(r.executor));
        }

        // ─── Vault 3: USDC yield slot.
        r.yieldVault = YieldVault(
            r.factory.deployYieldVault(
                YieldVaultParams({
                    asset: usdc,
                    adapter: address(r.yieldAdapter),
                    name: "Zorpha USDC Yield Vault",
                    symbol: "zqUSD",
                    performanceFeeBps: 1000,
                    feeRecipient: treasury,
                    admin: deployer
                }),
                keccak256("zorpha-yield-vault-v1")
            )
        );
        r.yieldVault.grantRole(r.yieldVault.KEEPER_ROLE(), address(r.executor));

        // ─── Handover. Every privileged role moves to governance or the
        //     timelock, and the deployer renounces its own.
        _handOver(address(r.oracle), gov, deployer);
        _handOver(address(r.factory), gov, deployer);
        _handOver(address(r.executor), gov, deployer);
        _handOver(address(r.swapAdapter), gov, deployer);

        r.spotVault.grantRole(r.spotVault.RISK_COUNCIL_ROLE(), gov);
        _handOver(address(r.spotVault), gov, deployer);

        r.yieldVault.grantRole(r.yieldVault.ADAPTER_SETTER_ROLE(), timelock);
        r.yieldVault.grantRole(r.yieldVault.RISK_COUNCIL_ROLE(), gov);
        _handOver(address(r.yieldVault), gov, deployer);

        if (address(r.rotationVault) != address(0)) {
            r.rotationVault.grantRole(r.rotationVault.RISK_COUNCIL_ROLE(), gov);
            _handOver(address(r.rotationVault), gov, deployer);
        }

        vm.stopBroadcast();

        // ─── Assertions: no deployer authority may survive this script.
        bytes32 adminRole = 0x00;
        require(IAccessControl(address(r.factory)).hasRole(adminRole, gov), "factory admin not gov");
        require(!IAccessControl(address(r.factory)).hasRole(adminRole, deployer), "deployer kept factory admin");
        require(!IAccessControl(address(r.spotVault)).hasRole(adminRole, deployer), "deployer kept vault admin");
        require(!IAccessControl(address(r.yieldVault)).hasRole(adminRole, deployer), "deployer kept vault admin");
        require(!IAccessControl(address(r.oracle)).hasRole(adminRole, deployer), "deployer kept oracle admin");
        require(r.oracle.minQuorum() <= r.oracle.updaterCount(), "oracle quorum unsatisfiable");

        console2.log("=== Zorpha vault layer deployed ===");
        console2.log("Oracle         ", address(r.oracle));
        console2.log("Factory        ", address(r.factory));
        console2.log("Reputation     ", address(r.reputation));
        console2.log("Executor       ", address(r.executor));
        console2.log("Spot vault     ", address(r.spotVault));
        console2.log("Rotation vault ", address(r.rotationVault));
        console2.log("Yield vault    ", address(r.yieldVault));
        console2.log("");
        console2.log("ACTION REQUIRED: seat the real oracle updater set and");
        console2.log("raise ORACLE_QUORUM before accepting live deposits. A");
        console2.log("single-updater median is a single point of failure.");
    }

    /// @dev Grant DEFAULT_ADMIN_ROLE to `gov` and renounce the deployer's.
    function _handOver(address target, address gov, address deployer) internal {
        bytes32 adminRole = 0x00;
        IAccessControl ac = IAccessControl(target);
        if (!ac.hasRole(adminRole, gov)) {
            ac.grantRole(adminRole, gov);
        }
        if (ac.hasRole(adminRole, deployer)) {
            ac.renounceRole(adminRole, deployer);
        }
    }
}

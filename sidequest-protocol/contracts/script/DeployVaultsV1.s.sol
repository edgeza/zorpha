// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";

import {Timelock} from "../src/governance/Timelock.sol";
import {MedianOracle} from "../src/oracle/MedianOracle.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {MainnetSafety} from "../src/lib/MainnetSafety.sol";
import {StrategyExecutor} from "../src/executor/StrategyExecutor.sol";
import {VaultFactory, SpotVaultParams, RWRotationVaultParams, YieldVaultParams} from "../src/VaultFactory.sol";
import {ReputationRegistry} from "../src/reputation/ReputationRegistry.sol";
import {SpotVaultMinimal} from "../src/vaults/SpotVaultMinimal.sol";
import {RWRotationVault} from "../src/vaults/RWRotationVault.sol";
import {YieldVault} from "../src/vaults/YieldVault.sol";
import {StubYieldAdapter} from "../src/adapters/StubYieldAdapter.sol";
import {StubSwapAdapter, RobinhoodChainRouterAdapter} from "../src/adapters/RobinhoodChainRouterAdapter.sol";
import {ERC4626YieldAdapter} from "../src/adapters/ERC4626YieldAdapter.sol";
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
        address yieldAdapter;
        address swapAdapter;
        bool yieldIsReal;
        bool swapIsReal;
    }

    function run() external returns (Deployed memory r) {
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

        address gov = vm.envAddress("GOVERNANCE");
        address timelock = vm.envAddress("TIMELOCK");
        address treasury = vm.envAddress("TREASURY");
        // Robinhood Chain's stablecoin is Paxos USDG, not USDC: the canonical
        // USDC addresses have no code on 4663. USDC_TOKEN is still honoured so
        // an in-flight runbook keeps working.
        address usdc = vm.envOr("USDG_TOKEN", address(0));
        if (usdc == address(0)) usdc = vm.envAddress("USDC_TOKEN");

        // Optional venues. Set on mainnet, left unset on testnet, where none of
        // this is deployed and the stubs stand in instead.
        address yieldTarget = vm.envOr("YIELD_TARGET", address(0));
        address swapRouter = vm.envOr("SWAP_ROUTER", address(0));
        uint24 swapFeeTier = uint24(vm.envOr("SWAP_FEE_TIER", uint256(500)));

        // Who may submit a signed rebalance, and who may pull the pause.
        // Default to governance so a deploy is never left with these unseated;
        // on mainnet these should be a keeper bot and a guardian multisig, not
        // the Safe doing both jobs.
        address keeper = vm.envOr("KEEPER", gov);
        address guardian = vm.envOr("GUARDIAN", gov);
        // Rebalances per vault per rolling 24h. Zero disables the limit
        // entirely -- `if (limit > 0)` in the executor -- so it must not be
        // the default.
        uint256 dailyLimit = vm.envOr("DAILY_REBALANCE_LIMIT", uint256(4));
        require(dailyLimit > 0, "DAILY_REBALANCE_LIMIT of 0 disables the rate limit");

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

        // The deployer must not be an oracle updater, and the default above
        // makes it one -- which produces a DEAD oracle.
        //
        // `_handOver` renounces every role in `_allRoles()` from the deployer,
        // and UPDATER_ROLE is in that list. `addUpdater` has already pushed the
        // address into the `updaters` array by then, and nothing removes it. So
        // the oracle ends up with an array entry that holds no role: it can
        // never report, `latestRoundData` can never reach quorum, and every
        // vault reverts on its first NAV read.
        //
        // Before the deploy-time role assertion further down, that shipped as a
        // successful deploy. Refusing here instead names the cause, because
        // "a seated oracle updater does not hold UPDATER_ROLE" does not explain
        // that the fix is to set ORACLE_UPDATERS to something other than the
        // key you are deploying with. See docs/FINDINGS-ORACLE-REVOCATION.md
        // for the array-versus-role divergence this is one instance of.
        for (uint256 i = 0; i < oracleUpdaters.length; i++) {
            require(
                oracleUpdaters[i] != deployer,
                "ORACLE_UPDATERS contains the deployer, whose roles are renounced at handover -- set it to the governance address or a keeper"
            );
        }

        if (deployerKey != 0) {
            vm.startBroadcast(deployerKey);
        } else {
            vm.startBroadcast();
        }

        // ─── Oracle. Deployer is admin only long enough to seat the updaters.
        r.oracle = new MedianOracle(8, 1 hours, 100 * 1e8, 1_000_000 * 1e8, quorum, deployer);
        for (uint256 i = 0; i < oracleUpdaters.length; i++) {
            r.oracle.addUpdater(oracleUpdaters[i]);
        }

        // ─── Registry, executor, adapters.
        r.reputation = new ReputationRegistry(gov);
        r.executor = new StrategyExecutor(deployer);

        // ─── Yield adapter ──────────────────────────────────────────────────
        // With a target set, deposits route into a real ERC-4626 vault and the
        // yield vault earns something. Without one it falls back to the stub,
        // whose own comment concedes "zero yield, zero risk" -- fine for
        // exercising accounting on testnet, not a product.
        if (yieldTarget != address(0)) {
            r.yieldAdapter = address(new ERC4626YieldAdapter(usdc, yieldTarget, deployer));
            r.yieldIsReal = true;
        } else {
            r.yieldAdapter = address(new StubYieldAdapter(usdc, gov));
        }

        // ─── Swap adapter ───────────────────────────────────────────────────
        // The stub swaps 1:1 ignoring price and decimals. That is survivable on
        // a testnet with mock tokens and catastrophic anywhere else, which is
        // why the real router is used the moment one is configured.
        if (swapRouter != address(0)) {
            r.swapAdapter = address(
                new RobinhoodChainRouterAdapter(swapRouter, stockToken1, usdc, swapFeeTier, deployer)
            );
            r.swapIsReal = true;
        } else {
            // The stub now prices off the same oracle the vault uses, so a
            // rebalance settles at a sane value instead of 1:1 on raw units.
            // It is still not a market -- zero slippage, unbounded depth, pays
            // out of its own balance -- so it must be pre-funded.
            r.swapAdapter = address(
                new StubSwapAdapter(stockToken1, usdc, address(r.oracle), deployer)
            );
        }

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
                    name: string.concat("Zorpha ", _symbolOf(stockToken1), " Long/Flat Vault"),
                    symbol: string.concat("zq", _symbolOf(stockToken1)),
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
        r.spotVault.setSwapAdapter(r.swapAdapter);
        r.spotVault.grantRole(r.spotVault.KEEPER_ROLE(), address(r.executor));
        IAccessControl(r.swapAdapter).grantRole(keccak256("VAULT_ROLE"), address(r.spotVault));

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
                        // A basket has no single asset to take a name from,
                        // so this one names the unit it is measured in
                        // rather than any one holding.
                        name: string.concat("Zorpha Rotation Vault (", _symbolOf(usdc), " base)"),
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

        // ─── Vault 3: stable yield slot.
        r.yieldVault = YieldVault(
            r.factory.deployYieldVault(
                YieldVaultParams({
                    asset: usdc,
                    adapter: r.yieldAdapter,
                    name: string.concat("Zorpha ", _symbolOf(usdc), " Yield Vault"),
                    symbol: string.concat("zq", _symbolOf(usdc)),
                    performanceFeeBps: 1000,
                    feeRecipient: treasury,
                    admin: deployer
                }),
                keccak256("zorpha-yield-vault-v1")
            )
        );
        r.yieldVault.grantRole(r.yieldVault.KEEPER_ROLE(), address(r.executor));

        // ERC4626YieldAdapter gates deposit/withdraw on VAULT_ROLE, which the
        // stub never did. Granted after the vault exists, since the factory
        // creates it and its address is not known before that.
        if (r.yieldIsReal) {
            IAccessControl(r.yieldAdapter).grantRole(keccak256("VAULT_ROLE"), address(r.yieldVault));
        }

        // ─── Handover. Every privileged role moves to governance or the
        //     timelock, and the deployer renounces its own.
        _handOver(address(r.oracle), gov, deployer);
        _handOver(address(r.factory), gov, deployer);
        // Seat the executor's own roles BEFORE handing it over, or nothing
        // can ever be granted again without a governance transaction.
        //
        // This was missing entirely. The deploy granted KEEPER_ROLE on each
        // VAULT to the executor -- so the executor could drive the vaults --
        // and never granted KEEPER_ROLE on the EXECUTOR to anybody, so
        // executeRebalance was callable by nobody and the spot and rotation
        // vaults shipped frozen. GUARDIAN_ROLE was unseated the same way,
        // which meant the emergency pause existed and could not be pulled.
        // Found on testnet 46630 after the fact; see the assertions below.
        r.executor.grantRole(r.executor.KEEPER_ROLE(), keeper);
        r.executor.grantRole(r.executor.GUARDIAN_ROLE(), guardian);

        // And give the rate limit a value, because 0 means "no limit".
        r.executor.setDailyLimit(address(r.spotVault), dailyLimit);
        r.executor.setDailyLimit(address(r.yieldVault), dailyLimit);
        if (address(r.rotationVault) != address(0)) {
            r.executor.setDailyLimit(address(r.rotationVault), dailyLimit);
        }

        _handOver(address(r.executor), gov, deployer);
        _handOver(r.swapAdapter, gov, deployer);
        if (r.yieldIsReal) _handOver(r.yieldAdapter, gov, deployer);

        r.spotVault.grantRole(r.spotVault.RISK_COUNCIL_ROLE(), gov);
        r.spotVault.grantRole(r.spotVault.KEEPER_ROLE(), gov);
        _handOverVault(address(r.spotVault), timelock, gov, deployer);

        r.yieldVault.grantRole(r.yieldVault.ADAPTER_SETTER_ROLE(), timelock);
        r.yieldVault.grantRole(r.yieldVault.RISK_COUNCIL_ROLE(), gov);
        r.yieldVault.grantRole(r.yieldVault.KEEPER_ROLE(), gov);
        _handOverVault(address(r.yieldVault), timelock, gov, deployer);

        if (address(r.rotationVault) != address(0)) {
            r.rotationVault.grantRole(r.rotationVault.RISK_COUNCIL_ROLE(), gov);
            r.rotationVault.grantRole(r.rotationVault.KEEPER_ROLE(), gov);
            _handOverVault(address(r.rotationVault), timelock, gov, deployer);
        }

        vm.stopBroadcast();

        // ─── Assertions: no deployer authority may survive this script.
        //
        // Checked against every role, not just DEFAULT_ADMIN_ROLE. The earlier
        // version of this block checked admin alone and therefore passed while
        // the deploy key kept DEPLOYER_ROLE on the factory -- which is exactly
        // the authority that matters there, since it is what deployYieldVault
        // is gated on.
        bytes32 adminRole = 0x00;
        require(IAccessControl(address(r.factory)).hasRole(adminRole, gov), "factory admin not gov");
        _assertStripped(address(r.factory), deployer, "factory");
        _assertStripped(address(r.spotVault), deployer, "spot vault");
        _assertStripped(address(r.yieldVault), deployer, "yield vault");
        _assertStripped(address(r.oracle), deployer, "oracle");
        _assertStripped(address(r.reputation), deployer, "reputation registry");
        if (address(r.rotationVault) != address(0)) {
            _assertStripped(address(r.rotationVault), deployer, "rotation vault");
        }
        require(r.oracle.minQuorum() <= r.oracle.updaterCount(), "oracle quorum unsatisfiable");

        // `updaterCount()` is `updaters.length`, which is NOT the number of
        // addresses holding UPDATER_ROLE -- the two can diverge, and did on
        // testnet the moment someone retired an updater with `revokeRole`
        // instead of `removeUpdater`. `latestRoundData` iterates the array and
        // never checks the role, so an array slot without the role still
        // contributes a stale price, and a slot with neither is a phantom that
        // inflates the count a launch gate reads.
        //
        // Deploy time is the one moment both facts are known, so assert they
        // agree here: every seated updater holds the role, and there are no
        // extra slots. See docs/FINDINGS-ORACLE-REVOCATION.md.
        require(
            r.oracle.updaterCount() == oracleUpdaters.length,
            "oracle updater array does not match the seated list"
        );
        for (uint256 i = 0; i < oracleUpdaters.length; i++) {
            require(
                r.oracle.hasRole(r.oracle.UPDATER_ROLE(), oracleUpdaters[i]),
                "a seated oracle updater does not hold UPDATER_ROLE"
            );
        }

        // Testnet scaffolding must not reach mainnet. The three conditions and
        // the reasoning live in `MainnetSafety`, as a library so a test can
        // exercise the real check rather than a copy of it -- see
        // test/lib/MainnetSafety.t.sol. Until now these were guarded only by
        // the console warnings printed below, which arrive after the
        // transactions have landed.
        MainnetSafety.check(
            block.chainid,
            r.swapIsReal,
            r.yieldIsReal,
            r.oracle.updaterCount(),
            r.oracle.minQuorum()
        );

        // A role nobody holds is a feature that does not exist. These four
        // assertions are the ones whose absence let the executor ship inert.
        require(
            IAccessControl(address(r.executor)).hasRole(r.executor.KEEPER_ROLE(), keeper),
            "nobody can submit a rebalance"
        );
        require(
            IAccessControl(address(r.executor)).hasRole(r.executor.GUARDIAN_ROLE(), guardian),
            "nobody can pull the pause"
        );
        require(r.executor.dailyLimit(address(r.spotVault)) > 0, "spot vault has no rate limit");
        require(r.executor.dailyLimit(address(r.yieldVault)) > 0, "yield vault has no rate limit");

        console2.log("=== Zorpha vault layer deployed ===");
        console2.log("Oracle         ", address(r.oracle));
        console2.log("Factory        ", address(r.factory));
        console2.log("Reputation     ", address(r.reputation));
        console2.log("Executor       ", address(r.executor));
        console2.log("Spot vault     ", address(r.spotVault));
        console2.log("Rotation vault ", address(r.rotationVault));
        console2.log("Yield vault    ", address(r.yieldVault));
        console2.log("Yield adapter  ", r.yieldAdapter);
        console2.log("Swap adapter   ", r.swapAdapter);
        console2.log("");
        if (!r.yieldIsReal) {
            console2.log("WARNING: yield adapter is the STUB. The yield vault");
            console2.log("earns exactly nothing. Set YIELD_TARGET to a real");
            console2.log("ERC-4626 vault before this holds anyone's money.");
        }
        if (!r.swapIsReal) {
            console2.log("WARNING: swap adapter is the STUB. It swaps 1:1");
            console2.log("ignoring price and decimals, and must be pre-funded.");
            console2.log("Set SWAP_ROUTER before this touches real assets.");
        }
        console2.log("");
        console2.log("ACTION REQUIRED: seat the real oracle updater set and");
        console2.log("raise ORACLE_QUORUM before accepting live deposits. A");
        console2.log("single-updater median is a single point of failure.");
    }

    /// @dev Every role the protocol defines, so a handover can be checked
    ///      against all of them rather than against the one that was
    ///      remembered.
    ///
    ///      This list existing at all is the fix for a real gap. `_handOver`
    ///      used to renounce DEFAULT_ADMIN_ROLE and nothing else, and the
    ///      assertions below only checked DEFAULT_ADMIN_ROLE -- so the deploy
    ///      key kept DEPLOYER_ROLE on the VaultFactory through a run that
    ///      asserted "no deployer authority may survive this script" and
    ///      passed. On testnet 46630 the compromised deploy key could still
    ///      call deployYieldVault months later. See docs/BURNED-KEYS.md.
    ///      Solidity cannot grep, so unlike the shell checkers this list is
    ///      literal and has to be kept in step with src/. Verify it with:
    ///        grep -rhoE 'keccak256\("[A-Z_]+"\)' src | sort -u
    ///      The first version of this list invented ORACLE_UPDATER_ROLE, which
    ///      does not exist -- the real name is UPDATER_ROLE -- and omitted
    ///      SWEEPER_ROLE, GUARDIAN_ROLE and VAULT_ROLE. A wrong entry is
    ///      harmless (renounceRole on a role you do not hold is a no-op) but a
    ///      MISSING one is the whole bug this function exists to prevent.
    /// @dev Read a token's own symbol, for naming a vault after what it holds.
    ///
    ///      Names used to be hardcoded, and drifted from reality immediately.
    ///      The vault deployed to testnet 46630 is called
    ///      "Zorpha HOOD Long/Flat Vault" and holds "Test Apple" (tAAPL) --
    ///      the wrong company -- while the yield vault is
    ///      "Zorpha USDC Yield Vault" holding tUSDG, on a chain that has no
    ///      canonical USDC deployment at all.
    ///
    ///      Deriving the name means it cannot disagree with the asset, whatever
    ///      STOCK_TOKEN_1 and USDG_TOKEN are set to. It also takes the host
    ///      chain operator's own ticker out of a product name, which is a
    ///      trademark question rather than an engineering one.
    function _symbolOf(address token) internal view returns (string memory) {
        return IERC20Metadata(token).symbol();
    }

    function _allRoles() internal pure returns (bytes32[10] memory) {
        return [
            bytes32(0x00), // DEFAULT_ADMIN_ROLE
            keccak256("ADAPTER_SETTER_ROLE"),
            keccak256("DEPLOYER_ROLE"),
            keccak256("GOVERNANCE_ROLE"),
            keccak256("GUARDIAN_ROLE"),
            keccak256("KEEPER_ROLE"),
            keccak256("RISK_COUNCIL_ROLE"),
            keccak256("SWEEPER_ROLE"),
            keccak256("UPDATER_ROLE"),
            keccak256("VAULT_ROLE")
        ];
    }

    /// @dev Hand `target` to `gov` and strip the deployer of everything.
    ///
    ///      Admin first, so governance can always recover, then renounce every
    ///      role the deployer holds. `renounceRole` on a role the caller does
    ///      not hold is a no-op in OpenZeppelin's implementation, so the loop
    ///      is safe against contracts that define only some of these.
    /// @dev Hand a VAULT to the timelock as admin, leaving `gov` only the roles
    ///      that must act without delay, and strip the deployer.
    ///
    ///      Why this exists, and why it is not `_handOver`:
    ///
    ///      OpenZeppelin's AccessControl makes DEFAULT_ADMIN_ROLE the admin of
    ///      every role unless told otherwise. So a `gov` holding
    ///      DEFAULT_ADMIN_ROLE can grant itself ANY role on the contract --
    ///      including `ADAPTER_SETTER_ROLE`, which the deploy hands to the
    ///      timelock specifically so that repointing where depositor funds are
    ///      held takes 48 hours.
    ///
    ///      Verified against the live testnet deployment by simulation:
    ///      `grantRole(ADAPTER_SETTER_ROLE, gov)` from gov SUCCEEDS. Two
    ///      transactions and the delay is gone. So the delay was advisory --
    ///      it documented an intent the roles did not enforce, which is worse
    ///      than no delay at all, because the code read as though depositors
    ///      had a 48h window to exit ahead of a venue change and they did not.
    ///
    ///      The leadership layer already had this right: VaultLauncher gives
    ///      launched vaults DEFAULT_ADMIN to the timelock and keeps only
    ///      ADAPTER_SETTER_ROLE for itself, so gov holds nothing it could
    ///      escalate from. This brings the factory vaults to the same standard.
    ///
    ///      `gov` keeps RISK_COUNCIL_ROLE and KEEPER_ROLE, which is deliberate:
    ///      the circuit breaker has to be pullable in one block. What gov loses
    ///      is the DEFAULT_ADMIN set -- claimFees, setFeeRecipient,
    ///      setSwapAdapter, setFirstLossEscrow, writeDownAccruedFees. None of
    ///      those is an emergency, and every one of them either moves money or
    ///      moves the pointer to where money lives.
    function _handOverVault(address target, address timelock, address gov, address deployer)
        internal
    {
        bytes32 adminRole = 0x00;
        IAccessControl ac = IAccessControl(target);

        if (!ac.hasRole(adminRole, timelock)) ac.grantRole(adminRole, timelock);

        // Strip gov of admin if an earlier step or an earlier deploy gave it.
        if (ac.hasRole(adminRole, gov)) ac.revokeRole(adminRole, gov);

        bytes32[10] memory roles = _allRoles();
        for (uint256 i = 0; i < roles.length; i++) {
            uint256 j = roles.length - 1 - i;
            if (ac.hasRole(roles[j], deployer)) ac.renounceRole(roles[j], deployer);
        }

        // The assertions are the point. A handover that silently half-applied
        // would leave exactly the state this function exists to prevent.
        require(ac.hasRole(adminRole, timelock), "handover: timelock is not admin");
        require(!ac.hasRole(adminRole, gov), "handover: gov still admin, can self-grant");
        require(!ac.hasRole(adminRole, deployer), "handover: deployer still admin");
    }

    function _handOver(address target, address gov, address deployer) internal {
        bytes32 adminRole = 0x00;
        IAccessControl ac = IAccessControl(target);
        if (!ac.hasRole(adminRole, gov)) {
            ac.grantRole(adminRole, gov);
        }
        bytes32[10] memory roles = _allRoles();
        for (uint256 i = 0; i < roles.length; i++) {
            // Admin last: renouncing it first would forfeit the right to
            // renounce the others on a contract where admin gates them.
            uint256 j = roles.length - 1 - i;
            if (ac.hasRole(roles[j], deployer)) {
                ac.renounceRole(roles[j], deployer);
            }
        }
    }

    /// @dev Assert the deployer holds no role at all on `target`.
    function _assertStripped(address target, address deployer, string memory what) internal view {
        bytes32[10] memory roles = _allRoles();
        for (uint256 i = 0; i < roles.length; i++) {
            require(
                !IAccessControl(target).hasRole(roles[i], deployer),
                string.concat("deployer kept a role on ", what)
            );
        }
    }
}

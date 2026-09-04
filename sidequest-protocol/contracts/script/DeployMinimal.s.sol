// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {VaultLauncher} from "../src/leadership/VaultLauncher.sol";

/// @title DeployMinimal
/// @notice The launchpad, without the oracle.
///
///         WHY THIS EXISTS
///
///         DeployVaultsV1 builds everything at once: a spot vault over a
///         tokenised equity, a rotation vault, a yield vault, a MedianOracle, a
///         swap adapter and a StrategyExecutor. The oracle is the expensive
///         part, and not in gas. It has an immutable 3600s staleness window, so
///         a report must land every hour or every priced read reverts -- and at
///         a quorum of two that is two independent posters, hourly, forever.
///         Measured at 48,001 gas a report, that is a recurring cost in the tens
///         of thousands of dollars a year before anybody has deposited anything.
///
///         None of it is needed for the launchpad. YieldVault does not mention
///         an oracle once: it values itself as rawAssets() + escrowSupport(),
///         both read from the venue and the escrow directly. And
///         launchYieldVault is the ONLY launch function, so a leader could never
///         create a vault that needed a price feed even if they wanted to.
///
///         So this script deploys the part that works without one:
///
///             VaultFactory     the CREATE2 deployer
///             VaultLauncher    the permissionless launch path, bonded
///             + the DEPLOYER_ROLE grant that makes them work together
///
///         and nothing else. No oracle, no updaters, no swap adapter, no trading
///         windows, no executor. The equity vaults can be added later against
///         this same token and this same factory, without redeploying either.
///
///         It is also the only part already proven against live mainnet: the
///         fork suite round-trips real Steakhouse USDG, launches a vault on it
///         as a stranger, and shows a leader absorbing a real loss first.
///
///         THE GRANT IS THE POINT
///
///         DeployLeadership ends by printing ACTION REQUIRED: grant DEPLOYER_ROLE
///         on the factory to the launcher, by hand, from whoever holds factory
///         admin. Until that lands, launchYieldVault reverts and the launchpad
///         is inert while every contract in it reads as deployed. A manual step
///         between "deployed" and "works" is a step that gets skipped, so this
///         script does it in-band and asserts it.
contract DeployMinimal is Script {
    function run() external returns (VaultFactory factory, VaultLauncher launcher) {
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", uint256(0));
        address deployer = deployerKey != 0 ? vm.addr(deployerKey) : msg.sender;

        address gov = vm.envAddress("GOVERNANCE");
        address treasury = vm.envAddress("TREASURY");
        address timelock = vm.envAddress("TIMELOCK");
        address zor = vm.envAddress("ZOR_TOKEN");

        require(gov != address(0) && gov != deployer, "GOVERNANCE must be a Safe, not the deployer");
        require(treasury != address(0), "TREASURY unset");
        require(timelock != address(0), "TIMELOCK unset");
        require(zor != address(0), "ZOR_TOKEN unset");

        // Venues a leader may allocate to. Everything else is refused, which is
        // the difference between permissionless and a one-transaction drain.
        address[] memory targets = vm.envOr("APPROVED_YIELD_TARGETS", ",", new address[](0));
        require(targets.length > 0, "APPROVED_YIELD_TARGETS is empty: nobody could launch anything");

        if (deployerKey != 0) vm.startBroadcast(deployerKey);
        else vm.startBroadcast();

        factory = new VaultFactory(deployer);

        // Vault admin is the TIMELOCK, never governance directly and never the
        // leader: privileged changes to someone else vault should be visible for
        // 48 hours before they land.
        launcher = new VaultLauncher(zor, address(factory), treasury, timelock, deployer);

        for (uint256 i = 0; i < targets.length; i++) {
            require(IERC4626(targets[i]).asset() != address(0), "target is not ERC-4626");
            launcher.setTargetApproved(targets[i], true);
        }

        // In-band, not printed as a to-do.
        factory.grantRole(factory.DEPLOYER_ROLE(), address(launcher));

        // Hand both over and step away.
        launcher.grantRole(0x00, gov);
        launcher.grantRole(launcher.GOVERNANCE_ROLE(), gov);
        launcher.renounceRole(launcher.GOVERNANCE_ROLE(), deployer);
        launcher.renounceRole(0x00, deployer);

        factory.grantRole(0x00, timelock);
        factory.renounceRole(factory.DEPLOYER_ROLE(), deployer);
        factory.renounceRole(0x00, deployer);

        vm.stopBroadcast();

        // The assertions are the deliverable. A handover that half-applied would
        // leave exactly the state this script exists to avoid.
        require(
            IAccessControl(address(factory)).hasRole(factory.DEPLOYER_ROLE(), address(launcher)),
            "launcher cannot deploy vaults: the launchpad would be inert"
        );
        require(!IAccessControl(address(factory)).hasRole(0x00, deployer), "deployer kept factory admin");
        require(IAccessControl(address(factory)).hasRole(0x00, timelock), "timelock is not factory admin");
        require(!IAccessControl(address(launcher)).hasRole(0x00, deployer), "deployer kept launcher admin");
        require(IAccessControl(address(launcher)).hasRole(0x00, gov), "governance is not launcher admin");

        console2.log("=== Zorpha minimal (launchpad, no oracle) ===");
        console2.log("VaultFactory     ", address(factory));
        console2.log("VaultLauncher    ", address(launcher));
        console2.log("Approved venues  ", targets.length);
        console2.log("");
        console2.log("No oracle, no updaters, no swap adapter, no executor.");
        console2.log("Nothing here needs a price feed, so nothing here has a");
        console2.log("recurring cost beyond the gas a leader spends themselves.");
        console2.log("");
        console2.log("NEXT: a leader calls launchYieldVault(target, seedEscrow,");
        console2.log("name, symbol, salt), having approved the bond in ZOR.");
    }
}

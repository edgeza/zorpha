// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {VaultLauncher} from "../src/leadership/VaultLauncher.sol";
import {VaultFactory} from "../src/VaultFactory.sol";

/// @title DeployLeadership
/// @notice Deploys the permissionless vault layer. Run AFTER DeployVaultsV1,
///         which produces the factory this needs.
///
///         The factory is deliberately left gated. This launcher holds its
///         `DEPLOYER_ROLE` and is the only caller, so vault creation becomes
///         permissionless *through the launcher's rules* rather than open to
///         anyone with a transaction. Removing the gate instead would let a
///         stranger deploy a vault with a 100% fee pointed at an adapter they
///         wrote.
contract DeployLeadership is Script {
    function run() external returns (VaultLauncher launcher) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        address gov = vm.envAddress("GOVERNANCE");
        address treasury = vm.envAddress("TREASURY");
        address timelock = vm.envAddress("TIMELOCK");
        address zor = vm.envAddress("ZOR_TOKEN");
        address factory = vm.envAddress("VAULT_FACTORY");

        require(gov != address(0) && gov != deployer, "GOVERNANCE must be a Safe, not the deployer");
        require(zor != address(0), "ZOR_TOKEN unset");
        require(factory != address(0), "VAULT_FACTORY unset");

        // Venues a leader may allocate to. Everything else is refused, which is
        // the whole difference between permissionless and a one-transaction
        // drain. Comma-separated.
        address[] memory targets = vm.envOr("APPROVED_YIELD_TARGETS", ",", new address[](0));

        vm.startBroadcast(deployerKey);

        // Vault admin is the TIMELOCK, not governance directly and never the
        // leader: privileged changes to someone else's vault should be visible
        // for 48 hours before they land.
        launcher = new VaultLauncher(zor, factory, treasury, timelock, deployer);

        for (uint256 i = 0; i < targets.length; i++) {
            require(IERC4626(targets[i]).asset() != address(0), "target is not ERC-4626");
            launcher.setTargetApproved(targets[i], true);
        }

        // Hand the launcher to governance and step away from it.
        launcher.grantRole(0x00, gov);
        launcher.grantRole(launcher.GOVERNANCE_ROLE(), gov);
        launcher.renounceRole(launcher.GOVERNANCE_ROLE(), deployer);
        launcher.renounceRole(0x00, deployer);

        vm.stopBroadcast();

        require(!IAccessControl(address(launcher)).hasRole(0x00, deployer), "deployer kept admin");
        require(IAccessControl(address(launcher)).hasRole(0x00, gov), "governance is not admin");

        console2.log("=== Zorpha leadership layer ===");
        console2.log("VaultLauncher    ", address(launcher));
        console2.log("Approved venues  ", targets.length);
        console2.log("");
        console2.log("ACTION REQUIRED: grant DEPLOYER_ROLE on the VaultFactory to");
        console2.log("the launcher, from whichever address holds factory admin:");
        console2.log("  factory.grantRole(DEPLOYER_ROLE, %s)", address(launcher));
        console2.log("");
        if (targets.length == 0) {
            console2.log("WARNING: no approved venues. Nobody can launch a vault");
            console2.log("until governance approves at least one ERC-4626 target.");
        }
    }
}

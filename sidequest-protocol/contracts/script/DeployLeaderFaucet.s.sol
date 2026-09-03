// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {LeaderFaucet} from "../src/testnet/LeaderFaucet.sol";

/// @notice Deploy the leader faucet, which is the thing standing between the
///         leader programme and anybody outside the team using it.
///
/// @dev    Refuses to run on chain 4663. The contract refuses too, at runtime,
///         but a deploy that cannot happen is better than one that can and is
///         inert -- a mainnet faucet address in an env file is a liability even
///         if `claim` reverts.
///
///         Funding is deliberately NOT part of this script. It needs ZOR from
///         governance, and governance is a Safe on mainnet and a keystore here;
///         either way that is a separate, visible transfer rather than
///         something buried in a deploy. The script prints the exact command.
contract DeployLeaderFaucet is Script {
    uint256 internal constant MAINNET_CHAIN_ID = 4663;

    function run() external returns (LeaderFaucet faucet) {
        require(block.chainid != MAINNET_CHAIN_ID, "LeaderFaucet is testnet-only");

        address zor = vm.envAddress("ZOR_TOKEN");
        address usdg = vm.envAddress("USDG_TOKEN");
        address launcher = vm.envAddress("VAULT_LAUNCHER");
        address gov = vm.envAddress("GOVERNANCE");
        // 25 leaders is a programme, not a giveaway. Governance can raise it.
        uint256 maxClaims = vm.envOr("FAUCET_MAX_CLAIMS", uint256(25));

        require(zor != address(0), "ZOR_TOKEN unset");
        require(usdg != address(0), "USDG_TOKEN unset");
        require(launcher != address(0), "VAULT_LAUNCHER unset");
        require(gov != address(0), "GOVERNANCE unset");

        vm.startBroadcast();
        faucet = new LeaderFaucet(zor, usdg, launcher, gov, maxClaims);
        vm.stopBroadcast();

        (uint256 bond, uint256 seed) = faucet.ticket();
        uint256 needed = bond * maxClaims;

        console2.log("=== Zorpha leader faucet ===");
        console2.log("LeaderFaucet   ", address(faucet));
        console2.log("owner (gov)    ", gov);
        console2.log("max claims     ", maxClaims);
        console2.log("bond per claim ", bond);
        console2.log("seed per claim ", seed);
        console2.log("");
        console2.log("It holds nothing yet. Claims revert until governance funds it.");
        console2.log("ZOR needed to cover every claim:");
        console2.log(needed);
        console2.log("");
        console2.log("Fund it from governance:");
        console2.log("  cast send <ZOR> 'transfer(address,uint256)' <FAUCET> <AMOUNT>");
        console2.log("");
        console2.log("The seed leg costs the float nothing: TestUSDG.mint is open,");
        console2.log("so the faucet mints it and only ZOR has to be provisioned.");
        console2.log("");
        console2.log("Add to zorpha-web/.env.local:");
        console2.log("  NEXT_PUBLIC_LEADER_FAUCET_ADDRESS=", address(faucet));
    }
}

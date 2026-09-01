// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TestUSDG, TestEquity, TestYieldTarget} from "../src/testnet/TestnetFixtures.sol";

/// @title DeployTestnetFixtures
/// @notice Stands up the venue Robinhood Chain testnet does not have.
///
///         Testnet (46630) is bare: the mainnet USDG, Steakhouse and Uniswap
///         addresses all return no code there. So a testnet run has no
///         stablecoin to denominate a vault in, no curated vault to earn yield
///         from, and no equity token to rotate into.
///
///         This deploys stand-ins for all three and prints the env block for
///         the vault deploy. Run it FIRST, before DeployVaultsV1.
///
///         Refuses to run on mainnet. The tokens here mint for free to anyone.
contract DeployTestnetFixtures is Script {
    uint256 internal constant MAINNET = 4663;

    function run() external {
        require(block.chainid != MAINNET, "fixtures are testnet-only");

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        TestUSDG usdg = new TestUSDG();
        TestEquity aapl = new TestEquity("Test Apple", "tAAPL");
        TestEquity nvda = new TestEquity("Test NVIDIA", "tNVDA");
        TestYieldTarget target = new TestYieldTarget(IERC20(address(usdg)));

        // Seed the deployer so there is something to deposit, and seed the
        // yield target so its share price is defined before the first deposit.
        usdg.mint(deployer, 1_000_000 * 1e6);
        aapl.mint(deployer, 10_000 * 1e18);
        nvda.mint(deployer, 10_000 * 1e18);

        vm.stopBroadcast();

        console2.log("=== Zorpha testnet fixtures ===");
        console2.log("tUSDG (6dp)      ", address(usdg));
        console2.log("tAAPL (18dp)     ", address(aapl));
        console2.log("tNVDA (18dp)     ", address(nvda));
        console2.log("Yield target     ", address(target));
        console2.log("");
        console2.log("Export these before running DeployVaultsV1:");
        console2.log("  export USDG_TOKEN=%s", address(usdg));
        console2.log("  export STOCK_TOKEN_1=%s", address(aapl));
        console2.log("  export STOCK_TOKEN_2=%s", address(nvda));
        console2.log("  export YIELD_TARGET=%s", address(target));
        console2.log("");
        console2.log("Leave SWAP_ROUTER unset on testnet: there is no DEX here,");
        console2.log("so the spot vault falls back to StubSwapAdapter and the");
        console2.log("rebalance path is exercised without real price discovery.");
    }
}

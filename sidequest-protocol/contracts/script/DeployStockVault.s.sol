// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {UniswapV3TwapAdapter} from "../src/oracle/UniswapV3TwapAdapter.sol";
import {SpotVaultMinimal} from "../src/vaults/SpotVaultMinimal.sol";
import {RobinhoodChainRouterAdapter} from "../src/adapters/RobinhoodChainRouterAdapter.sol";

/// @notice Deploys the oracle-free NVDA long/flat vault on Robinhood Chain 4663.
///
///         WHY ADMIN LANDS ON THE SAFE AND NOT ON THE TIMELOCK
///
///         The end state is admin on the Timelock. Deploying straight to it
///         would mean the Timelock has to grant KEEPER_ROLE, grant
///         RISK_COUNCIL_ROLE and set the swap adapter -- three separate 48-hour
///         proposals, during which the vault exists on chain and cannot trade.
///
///         So the constructor hands DEFAULT_ADMIN to the SAFE, and
///         safe-batches/I-stock-vault-roles.json does the roles, the adapter
///         wiring and the handover to the Timelock in ONE atomic transaction
///         that ends with the Safe renouncing its own admin. The vault is never
///         left in a half-configured state that someone could act on.
///
///         The deployer key holds nothing at any point. It pays gas and signs
///         three CREATEs; it is never granted a role on anything.
///
///         WHY THE READ-BACK AT THE END IS NOT DECORATION
///
///         The constructor derives base/quote ordering from the pool, so the
///         adapter cannot compute a reciprocal by accident. What it CANNOT
///         catch is a deployer who meant NVDA-in-USDG and typed the arguments
///         the other way round, because both orderings describe a real pair.
///         That mistake is caught here and nowhere else: `baseIsToken0` must be
///         false and `assetToCash(1e18)` must look like a share price in USDG.
///         Read them before broadcasting.
///
///         RUN, dry (no --broadcast, sends nothing):
///           forge script script/DeployStockVault.s.sol:DeployStockVault \
///             --rpc-url https://rpc.mainnet.chain.robinhood.com
///
///         RUN, for real:
///           forge script script/DeployStockVault.s.sol:DeployStockVault \
///             --rpc-url https://rpc.mainnet.chain.robinhood.com \
///             --account mainnet-deploy --broadcast --slow
///
///         Never pass --password. Let it prompt, so the passphrase stays out of
///         shell history.
contract DeployStockVault is Script {
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC; // 18dp
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168; // 6dp
    address constant POOL = 0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3; // 0.05%
    address constant SWAP_ROUTER_02 = 0xCaf681a66D020601342297493863E78C959E5cb2;
    uint24 constant FEE = 500;

    address constant SAFE = 0xC75E64Ccf3ce6E2F40939Ab58255681769BcF8C4;
    address constant TIMELOCK = 0x813D69B8e1DBE2E08bcB892BE203A6BCE99b36Fc;
    address constant TREASURY = 0x3D9FE37DC0D08BeD0CD48c74Cb344064df9fB3C6;

    uint32 constant TWAP_WINDOW = 1800;
    uint16 constant MIN_CARDINALITY = 300;

    /// @dev LOWERED FROM THE SPEC'S 1.2e19, on measurement.
    ///
    ///      `liquidity()` is IN-RANGE liquidity, and it turns out to move far
    ///      more violently than the spec assumed. Measured against the live pool
    ///      on 6 September, escalating single trades from a snapshot:
    ///
    ///          size(USDG)   in-range liq   spot divergence
    ///              50,000      1.342e19            4 bps
    ///             250,000      9.391e18           28 bps
    ///             500,000      7.784e18           67 bps
    ///           1,000,000      4.149e18          177 bps
    ///           2,000,000      7.483e13    (drained)
    ///
    ///      A $50,000 trade -- ordinary flow on a pool with $7M of depth, not an
    ///      attack -- already cuts in-range liquidity from 3.85e19 to 1.34e19.
    ///      At 1.2e19 the vault would have stopped rebalancing after any $250k
    ///      trade by anyone, which is availability lost for nothing.
    ///
    ///      5e18 is chosen so ordinary flow up to $500k leaves the vault
    ///      working, while the $1M case -- which drains depth to 4.149e18 -- is
    ///      still refused. That size matters specifically: at 177 bps it sits
    ///      INSIDE the 200 bps divergence tolerance, so the liquidity floor is
    ///      the only guard that catches it. Anything below ~4.2e18 would neuter
    ///      the check entirely.
    uint128 constant MIN_LIQUIDITY = 5e18;

    uint32 constant MAX_OBSERVATION_AGE = 4 hours;
    uint16 constant MAX_SPOT_DIVERGENCE_BPS = 200;

    uint256 constant MAX_ORACLE_STALENESS = 3600;
    uint16 constant REBALANCE_THRESHOLD_BPS = 100;
    uint16 constant MAX_SLIPPAGE_BPS = 100;
    uint256 constant PERFORMANCE_FEE_BPS = 1000;
    uint256 constant EMERGENCY_REDEEM_COOLDOWN = 0;

    function run() external {
        require(block.chainid == 4663, "wrong chain: this script is mainnet 4663 only");

        vm.startBroadcast();

        UniswapV3TwapAdapter oracle = new UniswapV3TwapAdapter(
            POOL, NVDA, USDG,
            TWAP_WINDOW, MIN_CARDINALITY, MIN_LIQUIDITY, MAX_OBSERVATION_AGE, MAX_SPOT_DIVERGENCE_BPS
        );

        SpotVaultMinimal vault = new SpotVaultMinimal(
            NVDA, USDG, address(oracle), MAX_ORACLE_STALENESS,
            "Zorpha NVDA Long/Flat", "zqNVDA",
            REBALANCE_THRESHOLD_BPS, MAX_SLIPPAGE_BPS, PERFORMANCE_FEE_BPS,
            TREASURY,  // feeRecipient, matching zsUSDG
            SAFE,      // admin, handed to the Timelock by safe batch I
            EMERGENCY_REDEEM_COOLDOWN
        );

        // Its own swap adapter, admin on the Safe, so VAULT_ROLE can be granted
        // to the vault inside the same batch that does everything else.
        RobinhoodChainRouterAdapter swap =
            new RobinhoodChainRouterAdapter(SWAP_ROUTER_02, NVDA, USDG, FEE, SAFE);

        vm.stopBroadcast();

        _report(oracle, vault, swap);
    }

    /// @dev Split out because `run` is already at the stack limit with three
    ///      contracts and every constant in scope.
    function _report(
        UniswapV3TwapAdapter oracle,
        SpotVaultMinimal vault,
        RobinhoodChainRouterAdapter swap
    ) internal view {
        (, int256 answer, , , ) = oracle.latestRoundData();

        console2.log("");
        console2.log("=== deployed ===");
        console2.log("UniswapV3TwapAdapter       ", address(oracle));
        console2.log("SpotVaultMinimal (zqNVDA)  ", address(vault));
        console2.log("RobinhoodChainRouterAdapter", address(swap));

        console2.log("");
        console2.log("=== read back: CHECK THESE BEFORE SIGNING ANYTHING ===");
        console2.log("oracle.decimals()   (expect 8)     ", oracle.decimals());
        console2.log("baseIsToken0        (expect false) ", oracle.baseIsToken0());
        console2.log("oracle answer at 1e8               ", uint256(answer));
        console2.log("  -> that is USDG per NVDA. If it does not look like a");
        console2.log("     share price, base and quote were passed backwards.");
        console2.log("vault.assetToCash(1e18) in USDG    ", vault.assetToCash(1e18));
        console2.log("  -> must equal the answer above divided by 100.");

        console2.log("");
        console2.log("=== roles as deployed ===");
        console2.log("vault admin is the Safe    ", vault.hasRole(0x00, SAFE));
        console2.log("vault admin is the Timelock", vault.hasRole(0x00, TIMELOCK));
        console2.log("  -> Safe true, Timelock false. Batch I flips that.");

        console2.log("");
        console2.log("=== guard headroom, live ===");
        console2.log("minLiquidity configured    ", oracle.minLiquidity());
        console2.log("buffer reaches back (s)    ", oracle.oldestObservationSecondsAgo());

        console2.log("");
        console2.log("NEXT: safe-batches/I-stock-vault-roles.json, with these three addresses.");
    }
}

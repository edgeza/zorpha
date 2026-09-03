// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {VaultFactory, SpotVaultParams, RWRotationVaultParams, YieldVaultParams} from "../src/VaultFactory.sol";
import {SpotVaultMinimal} from "../src/vaults/SpotVaultMinimal.sol";
import {RWRotationVault} from "../src/vaults/RWRotationVault.sol";
import {YieldVault} from "../src/vaults/YieldVault.sol";
import {StubYieldAdapter} from "../src/adapters/StubYieldAdapter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract VaultFactoryTest is Test {
    VaultFactory factory;
    address admin = makeAddr("admin");
    address user = makeAddr("user");

    function setUp() public {
        factory = new VaultFactory(admin);
    }

    function test_DeploySpotVault_PredictMatches() public {
        MockERC20 asset = new MockERC20("Asset", "A", 18);
        MockERC20 cash = new MockERC20("Cash", "C", 18);
        MockOracle oracle = new MockOracle(1e8, 8);

        SpotVaultParams memory p = SpotVaultParams({
            asset: address(asset),
            cashAsset: address(cash),
            oracle: address(oracle),
            maxOracleStaleness: 1 hours,
            name: "Test Spot",
            symbol: "TS",
            rebalanceThresholdBps: 100,
            maxSlippageBps: 100,
            performanceFeeBps: 0,
            feeRecipient: user,
            admin: user,
            emergencyRedeemCooldown: 1 hours
        });
        bytes32 salt = keccak256("test-spot-salt-1");

        address predicted = factory.predictSpotVault(p, salt);

        vm.prank(admin);
        address deployed = factory.deploySpotVault(p, salt);

        assertEq(predicted, deployed, "predicted == deployed");
        assertEq(factory.spotDeployCount(), 1);

        SpotVaultMinimal v = SpotVaultMinimal(deployed);
        assertEq(v.feeRecipient(), user);
    }

    function test_DeployYieldVault_PredictMatches() public {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        StubYieldAdapter adapter = new StubYieldAdapter(address(usdc), address(this));

        YieldVaultParams memory p = YieldVaultParams({
            asset: address(usdc),
            adapter: address(adapter),
            name: "Test Yield",
            symbol: "TY",
            performanceFeeBps: 0,
            feeRecipient: user,
            admin: user
        });
        bytes32 salt = keccak256("test-yield-salt-1");

        address predicted = factory.predictYieldVault(p, salt);
        vm.prank(admin);
        address deployed = factory.deployYieldVault(p, salt);
        assertEq(predicted, deployed);
        assertEq(factory.yieldDeployCount(), 1);
    }

    function test_DeployRotationVault_PredictMatches() public {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 t0 = new MockERC20("T0", "T0", 8);
        MockERC20 t1 = new MockERC20("T1", "T1", 8);
        MockOracle o0 = new MockOracle(1e8, 8);
        MockOracle o1 = new MockOracle(1e8, 8);

        address[] memory tokens = new address[](2);
        tokens[0] = address(t0); tokens[1] = address(t1);
        address[] memory oracles = new address[](2);
        oracles[0] = address(o0); oracles[1] = address(o1);
        uint16[] memory weights = new uint16[](2);
        weights[0] = 5000; weights[1] = 5000;

        RWRotationVaultParams memory p = RWRotationVaultParams({
            baseAsset: address(usdc),
            tokens: tokens,
            oracles: oracles,
            maxOracleStaleness: 1 hours,
            initialWeightsBps: weights,
            name: "Test Rot",
            symbol: "TR",
            performanceFeeBps: 0,
            feeRecipient: user,
            admin: user
        });
        bytes32 salt = keccak256("test-rot-salt-1");

        address predicted = factory.predictRotationVault(p, salt);
        vm.prank(admin);
        address deployed = factory.deployRotationVault(p, salt);
        assertEq(predicted, deployed);
        assertEq(factory.rotationDeployCount(), 1);
    }

    function test_NonDeployer_Reverts() public {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        StubYieldAdapter adapter = new StubYieldAdapter(address(usdc), address(this));
        YieldVaultParams memory p = YieldVaultParams({
            asset: address(usdc),
            adapter: address(adapter),
            name: "X", symbol: "X",
            performanceFeeBps: 0,
            feeRecipient: user, admin: user
        });
        // Named, so this cannot pass on a malformed params struct or a bad
        // adapter instead of the role check it is about. No prank: the caller
        // is this contract, which was never granted DEPLOYER_ROLE.
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                address(this),
                factory.DEPLOYER_ROLE()
            )
        );
        factory.deployYieldVault(p, bytes32("non-deployer-salt"));
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SpotVaultMinimal} from "../../src/vaults/SpotVaultMinimal.sol";
import {UniswapV3TwapAdapter} from "../../src/oracle/UniswapV3TwapAdapter.sol";

/// @notice The vault AS DEPLOYED on 4663, driven by the address that really
///         holds KEEPER_ROLE. Role bits being right is necessary; this is the
///         part that proves it can actually trade.
contract DeployedVaultLiveTest is Test {
    address constant VAULT = 0xB129495f0ad616EdD2f28b3B49470FC1f0FAD413;
    address constant ORACLE = 0xaBefb351777d8E68FCafa4D2F8A5848F326298cA;
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant SAFE = 0xC75E64Ccf3ce6E2F40939Ab58255681769BcF8C4;

    SpotVaultMinimal vault;
    bool forked;

    function setUp() public {
        string memory url = vm.envOr("RH_MAINNET_RPC_URL", string(""));
        if (bytes(url).length == 0) return;
        vm.createSelectFork(url);
        forked = true;
        vault = SpotVaultMinimal(VAULT);
    }

    function test_TheDeployedVaultCanActuallyTrade() public {
        if (!forked) { vm.skip(true); }

        (, int256 answer, , , ) = UniswapV3TwapAdapter(ORACLE).latestRoundData();
        console2.log("oracle answers            :", uint256(answer));
        assertGt(answer, 0, "the deployed oracle refuses");

        // Deposit as a stranger, so this is not privileged.
        address alice = address(0xA11CE);
        deal(NVDA, alice, 1e18);
        vm.startPrank(alice);
        IERC20(NVDA).approve(VAULT, 1e18);
        uint256 shares = vault.deposit(1e18, alice);
        vm.stopPrank();
        assertGt(shares, 0, "deposit produced no shares");
        console2.log("deposited 1 NVDA, shares  :", shares);

        // Rebalance as the SAFE, which is what actually holds KEEPER_ROLE now.
        vm.prank(SAFE);
        vault.rebalanceTo(0);
        assertEq(vault.rebalanceCount(), 1, "no receipt emitted");
        assertGt(IERC20(USDG).balanceOf(VAULT), 0, "no cash leg after going flat");
        console2.log("went flat, USDG held      :", IERC20(USDG).balanceOf(VAULT));

        vm.prank(SAFE);
        vault.rebalanceTo(10000);
        assertEq(vault.rebalanceCount(), 2);
        console2.log("back to long, NAV         :", vault.totalAssets());
        assertApproxEqRel(vault.totalAssets(), 1e18, 1e16, "round trip lost over 1%");

        // And the deployer, which holds nothing, must be refused.
        vm.prank(0x90D5fE6a51CbDA18C3960966D5830Ba03B4fFB02);
        vm.expectRevert();
        vault.rebalanceTo(5000);

        // As must a stranger.
        vm.prank(alice);
        vm.expectRevert();
        vault.rebalanceTo(5000);
        console2.log("deployer and stranger both refused");
    }
}

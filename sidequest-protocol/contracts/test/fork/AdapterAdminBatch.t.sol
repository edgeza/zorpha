// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SpotVaultMinimal} from "../../src/vaults/SpotVaultMinimal.sol";

/// @notice Replays batch K's own JSON as the Safe, then checks the vault can
///         still trade afterwards.
///
///         The second half is the point. Handing an adapter's admin away is
///         easy to get subtly wrong in a way that only shows at the next
///         rebalance, and the whole reason this role exists is to control who
///         may call swap().
contract AdapterAdminBatchTest is Test {
    address constant SAFE = 0xC75E64Ccf3ce6E2F40939Ab58255681769BcF8C4;
    address constant TIMELOCK = 0x813D69B8e1DBE2E08bcB892BE203A6BCE99b36Fc;
    address constant SWAP = 0x8E50FC336f87b454cc44a89dA3a7267412B045dc;
    address constant VAULT = 0xB129495f0ad616EdD2f28b3B49470FC1f0FAD413;
    bytes32 constant ADMIN = 0x00;

    bool forked;

    function setUp() public {
        string memory url = vm.envOr("RH_MAINNET_RPC_URL", string(""));
        if (bytes(url).length == 0) return;
        vm.createSelectFork(url);
        forked = true;
    }

    function test_BatchKMovesAdminAndLeavesTradingIntact() public {
        if (!forked) { vm.skip(true); }

        string memory raw = vm.readFile("safe-batches/K-adapter-admin-to-timelock.json");
        assertEq(vm.parseJsonString(raw, ".chainId"), "4663");

        assertTrue(IAccessControl(SWAP).hasRole(ADMIN, SAFE), "precondition: Safe is admin");
        assertFalse(IAccessControl(SWAP).hasRole(ADMIN, TIMELOCK));

        for (uint256 i = 0; i < 2; i++) {
            string memory base = string.concat(".transactions[", vm.toString(i), "]");
            address to = vm.parseJsonAddress(raw, string.concat(base, ".to"));
            bytes memory data = vm.parseJsonBytes(raw, string.concat(base, ".data"));
            vm.prank(SAFE);
            (bool ok, ) = to.call(data);
            assertTrue(ok, "a batch transaction reverted");
        }

        assertTrue(IAccessControl(SWAP).hasRole(ADMIN, TIMELOCK), "Timelock must be admin");
        assertFalse(IAccessControl(SWAP).hasRole(ADMIN, SAFE), "Safe must have renounced");

        // The part worth testing: the vault still rebalances. VAULT_ROLE was
        // untouched, so this must be unaffected, and asserting it is cheaper
        // than discovering otherwise on mainnet.
        SpotVaultMinimal vault = SpotVaultMinimal(VAULT);
        uint256 before = vault.rebalanceCount();
        vm.prank(SAFE);
        vault.rebalanceTo(10000);
        assertEq(vault.rebalanceCount(), before + 1, "the vault stopped trading");
        console2.log("rebalanced after the handover, receipts now:", vault.rebalanceCount());

        // And the Safe can no longer touch VAULT_ROLE.
        vm.prank(SAFE);
        vm.expectRevert();
        IAccessControl(SWAP).revokeRole(keccak256("VAULT_ROLE"), VAULT);
    }
}

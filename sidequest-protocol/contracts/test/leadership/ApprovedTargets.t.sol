// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {VaultLauncher} from "../../src/leadership/VaultLauncher.sol";
import {VaultFactory} from "../../src/VaultFactory.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice The venue allowlist has to be enumerable, not just queryable.
///
///         `approvedTarget` is a mapping: it answers "is this one approved?"
///         and cannot answer "which ones are?". So nothing could show a leader
///         the venues they may pick from, and the launch form asked them to
///         paste a raw address and only then told them whether it was allowed.
///
///         This is the same shape as the oracle bug earlier the same day:
///         `grantRole` set a mapping while the contract iterated an array, so
///         the role was held and the updater invisible. A membership set that
///         something has to enumerate needs an array, and the array has to be
///         maintained by whatever writes the mapping.
///
///         These tests exist for the maintenance, not the happy path: double
///         approve, revoke-from-the-middle, and revoke-what-was-never-approved
///         are where a hand-rolled set goes wrong.
contract ApprovedTargetsTest is Test {
    VaultLauncher launcher;
    address gov = address(0x60F);

    address a = address(0xA1);
    address b = address(0xB2);
    address c = address(0xC3);

    function setUp() public {
        MockERC20 zor = new MockERC20("Zorpha", "ZOR", 18);
        VaultFactory factory = new VaultFactory(address(this));
        launcher = new VaultLauncher(
            address(zor), address(factory), address(this), address(this), gov
        );
        vm.startPrank(gov);
    }

    function _all() internal view returns (address[] memory) {
        return launcher.allApprovedTargets();
    }

    function test_ApprovingListsIt() public {
        launcher.setTargetApproved(a, true);
        assertEq(launcher.approvedTargetCount(), 1);
        assertEq(_all()[0], a);
        assertTrue(launcher.approvedTarget(a));
    }

    /// Approving twice must not list the same venue twice, or a UI renders a
    /// duplicate and a count that disagrees with reality.
    function test_ApprovingTwiceDoesNotDuplicate() public {
        launcher.setTargetApproved(a, true);
        launcher.setTargetApproved(a, true);
        assertEq(launcher.approvedTargetCount(), 1);
    }

    /// Revoking one that was never approved must be a no-op, not an underflow.
    function test_RevokingAnUnknownTargetIsANoOp() public {
        launcher.setTargetApproved(a, false);
        assertEq(launcher.approvedTargetCount(), 0);
    }

    /// The swap-remove case: revoking from the MIDDLE must keep every other
    /// member present, which a naive pop would not.
    function test_RevokingFromTheMiddleKeepsTheRest() public {
        launcher.setTargetApproved(a, true);
        launcher.setTargetApproved(b, true);
        launcher.setTargetApproved(c, true);

        launcher.setTargetApproved(b, false);

        assertEq(launcher.approvedTargetCount(), 2);
        assertFalse(launcher.approvedTarget(b));

        address[] memory all = _all();
        bool sawA;
        bool sawC;
        for (uint256 i = 0; i < all.length; i++) {
            if (all[i] == a) sawA = true;
            if (all[i] == c) sawC = true;
            assertTrue(all[i] != b, "revoked target still listed");
        }
        assertTrue(sawA && sawC, "a surviving target was dropped");
    }

    /// Re-approving after a revoke must list it once, not resurrect a stale
    /// index into the middle of the array.
    function test_ReApprovingAfterRevokeListsItOnce() public {
        launcher.setTargetApproved(a, true);
        launcher.setTargetApproved(b, true);
        launcher.setTargetApproved(a, false);
        launcher.setTargetApproved(a, true);

        assertEq(launcher.approvedTargetCount(), 2);
        address[] memory all = _all();
        uint256 seen;
        for (uint256 i = 0; i < all.length; i++) if (all[i] == a) seen++;
        assertEq(seen, 1, "target listed more than once");
    }

    function test_RevokingEverythingEmptiesTheList() public {
        launcher.setTargetApproved(a, true);
        launcher.setTargetApproved(b, true);
        launcher.setTargetApproved(a, false);
        launcher.setTargetApproved(b, false);
        assertEq(launcher.approvedTargetCount(), 0);
        assertEq(_all().length, 0);
    }

    function test_OnlyGovernanceMayChangeTheList() public {
        vm.stopPrank();
        vm.expectRevert();
        launcher.setTargetApproved(a, true);
    }
}

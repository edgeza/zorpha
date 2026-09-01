// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {VaultLauncher} from "../../src/leadership/VaultLauncher.sol";
import {FirstLossEscrow} from "../../src/leadership/FirstLossEscrow.sol";
import {VaultFactory} from "../../src/VaultFactory.sol";
import {YieldVault} from "../../src/vaults/YieldVault.sol";
import {ERC4626YieldAdapter} from "../../src/adapters/ERC4626YieldAdapter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockERC4626} from "../mocks/MockERC4626.sol";

/// @notice Permissionless creation is only safe if the boundary holds. Most of
///         these tests are about what a leader CANNOT do once they have one.
contract VaultLauncherTest is Test {
    MockERC20 zor;
    MockERC20 usdg;
    MockERC4626 steak;
    MockERC4626 spark;
    MockERC4626 rogue; // approved by nobody

    VaultFactory factory;
    VaultLauncher launcher;

    address governance = address(0x6011);
    address treasury = address(0x7EA5);
    address leader = address(0x1EAD);
    address stranger = address(0x57A);
    address alice = address(0xA1);

    uint256 constant ONE = 1e6;
    uint256 constant BOND = 10_000e18;
    uint256 constant SEED = 1_000 * ONE;

    function setUp() public {
        zor = new MockERC20("Zorpha", "ZOR", 18);
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        steak = new MockERC4626(IERC20(address(usdg)), "Steakhouse USDG", "steakUSDG");
        spark = new MockERC4626(IERC20(address(usdg)), "Spark USDG", "spUSDG");
        rogue = new MockERC4626(IERC20(address(usdg)), "Rogue", "rogue");

        factory = new VaultFactory(address(this));
        launcher = new VaultLauncher(
            address(zor), address(factory), treasury, governance, governance
        );
        factory.grantRole(factory.DEPLOYER_ROLE(), address(launcher));

        vm.startPrank(governance);
        launcher.setTargetApproved(address(steak), true);
        launcher.setTargetApproved(address(spark), true);
        vm.stopPrank();

        zor.mint(leader, 100_000e18);
        zor.mint(stranger, 100_000e18);
        usdg.mint(leader, 1_000_000 * ONE);
        usdg.mint(stranger, 1_000_000 * ONE);
        usdg.mint(alice, 1_000_000 * ONE);
    }

    function _launch(address who, address target, bytes32 salt)
        internal
        returns (address vault, address escrow)
    {
        vm.startPrank(who);
        zor.approve(address(launcher), BOND);
        usdg.approve(address(launcher), SEED);
        (vault, escrow) = launcher.launchYieldVault(target, SEED, "Leader Vault", "lvUSDG", salt);
        vm.stopPrank();
    }

    // ─── Permissionless, but not free ────────────────────────────────────────

    function test_AnyoneCanLaunchAVault() public {
        (address vault, address escrow) = _launch(stranger, address(steak), bytes32("a"));

        assertTrue(vault != address(0), "no vault");
        assertEq(FirstLossEscrow(escrow).leader(), stranger, "leader not recorded");
        assertEq(FirstLossEscrow(escrow).escrow(), SEED, "buffer not seeded");
        assertEq(launcher.launchCount(), 1, "not registered");
    }

    function test_BondIsTakenAndHeld() public {
        uint256 before = zor.balanceOf(leader);
        _launch(leader, address(steak), bytes32("a"));
        assertEq(before - zor.balanceOf(leader), BOND, "bond not taken");
        assertEq(zor.balanceOf(address(launcher)), BOND, "bond not held");
    }

    function test_SeedBelowMinimumIsRejected() public {
        vm.startPrank(leader);
        zor.approve(address(launcher), BOND);
        usdg.approve(address(launcher), 1);
        vm.expectRevert(
            abi.encodeWithSelector(VaultLauncher.SeedTooSmall.selector, 1, SEED)
        );
        launcher.launchYieldVault(address(steak), 1, "x", "x", bytes32("a"));
        vm.stopPrank();
    }

    /// @dev The allowlist is the difference between permissionless and a
    ///      one-transaction drain. Without it a leader points the vault at a
    ///      contract they wrote.
    function test_UnapprovedTargetIsRejected() public {
        vm.startPrank(leader);
        zor.approve(address(launcher), BOND);
        usdg.approve(address(launcher), SEED);
        vm.expectRevert(
            abi.encodeWithSelector(VaultLauncher.TargetNotApproved.selector, address(rogue))
        );
        launcher.launchYieldVault(address(rogue), SEED, "x", "x", bytes32("a"));
        vm.stopPrank();
    }

    // ─── What a leader must NOT be able to do ────────────────────────────────

    function test_LeaderIsNotVaultAdmin() public {
        (address vault,) = _launch(leader, address(steak), bytes32("a"));

        assertFalse(
            IAccessControl(vault).hasRole(0x00, leader), "leader holds vault admin"
        );
        assertTrue(
            IAccessControl(vault).hasRole(0x00, governance), "governance is not admin"
        );
        assertFalse(
            IAccessControl(vault).hasRole(YieldVault(vault).ADAPTER_SETTER_ROLE(), leader),
            "leader can install an adapter directly"
        );
    }

    /// @dev The launcher needs exactly one power over a launched vault:
    ///      swapping the adapter between allowlisted venues. Keeping
    ///      DEFAULT_ADMIN_ROLE as well would leave one contract able to change
    ///      the fee or the fee recipient on every vault ever launched.
    function test_LauncherKeepsOnlyTheAdapterRole() public {
        (address vault,) = _launch(leader, address(steak), bytes32("a"));

        assertFalse(
            IAccessControl(vault).hasRole(0x00, address(launcher)),
            "launcher retained vault admin"
        );
        assertTrue(
            IAccessControl(vault).hasRole(
                YieldVault(vault).ADAPTER_SETTER_ROLE(), address(launcher)
            ),
            "launcher cannot reallocate"
        );
    }

    function test_LeaderCannotDisableTheEscrow() public {
        (address vault, address escrow) = _launch(leader, address(steak), bytes32("a"));

        FirstLossEscrow other = new FirstLossEscrow(
            address(usdg), vault, leader, treasury, 8000, 500
        );
        vm.prank(leader);
        vm.expectRevert(); // not admin, and it is set-once anyway
        YieldVault(vault).setFirstLossEscrow(address(other));

        assertEq(YieldVault(vault).firstLossEscrow(), escrow, "escrow was swapped");
    }

    function test_StrangerCannotReallocateSomeoneElsesVault() public {
        _launch(leader, address(steak), bytes32("a"));
        vm.prank(stranger);
        vm.expectRevert(VaultLauncher.NotLeader.selector);
        launcher.reallocate(1, address(spark));
    }

    function test_LeaderCannotReallocateToAnUnapprovedTarget() public {
        _launch(leader, address(steak), bytes32("a"));
        vm.prank(leader);
        vm.expectRevert(
            abi.encodeWithSelector(VaultLauncher.TargetNotApproved.selector, address(rogue))
        );
        launcher.reallocate(1, address(rogue));
    }

    // ─── What a leader SHOULD be able to do ──────────────────────────────────

    function test_LeaderReallocatesBetweenApprovedVenues() public {
        (address vault,) = _launch(leader, address(steak), bytes32("a"));

        vm.startPrank(alice);
        usdg.approve(vault, 10_000 * ONE);
        YieldVault(vault).deposit(10_000 * ONE, alice);
        vm.stopPrank();

        assertEq(steak.totalAssets(), 10_000 * ONE, "not deployed to first venue");

        vm.prank(leader);
        launcher.reallocate(1, address(spark));

        assertEq(steak.totalAssets(), 0, "did not leave the old venue");
        assertApproxEqAbs(spark.totalAssets(), 10_000 * ONE, 2, "did not reach the new venue");
        assertApproxEqAbs(
            YieldVault(vault).totalAssets(), 10_000 * ONE, 2, "NAV moved on reallocation"
        );
    }

    // ─── End to end ──────────────────────────────────────────────────────────

    function test_FullLifecycle_DepositYieldFeesLossExit() public {
        (address vault, address escrow) = _launch(leader, address(steak), bytes32("a"));

        // Depositor arrives.
        vm.startPrank(alice);
        usdg.approve(vault, 20_000 * ONE);
        uint256 shares = YieldVault(vault).deposit(20_000 * ONE, alice);
        vm.stopPrank();

        // Coverage: 1,000 buffer on 20,000 raw = 5%.
        assertEq(FirstLossEscrow(escrow).coverageRatioBps(), 500, "coverage wrong");

        // The venue earns.
        steak.accrue(2_000 * ONE);

        // Fees are marked on any interaction, then claimed into the escrow.
        vm.prank(alice);
        YieldVault(vault).withdraw(1 * ONE, alice, alice);
        assertGt(YieldVault(vault).performanceFeeAccrued(), 0, "no fee marked");

        uint256 leaderBefore = usdg.balanceOf(leader);
        uint256 treasuryBefore = usdg.balanceOf(treasury);
        vm.prank(governance);
        YieldVault(vault).claimFees();
        assertGt(usdg.balanceOf(leader) - leaderBefore, 0, "leader earned nothing");
        assertGt(usdg.balanceOf(treasury) - treasuryBefore, 0, "protocol earned nothing");

        // Then the venue loses less than the buffer.
        uint256 navBefore = YieldVault(vault).totalAssets();
        steak.slash(500 * ONE);
        assertApproxEqAbs(
            YieldVault(vault).totalAssets(), navBefore, 5, "depositor was not protected"
        );

        // Alice exits whole, the leader is out of pocket.
        vm.startPrank(alice);
        YieldVault(vault).redeem(YieldVault(vault).balanceOf(alice), alice, alice);
        vm.stopPrank();
        assertGt(FirstLossEscrow(escrow).totalAbsorbed(), 0, "the buffer never paid");
        shares; // silence unused
    }

    // ─── Bond ────────────────────────────────────────────────────────────────

    function test_BondReclaimableOnlyWhenVaultIsEmpty() public {
        (address vault,) = _launch(leader, address(steak), bytes32("a"));

        vm.startPrank(alice);
        usdg.approve(vault, 5_000 * ONE);
        YieldVault(vault).deposit(5_000 * ONE, alice);
        vm.stopPrank();

        vm.prank(leader);
        vm.expectRevert();
        launcher.reclaimBond(1);

        vm.startPrank(alice);
        YieldVault(vault).redeem(YieldVault(vault).balanceOf(alice), alice, alice);
        vm.stopPrank();

        uint256 before = zor.balanceOf(leader);
        vm.prank(leader);
        launcher.reclaimBond(1);
        assertEq(zor.balanceOf(leader) - before, BOND, "bond not returned");
    }

    function test_GovernanceCanSlashTheBond() public {
        _launch(leader, address(steak), bytes32("a"));

        uint256 before = zor.balanceOf(treasury);
        vm.prank(governance);
        launcher.slashBond(1, "front-ran depositors");
        assertEq(zor.balanceOf(treasury) - before, BOND, "bond not forfeited");

        vm.prank(leader);
        vm.expectRevert(VaultLauncher.BondAlreadyResolved.selector);
        launcher.reclaimBond(1);
    }

    function test_OnlyGovernanceCanSlash() public {
        _launch(leader, address(steak), bytes32("a"));
        vm.prank(stranger);
        vm.expectRevert();
        launcher.slashBond(1, "because");
    }

    // ─── Leaderboard ─────────────────────────────────────────────────────────

    function test_SummaryFeedsALeaderboard() public {
        (address vault,) = _launch(leader, address(steak), bytes32("a"));

        vm.startPrank(alice);
        usdg.approve(vault, 10_000 * ONE);
        YieldVault(vault).deposit(10_000 * ONE, alice);
        vm.stopPrank();

        (
            address v,
            address l,
            uint256 tvl,
            uint256 buffer,
            uint256 coverage,
            bool covered
        ) = launcher.vaultSummary(1);

        assertEq(v, vault);
        assertEq(l, leader);
        assertApproxEqAbs(tvl, 10_000 * ONE, 2, "tvl wrong");
        assertEq(buffer, SEED, "buffer wrong");
        assertEq(coverage, 1000, "10% coverage expected");
        assertTrue(covered, "should be adequately covered");

        uint256[] memory mine = launcher.launchesOfLeader(leader);
        assertEq(mine.length, 1, "leader index wrong");
    }

    function test_TwoLeadersRunIndependentVaults() public {
        (address v1,) = _launch(leader, address(steak), bytes32("a"));
        (address v2,) = _launch(stranger, address(spark), bytes32("b"));

        assertTrue(v1 != v2, "collided");
        assertEq(launcher.launchCount(), 2, "both not registered");
        assertEq(launcher.launchesOfLeader(leader).length, 1);
        assertEq(launcher.launchesOfLeader(stranger).length, 1);
    }
}

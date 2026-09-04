// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {VaultLauncher} from "../../src/leadership/VaultLauncher.sol";
import {FirstLossEscrow} from "../../src/leadership/FirstLossEscrow.sol";
import {VaultFactory} from "../../src/VaultFactory.sol";
import {YieldVault} from "../../src/vaults/YieldVault.sol";
import {Zorpha} from "../../src/Zorpha.sol";

/// @notice The whole leadership stack against the real venues on Robinhood
///         Chain mainnet: a stranger launches a vault, a real depositor uses
///         it, and the leader's capital is genuinely subordinated to theirs.
///
///         Opt-in on RH_MAINNET_RPC_URL, like the other fork suite.
contract LeadershipMainnetForkTest is Test {
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168; // 6dp
    address constant STEAK_USDG = 0xBeEff033F34C046626B8D0A041844C5d1A5409dd;
    address constant SPARK_USDG = 0xde770c84FE66E063336b31737cFE9790f18c4087;

    uint256 constant ONE = 1e6;
    uint256 constant BOND = 10_000e18;
    uint256 constant SEED = 1_000 * ONE;

    Zorpha zor;
    VaultFactory factory;
    VaultLauncher launcher;

    address governance = address(0x6011);
    address treasury = address(0x7EA5);
    address leader = address(0x1EAD);
    address alice = address(0xA11CE);

    bool forked;

    function setUp() public {
        string memory url = vm.envOr("RH_MAINNET_RPC_URL", string(""));
        if (bytes(url).length == 0) return;
        vm.createSelectFork(url);
        forked = true;

        // The token mints its whole supply to one holder at construction.
        zor = new Zorpha(address(this));
        factory = new VaultFactory(address(this));
        launcher = new VaultLauncher(
            address(zor), address(factory), treasury, governance, governance
        );
        factory.grantRole(factory.DEPLOYER_ROLE(), address(launcher));

        vm.startPrank(governance);
        launcher.setTargetApproved(STEAK_USDG, true);
        launcher.setTargetApproved(SPARK_USDG, true);
        vm.stopPrank();

        zor.transfer(leader, 100_000e18);
        deal(USDG, leader, 100_000 * ONE);
        deal(USDG, alice, 100_000 * ONE);
    }

    /// @dev vm.skip, not an early return.
    ///
    ///      Returning early made every test in this file report PASS while
    ///      executing nothing. Nine green ticks, ~5,500 gas each, for the only
    ///      tests that touch real Steakhouse vaults and the real router -- the
    ///      integration surface most likely to break without warning, reporting
    ///      that it was fine. A suite that cannot run should say so out loud;
    ///      vm.skip marks these SKIPPED, which reads as the absence of evidence
    ///      it actually is.
    modifier onlyForked() {
        if (!forked) {
            vm.skip(true);
        }
        _;
    }

    function _launch() internal returns (address vault, address escrow) {
        vm.startPrank(leader);
        zor.approve(address(launcher), BOND);
        IERC20(USDG).approve(address(launcher), SEED);
        (vault, escrow) =
            launcher.launchYieldVault(STEAK_USDG, SEED, "Leader USDG", "lvUSDG", bytes32("rh"));
        vm.stopPrank();
    }

    function test_StrangerLaunchesAVaultOnRealSteakhouse() public onlyForked {
        (address vault, address escrow) = _launch();

        assertEq(FirstLossEscrow(escrow).leader(), leader, "leader not recorded");
        assertEq(FirstLossEscrow(escrow).escrow(), SEED, "buffer not seeded");
        assertEq(zor.balanceOf(address(launcher)), BOND, "bond not held");

        vm.startPrank(alice);
        IERC20(USDG).approve(vault, 25_000 * ONE);
        YieldVault(vault).deposit(25_000 * ONE, alice);
        vm.stopPrank();

        // The money is in Steakhouse, not sitting in the vault.
        assertEq(IERC20(USDG).balanceOf(vault), 0, "vault held idle cash");
        assertGt(
            IERC4626(STEAK_USDG).balanceOf(YieldVault(vault).firstLossEscrow() == address(0)
                ? address(0)
                : address(YieldVault(vault).adapter())),
            0,
            "adapter holds no Steakhouse shares"
        );
        assertApproxEqRel(YieldVault(vault).totalAssets(), 25_000 * ONE, 1e15, "NAV wrong");

        console2.log("coverage bps:", FirstLossEscrow(escrow).coverageRatioBps());
    }

    function test_LeaderReallocatesBetweenTwoRealCuratedVaults() public onlyForked {
        (address vault,) = _launch();

        vm.startPrank(alice);
        IERC20(USDG).approve(vault, 20_000 * ONE);
        YieldVault(vault).deposit(20_000 * ONE, alice);
        vm.stopPrank();

        uint256 navBefore = YieldVault(vault).totalAssets();

        vm.prank(leader);
        launcher.reallocate(1, SPARK_USDG);

        assertApproxEqRel(
            YieldVault(vault).totalAssets(), navBefore, 1e15, "value lost moving venues"
        );
        assertGt(
            IERC4626(SPARK_USDG).balanceOf(address(YieldVault(vault).adapter())),
            0,
            "did not reach Spark"
        );
    }

    /// @dev The headline claim, against a real curated vault. A loss is forced
    ///      by removing underlying from the Steakhouse position, then the
    ///      depositor is checked to be whole.
    function test_ManagerLosesFirstAgainstRealSteakhouse() public onlyForked {
        (address vault, address escrow) = _launch();

        vm.startPrank(alice);
        IERC20(USDG).approve(vault, 20_000 * ONE);
        uint256 shares = YieldVault(vault).deposit(20_000 * ONE, alice);
        vm.stopPrank();

        // Force a drawdown by taking Steakhouse shares away from the adapter,
        // which is what a loss in the underlying market looks like from here.
        address adapter = address(YieldVault(vault).adapter());
        uint256 heldShares = IERC4626(STEAK_USDG).balanceOf(adapter);
        uint256 burn = heldShares / 40; // ~2.5%, inside the 1,000 buffer
        vm.prank(adapter);
        IERC20(STEAK_USDG).transfer(address(0xdead), burn);

        assertLt(YieldVault(vault).rawAssets(), 20_000 * ONE, "no drawdown was created");
        assertApproxEqRel(
            YieldVault(vault).totalAssets(), 20_000 * ONE, 2e15, "depositor was not protected"
        );

        uint256 before = IERC20(USDG).balanceOf(alice);
        vm.startPrank(alice);
        YieldVault(vault).redeem(shares, alice, alice);
        vm.stopPrank();

        assertApproxEqRel(
            IERC20(USDG).balanceOf(alice) - before, 20_000 * ONE, 2e15, "depositor took the loss"
        );
        assertGt(FirstLossEscrow(escrow).totalAbsorbed(), 0, "the buffer never paid");
        assertLt(FirstLossEscrow(escrow).escrow(), SEED, "leader is not out of pocket");

        console2.log("absorbed by the leader (USDG):", FirstLossEscrow(escrow).totalAbsorbed());
    }
}

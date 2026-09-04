// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {DeployMinimal} from "../../script/DeployMinimal.s.sol";
import {VaultFactory} from "../../src/VaultFactory.sol";
import {VaultLauncher} from "../../src/leadership/VaultLauncher.sol";
import {YieldVault} from "../../src/vaults/YieldVault.sol";
import {Zorpha} from "../../src/Zorpha.sol";

/// @notice A dry run of the minimal mainnet deploy, against mainnet.
///
///         NEEDS A RAISED GAS LIMIT. VaultFactory alone costs ~9.5m gas to
///         deploy, and setUp does that plus a VaultLauncher, so the default
///         budget runs out mid-handover and reports OutOfGas on a grantRole:
///
///             RH_MAINNET_RPC_URL=... forge test ///               --match-path test/fork/MinimalDeploy.t.sol --gas-limit 200000000
///
///         Runs script/DeployMinimal.s.sol itself rather than a copy of what it
///         does, then launches a vault on the real Steakhouse USDG venue through
///         the contracts it produced and puts a real depositor through it.
///
///         The first time the deploy script executes should not be the first
///         time it has ever executed. Every failure this can catch -- a missing
///         role, an unapproved venue, a handover that half applies, a venue that
///         does not behave like the ERC-4626 it claims to be -- costs nothing
///         here and costs a redeploy on mainnet.
contract MinimalDeployForkTest is Test {
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168; // 6dp
    address constant STEAK_USDG = 0xBeEff033F34C046626B8D0A041844C5d1A5409dd;

    uint256 constant ONE = 1e6;

    address gov = address(0x6011);
    address treasury = address(0x7EA5);
    address timelock = address(0x71E10);
    address leader = address(0x1EAD);
    address alice = address(0xA11CE);

    uint256 deployerKey = 0xD3910;
    address deployer;

    Zorpha zor;
    VaultFactory factory;
    VaultLauncher launcher;

    bool forked;

    function setUp() public {
        string memory url = vm.envOr("RH_MAINNET_RPC_URL", string(""));
        if (bytes(url).length == 0) return;
        vm.createSelectFork(url);
        forked = true;

        deployer = vm.addr(deployerKey);
        vm.deal(deployer, 10 ether);

        // Stands in for DeployZorphaToken, which runs first and is unchanged.
        vm.prank(deployer);
        zor = new Zorpha(deployer);

        address[] memory targets = new address[](1);
        targets[0] = STEAK_USDG;

        // deploy(), not run(). run() reads env and broadcasts, and Foundry
        // cannot execute a broadcasting script from inside a test -- the first
        // renounceRole dies with ReentrancySentryOOG. The split exists so this
        // test drives the real deployment code rather than a copy.
        DeployMinimal d = new DeployMinimal();
        vm.prank(deployer);
        (factory, launcher) = d.deploy(address(d), gov, treasury, timelock, address(zor), targets);
    }

    modifier onlyForked() {
        if (!forked) { vm.skip(true); }
        _;
    }

    function _launch(uint256 salt) internal returns (YieldVault) {
        uint256 bond = launcher.bondAmount();
        uint256 seed = launcher.minSeedEscrow();

        vm.prank(deployer);
        zor.transfer(leader, bond);
        deal(USDG, leader, seed * 2);

        vm.startPrank(leader);
        zor.approve(address(launcher), bond);
        IERC20(USDG).approve(address(launcher), seed);
        (address vaultAddr,) = launcher.launchYieldVault(
            STEAK_USDG, seed, "Zorpha Steakhouse USDG", "zqSTEAK", bytes32(salt)
        );
        vm.stopPrank();
        return YieldVault(vaultAddr);
    }

    /// Every assertion the script makes about itself, re-made from outside it.
    /// A script that checks its own work is worth having; a script whose checks
    /// are the only ones is not.
    function test_TheDeployLandsInTheStateItClaims() public onlyForked {
        assertTrue(
            IAccessControl(address(factory)).hasRole(factory.DEPLOYER_ROLE(), address(launcher)),
            "launcher cannot deploy: the launchpad is inert"
        );
        assertTrue(IAccessControl(address(factory)).hasRole(0x00, timelock), "timelock is not factory admin");
        assertFalse(IAccessControl(address(factory)).hasRole(0x00, deployer), "deployer kept factory admin");
        assertTrue(IAccessControl(address(launcher)).hasRole(0x00, gov), "gov is not launcher admin");
        assertFalse(IAccessControl(address(launcher)).hasRole(0x00, deployer), "deployer kept launcher admin");
        assertTrue(launcher.approvedTarget(STEAK_USDG), "the venue was not approved");
    }

    /// The grant DeployLeadership leaves as a printed ACTION REQUIRED. Without
    /// it every contract reads as deployed and nobody can launch anything, which
    /// is the failure this dry run exists to make impossible to ship.
    function test_AStrangerCanLaunchOnRealSteakhouse() public onlyForked {
        YieldVault vault = _launch(1);
        assertTrue(address(vault) != address(0), "no vault came back");
        assertEq(vault.asset(), USDG, "the vault is not denominated in the venue asset");
        console2.log("launched vault:", address(vault));
    }

    /// And a depositor can actually use it, through the real venue.
    function test_ADepositorGoesInAndOutThroughTheRealVenue() public onlyForked {
        YieldVault vault = _launch(2);

        uint256 amount = 1_000 * ONE;
        deal(USDG, alice, amount);

        vm.startPrank(alice);
        IERC20(USDG).approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, alice);
        assertGt(shares, 0, "deposit minted nothing");
        uint256 out = vault.redeem(shares, alice, alice);
        vm.stopPrank();

        console2.log("deposited:", amount);
        console2.log("redeemed :", out);

        // Rounding down on the way in and out is the honest direction. What must
        // not happen is a depositor gaining at the expense of the vault.
        assertLe(out, amount, "the depositor withdrew more than they put in");
        assertGe(out, amount - 10, "more than rounding was lost on a round trip");
    }

    /// No price feed anywhere in the deployed set. That is the entire economic
    /// argument for this shape, so it is asserted rather than claimed.
    function test_NothingDeployedNeedsAPriceFeed() public onlyForked {
        YieldVault vault = _launch(3);

        // A spot vault answers this. A yield vault has no such function, and
        // that is precisely why it costs nothing to run.
        (bool hasOracle,) = address(vault).staticcall(abi.encodeWithSignature("oracle()"));
        assertFalse(hasOracle, "the launched vault exposes an oracle");

        // And it still values itself, with no feed to consult. A freshly
        // launched vault holds nothing -- the seed goes to the ESCROW, not the
        // vault -- so give it something to value first.
        uint256 amount = 1_000 * ONE;
        deal(USDG, alice, amount);
        vm.startPrank(alice);
        IERC20(USDG).approve(address(vault), amount);
        vault.deposit(amount, alice);
        vm.stopPrank();

        assertGe(vault.totalAssets(), amount, "the vault cannot value itself without an oracle");
    }
}

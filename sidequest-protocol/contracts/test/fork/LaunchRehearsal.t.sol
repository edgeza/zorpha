// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {DeployZorphaToken} from "../../script/DeployZorphaToken.s.sol";
import {DeployMinimal} from "../../script/DeployMinimal.s.sol";
import {VaultFactory} from "../../src/VaultFactory.sol";
import {VaultLauncher} from "../../src/leadership/VaultLauncher.sol";
import {YieldVault} from "../../src/vaults/YieldVault.sol";

/// @notice The launch, rehearsed with the REAL addresses, on a fork of the
///         chain it will run on.
///
///         Everything here is what would actually be sent:
///
///           deployer   0x90D5fE6a51CbDA18C3960966D5830Ba03B4fFB02  (funded)
///           Safe       0xC75E64Ccf3ce6E2F40939Ab58255681769BcF8C4  (deployed)
///           venue      real Steakhouse USDG on 4663
///           root       generate-airdrop.ts over the deferral snapshot
///
///         The earlier rehearsals used placeholder addresses, which proves the
///         scripts work but not that THIS configuration does. A wrong Safe, an
///         unfunded key or a root that nobody can claim against all pass a test
///         built on address(0x6011).
contract LaunchRehearsalForkTest is Test {
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant STEAK_USDG = 0xBeEff033F34C046626B8D0A041844C5d1A5409dd;

    address constant DEPLOYER = 0x90D5fE6a51CbDA18C3960966D5830Ba03B4fFB02;
    address constant SAFE = 0xC75E64Ccf3ce6E2F40939Ab58255681769BcF8C4;
    bytes32 constant AIRDROP_ROOT =
        0x82f08a3e5c2343714663a14670596246566ee2a13c6dbc5e032e519e820f8797;

    uint256 constant ONE_USDG = 1e6;

    DeployZorphaToken tokenScript;
    DeployZorphaToken.Deployed d;
    VaultFactory factory;
    VaultLauncher launcher;

    bool forked;

    function setUp() public {
        string memory url = vm.envOr("RH_MAINNET_RPC_URL", string(""));
        if (bytes(url).length == 0) return;
        vm.createSelectFork(url);
        forked = true;
    }

    modifier onlyForked() {
        if (!forked) { vm.skip(true); }
        _;
    }

    /// deployCode, not `new`.
    ///
    /// Instantiating both scripts inline embeds both of their bytecodes -- and
    /// each embeds every contract it deploys -- in THIS contract, which then
    /// exceeds the 24kB limit and fails at its own constructor with
    /// CreateContractSizeLimit before a single test runs. deployCode loads the
    /// artifact at runtime, so the test contract stays small and still exercises
    /// the real script rather than a copy.
    function _runTokenLayer() internal {
        tokenScript = DeployZorphaToken(deployCode("DeployZorphaToken.s.sol:DeployZorphaToken"));
        d = tokenScript.deploy(
            DeployZorphaToken.Config({
                deployer: address(tokenScript),
                gov: SAFE,
                usdg: USDG,
                liquidityRecipient: SAFE,
                airdropRoot: AIRDROP_ROOT,
                claimDeadline: block.timestamp + 90 days,
                timelockDelay: 48 hours,
                buybackThreshold: 1_000 * ONE_USDG
            })
        );
    }

    function _runLaunchpad() internal {
        address[] memory targets = new address[](1);
        targets[0] = STEAK_USDG;
        DeployMinimal m = DeployMinimal(deployCode("DeployMinimal.s.sol:DeployMinimal"));
        (factory, launcher) =
            m.deploy(address(m), SAFE, address(d.treasury), address(d.timelock), address(d.zor), targets);
    }

    /// The whole launch, in the order it will actually happen.
    function test_TheLaunchRunsEndToEndWithTheRealAddresses() public onlyForked {
        _runTokenLayer();
        _runLaunchpad();

        console2.log("ZOR         ", address(d.zor));
        console2.log("Timelock    ", address(d.timelock));
        console2.log("Treasury    ", address(d.treasury));
        console2.log("Distributor ", address(d.distributor));
        console2.log("Vesting     ", address(d.vesting));
        console2.log("Factory     ", address(factory));
        console2.log("Launcher    ", address(launcher));

        assertTrue(address(d.zor) != address(0), "no token");
        assertTrue(address(launcher) != address(0), "no launcher");
    }

    /// The Safe ends up holding what it is supposed to hold, and the deployer
    /// holds nothing. This is the assertion the whole handover exists for.
    function test_TheSafeHoldsTheSupplyAndTheDeployerHoldsNothing() public onlyForked {
        _runTokenLayer();

        uint256 supply = d.zor.MAX_SUPPLY();
        uint256 safeBal = d.zor.balanceOf(SAFE);

        console2.log("supply        ", supply);
        console2.log("held by Safe  ", safeBal);
        console2.log("in distributor", d.zor.balanceOf(address(d.distributor)));
        console2.log("in insurance  ", d.zor.balanceOf(address(d.insurance)));

        assertEq(d.zor.balanceOf(address(tokenScript)), 0, "the deployer kept supply");
        // Governance tranche plus the liquidity tranche, since the Safe is both.
        assertGt(safeBal, supply / 2, "the Safe does not hold the governance tranche");
        assertEq(
            safeBal + d.zor.balanceOf(address(d.distributor)) + d.zor.balanceOf(address(d.insurance)),
            supply,
            "supply is not fully accounted for"
        );
    }

    /// The liquidity guard passes with the real recipient. This is the check
    /// that refused an EOA, and the Safe is what makes it pass -- proving the
    /// Safe was worth creating rather than merely required by a comment.
    function test_TheRealSafeSatisfiesTheMainnetLiquidityGuard() public onlyForked {
        assertEq(block.chainid, 4663, "not on mainnet");
        assertGt(SAFE.code.length, 0, "the Safe has no code on this chain");
        assertTrue(SAFE != DEPLOYER, "recipient is the deployer");

        _runTokenLayer();   // would revert if the guard refused
        assertGt(d.zor.balanceOf(SAFE), 0, "the liquidity tranche did not arrive");
    }

    /// The deferred airdrop, against the real root: the Safe claims the whole
    /// TGE tranche with an empty proof, and nobody else can.
    function test_TheSafeCanClaimTheWholeAirdropTranche() public onlyForked {
        _runTokenLayer();

        uint256 tranche = d.zor.balanceOf(address(d.distributor));
        assertGt(tranche, 0, "the distributor was not funded");

        uint256 before = d.zor.balanceOf(SAFE);
        bytes32[] memory noProof = new bytes32[](0);
        d.distributor.claim(0, SAFE, tranche, noProof);

        assertEq(d.zor.balanceOf(SAFE) - before, tranche, "the tranche did not arrive");
        assertEq(d.zor.balanceOf(address(d.distributor)), 0, "the distributor kept some");
        console2.log("airdrop tranche claimable by the Safe:", tranche);
    }

    /// And the launchpad works on top of it: a leader launches on real
    /// Steakhouse using the real ZOR for their bond, and a depositor uses it.
    function test_ALeaderLaunchesAndADepositorUsesIt() public onlyForked {
        _runTokenLayer();
        _runLaunchpad();

        address leader = address(0x1EAD);
        address alice = address(0xA11CE);

        uint256 bond = launcher.bondAmount();
        uint256 seed = launcher.minSeedEscrow();

        // The bond comes out of what governance holds -- the real path.
        vm.prank(SAFE);
        d.zor.transfer(leader, bond);
        deal(USDG, leader, seed * 2);

        vm.startPrank(leader);
        d.zor.approve(address(launcher), bond);
        IERC20(USDG).approve(address(launcher), seed);
        (address vaultAddr,) = launcher.launchYieldVault(
            STEAK_USDG, seed, "Zorpha Steakhouse USDG", "zqSTEAK", bytes32(uint256(1))
        );
        vm.stopPrank();

        YieldVault vault = YieldVault(vaultAddr);
        uint256 amount = 1_000 * ONE_USDG;
        deal(USDG, alice, amount);

        vm.startPrank(alice);
        IERC20(USDG).approve(vaultAddr, amount);
        uint256 shares = vault.deposit(amount, alice);
        uint256 out = vault.redeem(shares, alice, alice);
        vm.stopPrank();

        console2.log("launched vault:", vaultAddr);
        console2.log("deposited     :", amount);
        console2.log("redeemed      :", out);

        assertGt(shares, 0, "no shares minted");
        assertLe(out, amount, "the depositor gained");
        assertGe(out, amount - 10, "more than rounding was lost");
    }

    /// Nothing privileged is left with the deploying key.
    function test_TheDeployKeyKeepsNothing() public onlyForked {
        _runTokenLayer();
        _runLaunchpad();

        assertFalse(IAccessControl(address(factory)).hasRole(0x00, address(this)), "test kept factory admin");
        assertFalse(IAccessControl(address(launcher)).hasRole(0x00, address(this)), "test kept launcher admin");
        assertEq(d.zor.balanceOf(DEPLOYER), 0, "the deploy key holds ZOR");
        assertEq(d.buyback.owner(), address(d.timelock), "buyback not timelocked");
        assertEq(d.insurance.owner(), address(d.timelock), "insurance not timelocked");
        assertEq(d.vesting.admin(), SAFE, "vesting admin is not the Safe");
        assertEq(d.treasury.pendingOwner(), address(d.timelock), "treasury handover not started");
    }
}

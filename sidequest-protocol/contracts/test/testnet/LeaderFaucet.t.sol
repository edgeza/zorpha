// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {LeaderFaucet} from "../../src/testnet/LeaderFaucet.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// A launcher stand-in exposing only the two parameters the faucet reads.
contract StubLauncher {
    uint256 public bondAmount = 10_000e18;
    uint256 public minSeedEscrow = 1_000e6;

    function setBond(uint256 v) external {
        bondAmount = v;
    }
}

/// The faucet that makes the leader programme usable by somebody other than
/// the person who deployed it.
///
/// The programme has been live since day one with exactly one participant,
/// because `launchYieldVault` needs 10,000 ZOR and Zorpha has no mint
/// function -- the whole supply is minted in the constructor. A stranger had to
/// ask governance for tokens by hand.
contract LeaderFaucetTest is Test {
    MockERC20 zor;
    MockERC20 usdg;
    StubLauncher launcher;
    LeaderFaucet faucet;

    address gov = makeAddr("gov");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant TESTNET = 46630;
    uint256 constant MAINNET = 4663;

    function setUp() public {
        vm.chainId(TESTNET);
        zor = new MockERC20("Zorpha", "ZOR", 18);
        usdg = new MockERC20("Test Global Dollar", "tUSDG", 6);
        launcher = new StubLauncher();
        faucet = new LeaderFaucet(address(zor), address(usdg), address(launcher), gov, 50);

        // Governance funds it with ten bonds' worth.
        zor.mint(address(faucet), 100_000e18);
    }

    // ─── The point of the thing ─────────────────────────────────────────────

    function test_Claim_PaysABondAndASeed() public {
        vm.prank(alice);
        faucet.claim();

        assertEq(zor.balanceOf(alice), 10_000e18, "alice should hold exactly one bond");
        assertEq(usdg.balanceOf(alice), 1_000e6, "and exactly one seed");
        assertEq(faucet.claimCount(), 1, "claim not counted");
        assertTrue(faucet.hasClaimed(alice), "claim not recorded");
    }

    function test_Claim_IsOncePerAddress() public {
        vm.prank(alice);
        faucet.claim();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LeaderFaucet.AlreadyClaimed.selector, alice));
        faucet.claim();

        assertEq(zor.balanceOf(alice), 10_000e18, "a second claim must not top them up");
    }

    function test_Claim_DifferentAddressesEachGetOne() public {
        vm.prank(alice);
        faucet.claim();
        vm.prank(bob);
        faucet.claim();

        assertEq(zor.balanceOf(alice), 10_000e18);
        assertEq(zor.balanceOf(bob), 10_000e18);
        assertEq(faucet.claimCount(), 2);
    }

    // ─── The refusal that matters most ──────────────────────────────────────

    /// A faucet handing out 10,000 real ZOR per caller is a hole in the
    /// treasury. This is a runtime check rather than a deploy-time flag,
    /// because the contract would otherwise be one funding mistake away from
    /// being drained on mainnet.
    function test_Claim_RevertsOnMainnet() public {
        vm.chainId(MAINNET);
        vm.prank(alice);
        vm.expectRevert(LeaderFaucet.NotOnMainnet.selector);
        faucet.claim();
    }

    /// And the chain check runs BEFORE the per-address guard, so an address
    /// that already claimed on testnet still gets the mainnet refusal rather
    /// than a misleading AlreadyClaimed.
    function test_Claim_MainnetCheckPrecedesEverythingElse() public {
        vm.prank(alice);
        faucet.claim();

        vm.chainId(MAINNET);
        vm.prank(alice);
        vm.expectRevert(LeaderFaucet.NotOnMainnet.selector);
        faucet.claim();
    }

    // ─── Bounds ─────────────────────────────────────────────────────────────

    function test_Claim_RespectsTheCap() public {
        vm.prank(gov);
        faucet.setMaxClaims(1);

        vm.prank(alice);
        faucet.claim();

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(LeaderFaucet.FaucetExhausted.selector, 1, 1));
        faucet.claim();
    }

    function test_Claim_RefusesWhenTheFloatIsGone() public {
        // Read BEFORE the prank. An external call inside a pranked call's
        // argument list consumes the prank, and `sweep` then runs as this
        // contract and reverts OwnableUnauthorizedAccount -- which is how this
        // test failed first time round, and the third time today.
        uint256 held = zor.balanceOf(address(faucet));
        vm.prank(gov);
        faucet.sweep(gov, held);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LeaderFaucet.FaucetEmpty.selector, 0, 10_000e18));
        faucet.claim();
    }

    /// `claimsRemaining` must be bounded by the FLOAT, not just the cap.
    /// Reporting "50 remaining" while holding three bonds would send
    /// forty-seven people into a revert.
    function test_ClaimsRemaining_IsBoundedByTheBalance() public {
        assertEq(faucet.claimsRemaining(), 10, "100k of ZOR is ten bonds, under a cap of 50");

        vm.prank(gov);
        faucet.sweep(gov, 70_000e18); // three bonds left

        assertEq(faucet.claimsRemaining(), 3, "must follow the balance down");
    }

    function test_ClaimsRemaining_IsBoundedByTheCap() public {
        zor.mint(address(faucet), 10_000_000e18); // far more than the cap allows
        vm.prank(gov);
        faucet.setMaxClaims(4);
        assertEq(faucet.claimsRemaining(), 4, "the cap must bind when the float is deep");
    }

    // ─── Coupling to the launcher ───────────────────────────────────────────

    /// The ticket is READ from the launcher, not copied at deploy. A faucet
    /// holding a stale bond amount hands out too little, and every launch
    /// attempt then reverts on an allowance the claimant cannot diagnose.
    function test_Ticket_FollowsTheLauncher() public {
        (uint256 bond0,) = faucet.ticket();
        assertEq(bond0, 10_000e18);

        launcher.setBond(25_000e18);

        (uint256 bond1,) = faucet.ticket();
        assertEq(bond1, 25_000e18, "the faucet must follow a governance change");

        vm.prank(alice);
        faucet.claim();
        assertEq(zor.balanceOf(alice), 25_000e18, "and pay the new amount");
    }

    // ─── Governance ─────────────────────────────────────────────────────────

    function test_Sweep_IsOwnerOnly() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice)
        );
        faucet.sweep(alice, 1);
    }

    function test_SetMaxClaims_IsOwnerOnly() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice)
        );
        faucet.setMaxClaims(999);
    }

    function test_Sweep_ReturnsTheFloat() public {
        uint256 held = zor.balanceOf(address(faucet));
        vm.prank(gov);
        faucet.sweep(gov, held);
        assertEq(zor.balanceOf(gov), held);
        assertEq(zor.balanceOf(address(faucet)), 0);
    }
}

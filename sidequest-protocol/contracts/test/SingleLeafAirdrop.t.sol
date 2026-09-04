// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MerkleDistributor} from "../src/MerkleDistributor.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice A one-recipient airdrop tree, which is the deferral option for the
///         mainnet launch: governance is the sole claimant, takes the whole TGE
///         tranche, and distributes later through a second distributor built
///         from the real recipient list.
///
///         It gets its own test because a single-leaf tree is a genuine edge
///         case. The proof array is EMPTY -- there are no siblings to hash
///         against -- so MerkleProof.verify has to conclude that the leaf is
///         itself the root. If it did not, the whole tranche would be locked in
///         the distributor until claimDeadline with nobody able to claim it, and
///         the failure would arrive at the first claim rather than at deploy.
///
///         Root and values are the verbatim output of generate-airdrop.ts over
///         a one-line snapshot naming the governance Safe.
contract SingleLeafAirdropTest is Test {
    MerkleDistributor dist;
    MockERC20 zor;

    address governanceSafe = 0xC75E64Ccf3ce6E2F40939Ab58255681769BcF8C4;
    address timelock = makeAddr("timelock");
    address stranger = makeAddr("stranger");

    bytes32 constant ROOT = 0x82f08a3e5c2343714663a14670596246566ee2a13c6dbc5e032e519e820f8797;
    uint256 constant AMOUNT = 80_000_000e18;

    function setUp() public {
        vm.warp(1_800_000_000);
        zor = new MockERC20("Zorpha", "ZOR", 18);
        dist = new MerkleDistributor(
            IERC20(address(zor)), ROOT, block.timestamp + 90 days, timelock
        );
        zor.mint(address(dist), AMOUNT);
    }

    function test_TheSoleClaimantCanClaimWithAnEmptyProof() public {
        bytes32[] memory noProof = new bytes32[](0);

        dist.claim(0, governanceSafe, AMOUNT, noProof);

        assertEq(zor.balanceOf(governanceSafe), AMOUNT, "the tranche did not arrive");
        assertEq(zor.balanceOf(address(dist)), 0, "the distributor kept some");
        assertTrue(dist.isClaimed(0), "the index was not marked");
    }

    /// The tree being one leaf must not make it claimable by anyone else. An
    /// empty proof plus a wrong account has to fail on the leaf, or a
    /// single-entry tree would be an open door.
    function test_AnEmptyProofDoesNotLetAnyoneElseClaim() public {
        bytes32[] memory noProof = new bytes32[](0);

        vm.expectRevert(MerkleDistributor.InvalidProof.selector);
        dist.claim(0, stranger, AMOUNT, noProof);
    }

    /// Nor for the right account at the wrong amount.
    function test_NorTheRightAccountAtTheWrongAmount() public {
        bytes32[] memory noProof = new bytes32[](0);

        vm.expectRevert(MerkleDistributor.InvalidProof.selector);
        dist.claim(0, governanceSafe, AMOUNT + 1, noProof);
    }

    /// And it still cannot be claimed twice, which is what makes the whole
    /// tranche moving in one transaction safe.
    function test_AndStillCannotBeClaimedTwice() public {
        bytes32[] memory noProof = new bytes32[](0);
        dist.claim(0, governanceSafe, AMOUNT, noProof);

        vm.expectRevert(abi.encodeWithSelector(MerkleDistributor.AlreadyClaimed.selector, uint256(0)));
        dist.claim(0, governanceSafe, AMOUNT, noProof);
    }
}

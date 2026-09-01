// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Zorpha} from "../src/Zorpha.sol";
import {MerkleDistributor} from "../src/MerkleDistributor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Airdrop generator parity
/// @notice Cross-checks the OFF-CHAIN Merkle generator against the ON-CHAIN
///         verifier using values the generator actually produced.
///
///         This is the one seam in the airdrop where a mistake is both easy and
///         catastrophic: if `scripts/generate-airdrop.ts` and
///         `MerkleDistributor.claim` disagree on leaf encoding, pair ordering,
///         or odd-node promotion, then every proof on the claim page fails for
///         real recipients with no diagnosable reason. Neither side's own tests
///         would notice, because each is self-consistent.
///
///         The root and proofs below are verbatim output of:
///
///           npx tsx sidequest-protocol/scripts/generate-airdrop.ts \
///             --snapshot snap.csv --out ./out
///
///         over a five-recipient snapshot — chosen odd so the odd-node
///         promotion path is exercised rather than the tidy power-of-two case.
///         If the generator's encoding ever changes, this test fails.
contract AirdropGeneratorParityTest is Test {
    Zorpha token;
    MerkleDistributor dist;

    address admin = makeAddr("admin");

    // Generated root.
    bytes32 constant ROOT = 0xbc34179ac69d1156ed2a4759f6310d6ab243e5d83e1069d23cfac77c032f5d20;

    address constant R0 = 0x1111111111111111111111111111111111111111;
    address constant R1 = 0x2222222222222222222222222222222222222222;
    address constant R2 = 0x3333333333333333333333333333333333333333;
    address constant R3 = 0x4444444444444444444444444444444444444444;
    address constant R4 = 0x5555555555555555555555555555555555555555;

    uint256 constant A0 = 1_000e18;
    uint256 constant A1 = 2_500e18;
    uint256 constant A2 = 750e18;
    uint256 constant A3 = 12_345e18;
    uint256 constant A4 = 1e18;

    uint256 constant TOTAL = A0 + A1 + A2 + A3 + A4; // 16,596 ZOR

    function setUp() public {
        vm.warp(1_700_000_000);
        token = new Zorpha(address(this));
        dist = new MerkleDistributor(
            IERC20(address(token)), ROOT, block.timestamp + 30 days, admin
        );
        token.transfer(address(dist), TOTAL);
    }

    function _proof0() internal pure returns (bytes32[] memory p) {
        p = new bytes32[](3);
        p[0] = 0x9ec8d5aa5127c13b6827f1d5cb7e6e37c16376ca48c6601752116820ca4f6706;
        p[1] = 0xe5c2d64704cd79faf31691ec900753324255f79855d1957bd13824b28a5877a8;
        p[2] = 0xab399c97089e888e8ef65cb19fd711992f15e5ba905848897cc28a50bc5cce8a;
    }

    function _proof1() internal pure returns (bytes32[] memory p) {
        p = new bytes32[](3);
        p[0] = 0xa808bdc9b7cad58e14299835b11f58eabfda13a079aba0111d7624fb067385f6;
        p[1] = 0xe5c2d64704cd79faf31691ec900753324255f79855d1957bd13824b28a5877a8;
        p[2] = 0xab399c97089e888e8ef65cb19fd711992f15e5ba905848897cc28a50bc5cce8a;
    }

    function _proof2() internal pure returns (bytes32[] memory p) {
        p = new bytes32[](3);
        p[0] = 0x0f206316dde8ac35e9d8e867cdf72dcc29ed79c8b08261d2531a52408d321104;
        p[1] = 0xfac1f26c8e269d58c81e7c25a618641283bca5b9dbf24e37193f9f2f22d70c01;
        p[2] = 0xab399c97089e888e8ef65cb19fd711992f15e5ba905848897cc28a50bc5cce8a;
    }

    function _proof3() internal pure returns (bytes32[] memory p) {
        p = new bytes32[](3);
        p[0] = 0x61086823917914dee94195a2ee3a36879b86383f1a2c41e98722b7d582eb5861;
        p[1] = 0xfac1f26c8e269d58c81e7c25a618641283bca5b9dbf24e37193f9f2f22d70c01;
        p[2] = 0xab399c97089e888e8ef65cb19fd711992f15e5ba905848897cc28a50bc5cce8a;
    }

    /// The 5th recipient sits alone at each level, so its proof is a single
    /// hash. This is the odd-node promotion path.
    function _proof4() internal pure returns (bytes32[] memory p) {
        p = new bytes32[](1);
        p[0] = 0xe704f96a39ec3d2a8bcc7639fc9fd41f4d73e2bffdf0bf9f5e26f883c3ca091f;
    }

    /// Every generated proof must be accepted by the contract.
    function test_EveryGeneratedProofIsAcceptedOnChain() public {
        dist.claim(0, R0, A0, _proof0());
        dist.claim(1, R1, A1, _proof1());
        dist.claim(2, R2, A2, _proof2());
        dist.claim(3, R3, A3, _proof3());
        dist.claim(4, R4, A4, _proof4());

        assertEq(token.balanceOf(R0), A0);
        assertEq(token.balanceOf(R1), A1);
        assertEq(token.balanceOf(R2), A2);
        assertEq(token.balanceOf(R3), A3);
        assertEq(token.balanceOf(R4), A4);

        // The distributor must be exactly emptied: the generator's reported
        // total and the tree's real contents agree.
        assertEq(token.balanceOf(address(dist)), 0, "generator total mismatch");
    }

    /// A recipient cannot reuse someone else's proof for their own address.
    function test_ProofIsNotTransferableBetweenRecipients() public {
        vm.expectRevert(MerkleDistributor.InvalidProof.selector);
        dist.claim(0, R1, A0, _proof0());
    }

    /// A recipient cannot pair their own proof with a larger amount.
    function test_ProofDoesNotAuthoriseADifferentAmount() public {
        vm.expectRevert(MerkleDistributor.InvalidProof.selector);
        dist.claim(3, R3, A3 + 1, _proof3());
    }

    /// The odd-node promotion must not make the lone leaf forgeable — a
    /// duplicated-node tree builder would let index 4 be claimed twice under
    /// two different indices.
    function test_OddNodeLeafCannotBeClaimedUnderAnotherIndex() public {
        vm.expectRevert(MerkleDistributor.InvalidProof.selector);
        dist.claim(5, R4, A4, _proof4());
    }
}

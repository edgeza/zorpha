// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {StrategyExecutor, ISpotRebalancer} from "../../src/executor/StrategyExecutor.sol";

contract Rebalancer is ISpotRebalancer {
    uint16 public lastWeight;
    uint256 public callCount;
    function rebalanceTo(uint16 w) external { lastWeight = w; callCount += 1; }
}

/// @notice A Safe-shaped signer: a contract that answers EIP-1271 by checking a
///         signature against an owner set and a threshold.
///
///         Deliberately not a stub returning a constant. The point of the change
///         under test is that a MULTI-PARTY signer works -- a hardware wallet and
///         a service key together -- and a mock that said yes to everything would
///         pass whether or not the executor actually asked it anything.
contract SafeLikeSigner {
    bytes4 internal constant MAGIC = 0x1626ba7e;

    mapping(address => bool) public isOwner;
    uint256 public threshold;

    constructor(address[] memory owners_, uint256 threshold_) {
        for (uint256 i = 0; i < owners_.length; i++) isOwner[owners_[i]] = true;
        threshold = threshold_;
    }

    function setOwner(address who, bool on) external { isOwner[who] = on; }

    /// Concatenated 65-byte signatures; each must recover to a distinct owner.
    function isValidSignature(bytes32 hash, bytes calldata sigs) external view returns (bytes4) {
        if (sigs.length % 65 != 0) return 0xffffffff;
        uint256 n = sigs.length / 65;
        if (n < threshold) return 0xffffffff;

        address last = address(0);
        for (uint256 i = 0; i < n; i++) {
            bytes calldata one = sigs[i * 65:(i + 1) * 65];
            bytes32 r = bytes32(one[0:32]);
            bytes32 s = bytes32(one[32:64]);
            uint8 v = uint8(one[64]);
            address rec = ecrecover(hash, v, r, s);
            if (rec == address(0) || !isOwner[rec]) return 0xffffffff;
            // Ascending order forces distinct owners, as Safe does.
            if (rec <= last) return 0xffffffff;
            last = rec;
        }
        return MAGIC;
    }
}

/// @notice Who may sign, and in what form.
///
///         Two limits were load-bearing and neither was written down as a
///         decision: authorizedSigner was ONE address for every vault, and it
///         was verified with a bare ecrecover, so it had to be an EOA. Together
///         they meant a strategy operated by a person and one operated by an
///         algorithm had to share a private key -- the exact arrangement the
///         rest of this codebase exists to prevent -- and that rotating a signer
///         for one vault rotated it for all of them.
contract SignerFlexibilityTest is Test {
    StrategyExecutor executor;
    Rebalancer vaultA;
    Rebalancer vaultB;

    uint256 humanPk = 0xA11CE;
    uint256 algoPk = 0xB0B;
    uint256 strangerPk = 0xBAD;
    address human;
    address algo;
    address stranger;

    function setUp() public {
        vm.warp(1_800_000_000);
        executor = new StrategyExecutor(address(this));
        vaultA = new Rebalancer();
        vaultB = new Rebalancer();
        human = vm.addr(humanPk);
        algo = vm.addr(algoPk);
        stranger = vm.addr(strangerPk);

        executor.grantRole(executor.KEEPER_ROLE(), address(this));
        executor.setDailyLimit(address(vaultA), 20);
        executor.setDailyLimit(address(vaultB), 20);
        executor.setAuthorizedSigner(human);
    }

    function _digest(address v, uint16 w, uint256 nonce, uint256 expiry) internal view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(executor.REBALANCE_TYPEHASH(), v, w, nonce, expiry));
        return keccak256(abi.encodePacked(hex"1901", executor.DOMAIN_SEPARATOR(), structHash));
    }

    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _go(address v, uint256 pk, uint256 nonce) internal {
        uint256 exp = block.timestamp + 600;
        executor.executeRebalance(v, 5000, nonce, exp, _sign(pk, _digest(v, 5000, nonce, exp)));
    }

    // --- The EOA path is unchanged ------------------------------------------

    function test_AnEoaSignerStillWorksExactlyAsBefore() public {
        _go(address(vaultA), humanPk, 1);
        assertEq(vaultA.callCount(), 1, "an EOA signature stopped working");
    }

    function test_AndTheWrongEoaIsStillRefused() public {
        uint256 exp = block.timestamp + 600;
        // Built BEFORE expectRevert on purpose: _digest calls
        // executor.REBALANCE_TYPEHASH(), and that external call would consume
        // the expectation, leaving the real call unguarded and the test green
        // against a contract that never refused anything.
        bytes memory badSig = _sign(strangerPk, _digest(address(vaultA), 5000, 1, exp));
        vm.expectRevert(StrategyExecutor.InvalidSignature.selector);
        executor.executeRebalance(address(vaultA), 5000, 1, exp, badSig);
    }

    /// The hand-rolled verifier enforced low-s explicitly. SignatureChecker
    /// routes EOAs through the OpenZeppelin ECDSA library, which rejects a
    /// high-s value too, so the property survives the rewrite rather than being
    /// assumed to.
    function test_AHighSSignatureIsStillRefused() public {
        uint256 exp = block.timestamp + 600;
        bytes32 digest = _digest(address(vaultA), 5000, 1, exp);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(humanPk, digest);

        uint256 N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 highS = bytes32(N - uint256(s));
        uint8 flipped = v == 27 ? 28 : 27;

        vm.expectRevert(StrategyExecutor.InvalidSignature.selector);
        executor.executeRebalance(address(vaultA), 5000, 1, exp, abi.encodePacked(r, highS, flipped));
    }

    // --- Per-vault signers ---------------------------------------------------

    function test_AVaultWithNoOverrideUsesTheDefault() public view {
        assertEq(executor.signerFor(address(vaultA)), human, "default not applied");
        assertEq(executor.vaultSigner(address(vaultA)), address(0), "an override appeared from nowhere");
    }

    /// The thing that was impossible: one vault signed by a person, another by
    /// an algorithm, on the same executor.
    function test_TwoVaultsCanHaveTwoDifferentSigners() public {
        executor.setVaultSigner(address(vaultB), algo);

        assertEq(executor.signerFor(address(vaultA)), human);
        assertEq(executor.signerFor(address(vaultB)), algo);

        _go(address(vaultA), humanPk, 1);
        _go(address(vaultB), algoPk, 1);
        assertEq(vaultA.callCount(), 1, "the human could not sign for vault A");
        assertEq(vaultB.callCount(), 1, "the algo could not sign for vault B");
    }

    /// And the separation holds in both directions, which is the whole value:
    /// compromising one operator does not reach the vault of the other.
    function test_AndNeitherCanSignForTheVaultOfTheOther() public {
        executor.setVaultSigner(address(vaultB), algo);

        uint256 exp = block.timestamp + 600;
        // Built BEFORE expectRevert on purpose: _digest calls
        // executor.REBALANCE_TYPEHASH(), and that external call would consume
        // the expectation, leaving the real call unguarded and the test green
        // against a contract that never refused anything.
        bytes memory badSig = _sign(humanPk, _digest(address(vaultB), 5000, 1, exp));
        vm.expectRevert(StrategyExecutor.InvalidSignature.selector);
        executor.executeRebalance(address(vaultB), 5000, 1, exp, badSig);

        // Built BEFORE expectRevert on purpose: _digest calls
        // executor.REBALANCE_TYPEHASH(), and that external call would consume
        // the expectation, leaving the real call unguarded and the test green
        // against a contract that never refused anything.
        bytes memory badSig2 = _sign(algoPk, _digest(address(vaultA), 5000, 1, exp));
        vm.expectRevert(StrategyExecutor.InvalidSignature.selector);
        executor.executeRebalance(address(vaultA), 5000, 1, exp, badSig2);
    }

    function test_ClearingAnOverrideRestoresTheDefault() public {
        executor.setVaultSigner(address(vaultB), algo);
        executor.setVaultSigner(address(vaultB), address(0));
        assertEq(executor.signerFor(address(vaultB)), human, "zero did not clear the override");
        _go(address(vaultB), humanPk, 1);
    }

    function test_SettingAVaultSignerIsAdminOnly() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, bytes32(0)
            )
        );
        executor.setVaultSigner(address(vaultA), stranger);
    }

    function test_AVaultSignerCannotBeSetForTheZeroVault() public {
        vm.expectRevert(StrategyExecutor.ZeroVault.selector);
        executor.setVaultSigner(address(0), algo);
    }

    // --- EIP-1271 -------------------------------------------------------------

    /// A 2-of-2 Safe as the signer: the hardware wallet of the human and the
    /// service key of the algorithm must BOTH sign before the rebalance is
    /// valid. Impossible while the verifier was a bare ecrecover against one EOA.
    function test_ASafeCanBeTheSignerAndRequireBothParties() public {
        address[] memory owners = new address[](2);
        (owners[0], owners[1]) = human < algo ? (human, algo) : (algo, human);
        SafeLikeSigner safe = new SafeLikeSigner(owners, 2);
        executor.setVaultSigner(address(vaultA), address(safe));

        uint256 exp = block.timestamp + 600;
        bytes32 digest = _digest(address(vaultA), 5000, 1, exp);

        // Owners must appear in ascending order, as a real Safe requires.
        (uint256 lo, uint256 hi) = human < algo ? (humanPk, algoPk) : (algoPk, humanPk);
        bytes memory both = bytes.concat(_sign(lo, digest), _sign(hi, digest));

        executor.executeRebalance(address(vaultA), 5000, 1, exp, both);
        assertEq(vaultA.callCount(), 1, "a 2-of-2 contract signature was refused");
    }

    /// One of the two is not enough, and the executor learns that from the Safe
    /// rather than deciding it -- proof the 1271 call is actually being made.
    function test_OneSignatureOnATwoOfTwoSafeIsRefused() public {
        address[] memory owners = new address[](2);
        (owners[0], owners[1]) = human < algo ? (human, algo) : (algo, human);
        SafeLikeSigner safe = new SafeLikeSigner(owners, 2);
        executor.setVaultSigner(address(vaultA), address(safe));

        uint256 exp = block.timestamp + 600;
        // Built BEFORE expectRevert on purpose: _digest calls
        // executor.REBALANCE_TYPEHASH(), and that external call would consume
        // the expectation, leaving the real call unguarded and the test green
        // against a contract that never refused anything.
        bytes memory badSig = _sign(humanPk, _digest(address(vaultA), 5000, 1, exp));
        vm.expectRevert(StrategyExecutor.InvalidSignature.selector);
        executor.executeRebalance(address(vaultA), 5000, 1, exp, badSig);
    }

    /// The operational payoff: an operator is removed inside the Safe, with no
    /// executor transaction and no governance delay. The same key that worked a
    /// moment ago stops working, and the executor is untouched.
    function test_RemovingAnOwnerInTheSafeRevokesTheirSigningRights() public {
        address[] memory owners = new address[](1);
        owners[0] = algo;
        SafeLikeSigner safe = new SafeLikeSigner(owners, 1);
        executor.setVaultSigner(address(vaultA), address(safe));

        uint256 exp = block.timestamp + 600;
        executor.executeRebalance(
            address(vaultA), 5000, 1, exp, _sign(algoPk, _digest(address(vaultA), 5000, 1, exp))
        );
        assertEq(vaultA.callCount(), 1);

        safe.setOwner(algo, false);

        // Built BEFORE expectRevert on purpose: _digest calls
        // executor.REBALANCE_TYPEHASH(), and that external call would consume
        // the expectation, leaving the real call unguarded and the test green
        // against a contract that never refused anything.
        bytes memory badSig = _sign(algoPk, _digest(address(vaultA), 5000, 2, exp));
        vm.expectRevert(StrategyExecutor.InvalidSignature.selector);
        executor.executeRebalance(address(vaultA), 5000, 2, exp, badSig);
        assertEq(executor.signerFor(address(vaultA)), address(safe), "the executor was changed instead");
    }

    /// A contract that is not a 1271 signer at all must fail closed. Reverting,
    /// returning nothing, or returning the wrong magic value all mean no.
    function test_AContractThatIsNotASignerFailsClosed() public {
        executor.setVaultSigner(address(vaultA), address(vaultB));   // a plain Rebalancer

        uint256 exp = block.timestamp + 600;
        // Built BEFORE expectRevert on purpose: _digest calls
        // executor.REBALANCE_TYPEHASH(), and that external call would consume
        // the expectation, leaving the real call unguarded and the test green
        // against a contract that never refused anything.
        bytes memory badSig = _sign(humanPk, _digest(address(vaultA), 5000, 1, exp));
        vm.expectRevert(StrategyExecutor.InvalidSignature.selector);
        executor.executeRebalance(address(vaultA), 5000, 1, exp, badSig);
    }

    /// The nonce still closes replay for a contract signer, where the 65-byte
    /// length check that used to sit in the verifier no longer applies.
    function test_AContractSignatureCannotBeReplayed() public {
        address[] memory owners = new address[](1);
        owners[0] = algo;
        SafeLikeSigner safe = new SafeLikeSigner(owners, 1);
        executor.setVaultSigner(address(vaultA), address(safe));

        uint256 exp = block.timestamp + 600;
        bytes memory sig = _sign(algoPk, _digest(address(vaultA), 5000, 1, exp));
        executor.executeRebalance(address(vaultA), 5000, 1, exp, sig);

        vm.expectRevert(
            abi.encodeWithSelector(StrategyExecutor.NonceAlreadyUsed.selector, address(vaultA), 1)
        );
        executor.executeRebalance(address(vaultA), 5000, 1, exp, sig);
    }
}

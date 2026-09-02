// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {StrategyExecutor} from "../../src/executor/StrategyExecutor.sol";
import {ISpotRebalancer} from "../../src/executor/StrategyExecutor.sol";
import {IBasketRebalancer} from "../../src/executor/StrategyExecutor.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockOracle} from "../mocks/MockOracle.sol";
import {MockSpotAdapter} from "../mocks/MockSpotAdapter.sol";
import {SpotVaultMinimal} from "../../src/vaults/SpotVaultMinimal.sol";

contract MockSpotRebalancer is ISpotRebalancer {
    uint16 public lastWeight;
    uint256 public callCount;
    function rebalanceTo(uint16 w) external {
        lastWeight = w;
        callCount += 1;
    }
}

contract MockBasketRebalancer is IBasketRebalancer {
    uint16[] private _last;
    uint256 public callCount;
    bool public revertNext;

    function setRevertNext(bool v) external { revertNext = v; }

    function rebalanceTo(uint16[] calldata w) external {
        require(!revertNext, "MockBasketRebalancer: refused");
        delete _last;
        for (uint256 i = 0; i < w.length; i++) _last.push(w[i]);
        callCount += 1;
    }

    function lastWeightAt(uint256 i) external view returns (uint16) { return _last[i]; }
    function lastLength() external view returns (uint256) { return _last.length; }
}

contract StrategyExecutorTest is Test {
    StrategyExecutor executor;
    MockSpotRebalancer vault;
    uint256 signerPk;
    address signer;

    function setUp() public {
        executor = new StrategyExecutor(address(this));
        vault = new MockSpotRebalancer();
        signerPk = 0xA11CE;
        signer = vm.addr(signerPk);
        executor.setAuthorizedSigner(signer);
        executor.grantRole(executor.KEEPER_ROLE(), address(this));
        // Wire daily limit
        executor.setDailyLimit(address(vault), 5);
    }

    function _signRebalance(address v, uint16 weight, uint256 nonce, uint256 expiry)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(
            abi.encode(executor.REBALANCE_TYPEHASH(), v, weight, nonce, expiry)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", executor.DOMAIN_SEPARATOR(), structHash));
        (uint8 vSig, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        return abi.encodePacked(r, s, vSig);
    }

    function test_ValidSignature_Rebalances() public {
        uint16 weight = 5000;
        uint256 nonce = 1;
        uint256 expiry = block.timestamp + 1 days;
        bytes memory sig = _signRebalance(address(vault), weight, nonce, expiry);

        bool ok = executor.executeRebalance(address(vault), weight, nonce, expiry, sig);
        assertTrue(ok);
        assertEq(vault.lastWeight(), weight);
        assertEq(vault.callCount(), 1);
        assertEq(executor.nonces(address(vault)), 1);
    }

    function test_ReplayedNonce_Reverts() public {
        uint16 weight = 5000;
        uint256 nonce = 1;
        uint256 expiry = block.timestamp + 1 days;
        bytes memory sig = _signRebalance(address(vault), weight, nonce, expiry);
        executor.executeRebalance(address(vault), weight, nonce, expiry, sig);
        vm.expectRevert();
        executor.executeRebalance(address(vault), weight, nonce, expiry, sig);
    }

    function test_ExpiredSignal_Reverts() public {
        uint16 weight = 5000;
        uint256 nonce = 1;
        uint256 expiry = block.timestamp - 1;
        bytes memory sig = _signRebalance(address(vault), weight, nonce, expiry);
        vm.expectRevert();
        executor.executeRebalance(address(vault), weight, nonce, expiry, sig);
    }

    function test_ExpiryTooFar_Reverts() public {
        uint16 weight = 5000;
        uint256 nonce = 1;
        uint256 expiry = block.timestamp + 30 days;
        bytes memory sig = _signRebalance(address(vault), weight, nonce, expiry);
        vm.expectRevert();
        executor.executeRebalance(address(vault), weight, nonce, expiry, sig);
    }

    function test_BadWeight_Reverts() public {
        uint16 weight = 10001;
        uint256 nonce = 1;
        uint256 expiry = block.timestamp + 1 days;
        bytes memory sig = _signRebalance(address(vault), weight, nonce, expiry);
        vm.expectRevert();
        executor.executeRebalance(address(vault), weight, nonce, expiry, sig);
    }

    function test_WrongSigner_Reverts() public {
        address wrong = vm.addr(0xBADBEEF);
        executor.setAuthorizedSigner(wrong);

        uint16 weight = 5000;
        uint256 nonce = 1;
        uint256 expiry = block.timestamp + 1 days;
        bytes memory sig = _signRebalance(address(vault), weight, nonce, expiry);
        vm.expectRevert();
        executor.executeRebalance(address(vault), weight, nonce, expiry, sig);
    }

    function test_Pause_BlocksExecution() public {
        executor.setPaused(true);
        uint16 weight = 5000;
        uint256 nonce = 1;
        uint256 expiry = block.timestamp + 1 days;
        bytes memory sig = _signRebalance(address(vault), weight, nonce, expiry);
        vm.expectRevert();
        executor.executeRebalance(address(vault), weight, nonce, expiry, sig);
    }

    function test_DailyLimit_After5_Reverts() public {
        for (uint256 i = 0; i < 5; i++) {
            uint16 weight = uint16(2000 * (i + 1));
            uint256 nonce = i + 1;
            uint256 expiry = block.timestamp + 1 days;
            bytes memory sig = _signRebalance(address(vault), weight, nonce, expiry);
            executor.executeRebalance(address(vault), weight, nonce, expiry, sig);
        }
        // 6th within same day should revert.
        uint16 weight = 100;
        uint256 nonce = 6;
        uint256 expiry = block.timestamp + 1 days;
        bytes memory sig = _signRebalance(address(vault), weight, nonce, expiry);
        vm.expectRevert();
        executor.executeRebalance(address(vault), weight, nonce, expiry, sig);
    }

    /// NOTE: timepoints are derived from literals, never from a read of
    /// `block.timestamp`. foundry.toml sets `via_ir = true`, and the IR
    /// optimiser rematerialises the TIMESTAMP opcode at each use instead of
    /// caching it, so a local assigned `block.timestamp` before a `vm.warp`
    /// silently reports the pre-warp value afterwards. That is what made this
    /// test sign an expiry of 86401 while the chain was already at 86402.
    function test_DailyLimit_WindowSlides() public {
        uint256 t0 = 1_700_000_000;
        vm.warp(t0);

        for (uint256 i = 0; i < 5; i++) {
            uint16 weight = uint16(2000 * (i + 1));
            uint256 nonce = i + 1;
            uint256 expiry = t0 + 1 days;
            bytes memory sig = _signRebalance(address(vault), weight, nonce, expiry);
            executor.executeRebalance(address(vault), weight, nonce, expiry, sig);
        }

        // The 6th within the same window is refused.
        {
            bytes memory sig = _signRebalance(address(vault), 100, 6, t0 + 1 days);
            vm.expectRevert(
                abi.encodeWithSelector(StrategyExecutor.DailyLimitExceeded.selector, 5, 5)
            );
            executor.executeRebalance(address(vault), 100, 6, t0 + 1 days, sig);
        }

        // Roll past the window; the limit resets and the same command lands.
        uint256 t1 = t0 + 1 days + 1;
        vm.warp(t1);
        assertEq(executor.getRecentRebalanceCount(address(vault)), 0, "window must have drained");

        uint256 expiry1 = t1 + 1 days;
        bytes memory sig1 = _signRebalance(address(vault), 100, 6, expiry1);
        assertTrue(executor.executeRebalance(address(vault), 100, 6, expiry1, sig1));
        assertEq(executor.getRecentRebalanceCount(address(vault)), 1);
    }

    // --- Basket rebalance ---------------------------------------------------
    //
    // RWRotationVault takes rebalanceTo(uint16[]), a different selector from
    // the single-weight form. Before executeBasketRebalance existed the
    // executor could only call the latter, so it reverted with empty data
    // against a rotation vault -- and because the deploy grants KEEPER_ROLE on
    // each vault only to the executor, nothing else could call the array form
    // either. The rotation vault shipped unable to rebalance by any route
    // while the portal advertised it as rotating on a signed mandate.

    function _signBasket(address v, uint16[] memory w, uint256 nonce, uint256 expiry)
        internal
        view
        returns (bytes memory)
    {
        uint256[] memory padded = new uint256[](w.length);
        for (uint256 i = 0; i < w.length; i++) padded[i] = w[i];
        bytes32 structHash = keccak256(
            abi.encode(
                executor.BASKET_REBALANCE_TYPEHASH(),
                v,
                keccak256(abi.encodePacked(padded)),
                nonce,
                expiry
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", executor.DOMAIN_SEPARATOR(), structHash));
        (uint8 vSig, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        return abi.encodePacked(r, s, vSig);
    }

    function _basket() internal returns (MockBasketRebalancer b) {
        b = new MockBasketRebalancer();
        executor.setDailyLimit(address(b), 5);
    }

    function test_Basket_ValidSignatureRebalances() public {
        MockBasketRebalancer b = _basket();
        uint16[] memory w = new uint16[](2);
        w[0] = 6000;
        w[1] = 4000;
        uint256 expiry = block.timestamp + 1 days;

        executor.executeBasketRebalance(address(b), w, 1, expiry, _signBasket(address(b), w, 1, expiry));

        assertEq(b.callCount(), 1, "the vault must actually be called");
        assertEq(b.lastWeightAt(0), 6000);
        assertEq(b.lastWeightAt(1), 4000);
        assertEq(executor.nonces(address(b)), 1, "nonce consumed");
    }

    /// The weights are part of what is signed, so altering one after signing
    /// must fail. Without hashing the array into the struct this would pass.
    function test_Basket_TamperedWeightsRejected() public {
        MockBasketRebalancer b = _basket();
        uint16[] memory signed = new uint16[](2);
        signed[0] = 6000;
        signed[1] = 4000;
        uint256 expiry = block.timestamp + 1 days;
        bytes memory sig = _signBasket(address(b), signed, 1, expiry);

        uint16[] memory tampered = new uint16[](2);
        tampered[0] = 9000;
        tampered[1] = 1000;

        vm.expectRevert(StrategyExecutor.InvalidSignature.selector);
        executor.executeBasketRebalance(address(b), tampered, 1, expiry, sig);
    }

    /// Reordering is a different instruction, not the same one. A hash over
    /// concatenated elements catches it; a sum or a length check would not.
    function test_Basket_ReorderedWeightsRejected() public {
        MockBasketRebalancer b = _basket();
        uint16[] memory signed = new uint16[](2);
        signed[0] = 6000;
        signed[1] = 4000;
        uint256 expiry = block.timestamp + 1 days;
        bytes memory sig = _signBasket(address(b), signed, 1, expiry);

        uint16[] memory swapped = new uint16[](2);
        swapped[0] = 4000;
        swapped[1] = 6000;

        vm.expectRevert(StrategyExecutor.InvalidSignature.selector);
        executor.executeBasketRebalance(address(b), swapped, 1, expiry, sig);
    }

    /// The two commands are distinct EIP-712 types on purpose. If they shared a
    /// typehash, authority to set one weight would be authority to set a whole
    /// basket, which is a strictly larger permission.
    function test_Basket_SpotSignatureCannotBeReplayedAsBasket() public {
        MockBasketRebalancer b = _basket();
        uint256 expiry = block.timestamp + 1 days;

        bytes memory spotSig = _signRebalance(address(b), 6000, 1, expiry);

        uint16[] memory w = new uint16[](1);
        w[0] = 6000;

        vm.expectRevert(StrategyExecutor.InvalidSignature.selector);
        executor.executeBasketRebalance(address(b), w, 1, expiry, spotSig);
    }

    function test_Basket_ReplayRejected() public {
        MockBasketRebalancer b = _basket();
        uint16[] memory w = new uint16[](2);
        w[0] = 5000;
        w[1] = 5000;
        uint256 expiry = block.timestamp + 1 days;
        bytes memory sig = _signBasket(address(b), w, 1, expiry);

        executor.executeBasketRebalance(address(b), w, 1, expiry, sig);
        vm.expectRevert(
            abi.encodeWithSelector(StrategyExecutor.NonceAlreadyUsed.selector, address(b), 1)
        );
        executor.executeBasketRebalance(address(b), w, 1, expiry, sig);
    }

    function test_Basket_ExpiredRejected() public {
        MockBasketRebalancer b = _basket();
        uint16[] memory w = new uint16[](1);
        w[0] = 10000;
        uint256 expiry = block.timestamp - 1;
        // Signature computed BEFORE vm.expectRevert, not inside the call
        // arguments. _signBasket reads BASKET_REBALANCE_TYPEHASH and
        // DOMAIN_SEPARATOR off the executor, and those external calls consume
        // the single-shot expectation -- so the revert is attributed to a view
        // call that does not revert, and the test fails with "next call did not
        // revert as expected" while the contract behaves correctly. The same
        // trap with vm.prank is already documented in this file.
        bytes memory sig = _signBasket(address(b), w, 1, expiry);
        vm.expectRevert(
            abi.encodeWithSelector(StrategyExecutor.SignalExpired.selector, expiry, block.timestamp)
        );
        executor.executeBasketRebalance(address(b), w, 1, expiry, sig);
    }

    function test_Basket_RateLimitBites() public {
        MockBasketRebalancer b = new MockBasketRebalancer();
        executor.setDailyLimit(address(b), 2);
        uint16[] memory w = new uint16[](1);
        w[0] = 10000;
        uint256 expiry = block.timestamp + 1 days;

        executor.executeBasketRebalance(address(b), w, 1, expiry, _signBasket(address(b), w, 1, expiry));
        executor.executeBasketRebalance(address(b), w, 2, expiry, _signBasket(address(b), w, 2, expiry));

        // Signature computed BEFORE vm.expectRevert, not inside the call
        // arguments. _signBasket reads BASKET_REBALANCE_TYPEHASH and
        // DOMAIN_SEPARATOR off the executor, and those external calls consume
        // the single-shot expectation -- so the revert is attributed to a view
        // call that does not revert, and the test fails with "next call did not
        // revert as expected" while the contract behaves correctly. The same
        // trap with vm.prank is already documented in this file.
        bytes memory third = _signBasket(address(b), w, 3, expiry);
        vm.expectRevert(abi.encodeWithSelector(StrategyExecutor.DailyLimitExceeded.selector, 2, 2));
        executor.executeBasketRebalance(address(b), w, 3, expiry, third);

        assertEq(b.callCount(), 2, "the rejected one must not reach the vault");
    }

    /// A keeper may submit and must not be able to decide, on this path too.
    function test_Basket_WrongSignerRejected() public {
        MockBasketRebalancer b = _basket();
        uint16[] memory w = new uint16[](1);
        w[0] = 10000;
        uint256 expiry = block.timestamp + 1 days;

        uint256[] memory padded = new uint256[](1);
        padded[0] = 10000;
        bytes32 structHash = keccak256(
            abi.encode(
                executor.BASKET_REBALANCE_TYPEHASH(),
                address(b),
                keccak256(abi.encodePacked(padded)),
                uint256(1),
                expiry
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", executor.DOMAIN_SEPARATOR(), structHash));
        (uint8 vSig, bytes32 r, bytes32 s) = vm.sign(uint256(0xBADBAD), digest);

        vm.expectRevert(StrategyExecutor.InvalidSignature.selector);
        executor.executeBasketRebalance(address(b), w, 1, expiry, abi.encodePacked(r, s, vSig));
    }

    /// The vault owns basket validity, and its revert must unwind the nonce and
    /// the rate-limit slot with it. Otherwise a basket the vault refuses would
    /// still burn a nonce, and the manager would have to re-sign to retry.
    function test_Basket_VaultRevertConsumesNothing() public {
        MockBasketRebalancer b = _basket();
        b.setRevertNext(true);
        uint16[] memory w = new uint16[](1);
        w[0] = 10000;
        uint256 expiry = block.timestamp + 1 days;

        // Signature computed BEFORE vm.expectRevert, not inside the call
        // arguments. _signBasket reads BASKET_REBALANCE_TYPEHASH and
        // DOMAIN_SEPARATOR off the executor, and those external calls consume
        // the single-shot expectation -- so the revert is attributed to a view
        // call that does not revert, and the test fails with "next call did not
        // revert as expected" while the contract behaves correctly. The same
        // trap with vm.prank is already documented in this file.
        bytes memory sig = _signBasket(address(b), w, 1, expiry);
        vm.expectRevert("MockBasketRebalancer: refused");
        executor.executeBasketRebalance(address(b), w, 1, expiry, sig);

        assertEq(executor.nonces(address(b)), 0, "nonce must not survive a vault revert");
        assertEq(b.callCount(), 0);
    }
}

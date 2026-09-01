// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {StrategyExecutor} from "../../src/executor/StrategyExecutor.sol";
import {ISpotRebalancer} from "../../src/executor/StrategyExecutor.sol";
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
}

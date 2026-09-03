// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {SpotVaultMinimal} from "../../src/vaults/SpotVaultMinimal.sol";
import {MedianOracle} from "../../src/oracle/MedianOracle.sol";
import {OracleWindow} from "../../src/oracle/OracleWindow.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockOracle} from "../mocks/MockOracle.sol";

/// @notice A vault must never be given a staleness window TIGHTER than the
///         oracle it reads.
///
///         `MedianOracle.latestRoundData` reports the OLDEST contributing
///         timestamp, and a report contributes while it is inside the ORACLE's
///         window. So a vault whose own window is shorter reverts StaleOracle
///         on a price that a fresh report is sitting right next to -- the
///         median is current, the timestamp is not, and nothing says why.
///
///         Measured on testnet 46630 before this was enforced: a 90s vault
///         against the 3600s production oracle saw `age 541s` moments after a
///         price was posted, because a second updater's older report was still
///         inside the oracle's window and pinned the timestamp.
///
///         These tests pin the boundary rather than a comfortable value, since
///         equality is the case a careless deploy lands on.
contract OracleWindowTest is Test {
    MockERC20 asset;
    MockERC20 cash;

    function setUp() public {
        asset = new MockERC20("Equity", "EQ", 18);
        cash = new MockERC20("Stable", "ST", 6);
    }

    function _median(uint256 window) internal returns (MedianOracle) {
        return new MedianOracle(8, window, 1, type(int256).max, 1, address(this));
    }

    function _deploy(address oracle, uint256 vaultWindow) internal returns (SpotVaultMinimal) {
        return new SpotVaultMinimal(
            address(asset),
            address(cash),
            oracle,
            vaultWindow,
            "Vault",
            "V",
            200,
            100,
            0,
            address(this),
            address(this),
            0
        );
    }

    function test_RejectsAVaultWindowTighterThanTheOracle() public {
        MedianOracle oracle = _median(3600);
        vm.expectRevert(
            abi.encodeWithSelector(
                OracleWindow.VaultWindowTighterThanOracle.selector, address(oracle), 90, uint256(3600)
            )
        );
        _deploy(address(oracle), 90);
    }

    /// One second under is still under. The failure this guards is a deploy
    /// that looks right, so the boundary is where it has to bite.
    function test_RejectsOneSecondUnder() public {
        MedianOracle oracle = _median(3600);
        vm.expectRevert(
            abi.encodeWithSelector(
                OracleWindow.VaultWindowTighterThanOracle.selector, address(oracle), 3599, uint256(3600)
            )
        );
        _deploy(address(oracle), 3599);
    }

    function test_AcceptsEqualWindows() public {
        MedianOracle oracle = _median(3600);
        SpotVaultMinimal v = _deploy(address(oracle), 3600);
        assertEq(v.maxOracleStaleness(), 3600);
    }

    /// The configuration per-asset windows actually need: a feed with a long
    /// heartbeat behind a vault whose backstop clears it.
    function test_AcceptsAWiderVaultWindow() public {
        MedianOracle oracle = _median(86_400);
        SpotVaultMinimal v = _deploy(address(oracle), 90_000);
        assertEq(v.maxOracleStaleness(), 90_000);
    }

    /// A real Chainlink aggregator has no `maxStaleness()` -- its heartbeat is
    /// off-chain configuration, not a getter. The probe must degrade to a
    /// no-op rather than making every non-MedianOracle feed unusable.
    function test_IgnoresAnOracleThatDoesNotExposeItsWindow() public {
        MockOracle plain = new MockOracle(1e8, 8);
        SpotVaultMinimal v = _deploy(address(plain), 90);
        assertEq(v.maxOracleStaleness(), 90);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {SpotVaultMinimal} from "../../src/vaults/SpotVaultMinimal.sol";
import {MedianOracle} from "../../src/oracle/MedianOracle.sol";
import {OracleWindow} from "../../src/oracle/OracleWindow.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockOracle} from "../mocks/MockOracle.sol";

/// @notice Which layer actually refuses a stale price, and when.
///
///         `OracleWindow.requireNotTighterThan` forbids a vault window BELOW
///         its oracle's own, and is right to: MedianOracle reports the OLDEST
///         contributing timestamp, so a vault stricter than its oracle is
///         bricked by construction rather than merely conservative.
///
///         The consequence had not been written down anywhere, and it is the
///         reason this file exists: behind one of our own oracles the vault's
///         `maxOracleStaleness` can NEVER be the check that fires. At the only
///         legal setting the two windows are equal, and MedianOracle drops the
///         report and reverts `InsufficientFreshReports` before the vault gets
///         to compare timestamps at all. Every vault on testnet 46630 is in
///         exactly that position.
///
///         So `maxOracleStaleness` looks like the protocol's staleness defence
///         while being unreachable on every vault currently deployed. It is not
///         dead code -- it is load-bearing in precisely the case OracleWindow
///         documents as unenforceable, a real Chainlink feed with no
///         `maxStaleness()` getter, where the staticcall returns false and the
///         vault's own window is the ONLY thing left. That case had no test.
///
///         The on-chain staleness drill cannot cover this: the factory refuses
///         to deploy the tighter-window vault the drill would need, so the drill
///         necessarily exercises the oracle. These four tests pin both halves.
contract OracleWindowCoverageTest is Test {
    MockERC20 asset;
    MockERC20 cash;

    address admin = address(this);

    function setUp() public {
        // Away from zero so `block.timestamp - age` cannot underflow.
        vm.warp(1_800_000_000);
        asset = new MockERC20("Equity", "EQ", 18);
        cash = new MockERC20("Cash", "USD", 6);
    }

    function _spot(address oracle_, uint256 window) internal returns (SpotVaultMinimal) {
        return new SpotVaultMinimal(
            address(asset), address(cash), oracle_, window,
            "Vault", "V", 0, 100, 0, admin, admin, 0
        );
    }

    /// grossValue prices what the vault HOLDS, and `cashToAsset` returns early
    /// on a zero balance, so BOTH legs are needed before the oracle is read at
    /// all. An empty vault answers 0 and a fully-long vault answers its asset
    /// balance, neither of them touching the feed -- a revert test built on
    /// either would pass for the wrong reason, or fail to revert at all.
    function _seed(SpotVaultMinimal v) internal {
        asset.mint(admin, 10e18);
        asset.approve(address(v), 10e18);
        v.deposit(10e18, admin);
        cash.mint(address(v), 1_000e6);
    }

    function _median(uint256 window) internal returns (MedianOracle o) {
        o = new MedianOracle(8, window, 1, 1e12, 1, admin);
        o.addUpdater(admin);
        o.report(250e8);
    }

    // ─── A feed that does not expose its window ──────────────────────────────

    /// The staticcall fails, the library returns, and any window is accepted --
    /// including one far tighter than the feed's real heartbeat. Nothing on
    /// chain can catch that, which is what makes the vault's own check matter
    /// here rather than being belt to the oracle's braces.
    function test_AFeedWithoutMaxStalenessAcceptsAnyVaultWindow() public {
        MockOracle feed = new MockOracle(250e8, 8);
        SpotVaultMinimal v = _spot(address(feed), 90);
        assertEq(v.maxOracleStaleness(), 90, "window not taken as given");
    }

    /// And with such a feed the vault's own comparison is the only refusal in
    /// the system. This is the assertion the testnet drill is structurally
    /// unable to make.
    function test_ThereTheVaultsOwnWindowIsTheOnlyRefusal() public {
        MockOracle feed = new MockOracle(250e8, 8);
        SpotVaultMinimal v = _spot(address(feed), 90);
        _seed(v);

        assertGt(v.grossValue(), 0, "fresh feed should price");

        feed.setUpdatedAt(block.timestamp - 91);
        vm.expectRevert(
            abi.encodeWithSelector(
                SpotVaultMinimal.StaleOracle.selector, block.timestamp - 91, block.timestamp
            )
        );
        v.grossValue();
    }

    /// The boundary of the claim "a stale oracle halts the vault": it does not,
    /// while the vault is entirely in its own unit of account. Holding only the
    /// equity leg, grossValue is a balance lookup and the feed is never
    /// consulted, so the vault keeps pricing, depositing and redeeming with a
    /// dead oracle behind it.
    ///
    /// That is correct rather than a hole -- an asset-denominated vault holding
    /// only that asset needs no price to know what it is worth, and refusing
    /// would strand depositors for no gain. It is recorded because the halting
    /// guarantee is routinely stated without the condition, and the testnet
    /// drill has to take both legs before it can observe any refusal at all.
    function test_AFullyLongVaultPricesWithNoWorkingFeedAtAll() public {
        MockOracle feed = new MockOracle(250e8, 8);
        SpotVaultMinimal v = _spot(address(feed), 90);

        asset.mint(admin, 10e18);
        asset.approve(address(v), 10e18);
        v.deposit(10e18, admin);          // asset leg only, no cash

        feed.setUpdatedAt(block.timestamp - 10_000);   // long dead
        assertEq(v.grossValue(), 10e18, "a fully-long vault should not need a price");
    }

    // ─── One of our own oracles ──────────────────────────────────────────────

    /// The tighter-window vault the drill wants cannot be built.
    function test_OurOwnOracleRefusesATighterVaultWindow() public {
        MedianOracle o = _median(3600);
        vm.expectRevert(
            abi.encodeWithSelector(
                OracleWindow.VaultWindowTighterThanOracle.selector, address(o), 90, 3600
            )
        );
        _spot(address(o), 90);
    }

    /// At the only legal setting -- equal windows -- the oracle goes dark first,
    /// so `StaleOracle` is unreachable. The vault still refuses; it simply is
    /// not the thing doing the refusing.
    function test_AtEqualWindowsTheOracleRefusesBeforeTheVaultCanLook() public {
        MedianOracle o = _median(3600);
        SpotVaultMinimal v = _spot(address(o), 3600);
        _seed(v);

        assertGt(v.grossValue(), 0, "fresh oracle should price");

        vm.warp(block.timestamp + 3601);
        vm.expectRevert(
            abi.encodeWithSelector(MedianOracle.InsufficientFreshReports.selector, 0, 1)
        );
        v.grossValue();
    }
}

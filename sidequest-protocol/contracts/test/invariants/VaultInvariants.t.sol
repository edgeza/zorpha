// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {SpotVaultMinimal} from "../../src/vaults/SpotVaultMinimal.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockOracle} from "../mocks/MockOracle.sol";
import {MockSpotAdapter} from "../mocks/MockSpotAdapter.sol";

/// @notice Stateful handler for the SpotVault invariant run.
///
///         AUDIT V-05. The previous handler pranked `rebalanceTo` as the vault's
///         own address, which holds no KEEPER_ROLE, so all 64,010 rebalance
///         calls reverted across every run. Forge's invariant runner defaults to
///         `fail_on_revert = false`, so the suite reported both invariants
///         holding across 128,000 calls while having never once exercised a
///         rebalance. That is worse than having no invariant test: it
///         manufactures confidence.
///
///         This handler is wired so calls actually land, and it records ghost
///         counters so `afterInvariant` can assert real coverage and fail the
///         run if the fuzzer never got through.
contract VaultHandler is Test {
    SpotVaultMinimal public vault;
    MockERC20 public asset;
    MockERC20 public cash;
    MockOracle public oracle;
    MockSpotAdapter public adapter;

    address public constant ALICE = address(0xA11CE);

    // ─── Ghost state ─────────────────────────────────────────────────────────
    uint256 public depositCalls;
    uint256 public redeemCalls;
    uint256 public rebalanceCalls;
    uint256 public priceMoves;
    uint256 public totalDepositedAssets;
    uint256 public totalRedeemedAssets;

    constructor(
        SpotVaultMinimal v,
        MockERC20 a,
        MockERC20 c,
        MockOracle o,
        MockSpotAdapter ad
    ) {
        vault = v;
        asset = a;
        cash = c;
        oracle = o;
        adapter = ad;
    }

    function deposit(uint256 amount) external {
        amount = bound(amount, 1e6, 100 * 1e8);

        asset.mint(ALICE, amount);
        vm.startPrank(ALICE);
        asset.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, ALICE);
        vm.stopPrank();

        if (shares > 0) {
            depositCalls++;
            totalDepositedAssets += amount;
        }
    }

    function redeem(uint256 sharesSeed) external {
        uint256 held = vault.balanceOf(ALICE);
        if (held == 0) return;
        uint256 shares = bound(sharesSeed, 1, held);

        vm.startPrank(ALICE);
        uint256 got = vault.redeem(shares, ALICE, ALICE);
        vm.stopPrank();

        redeemCalls++;
        totalRedeemedAssets += got;
    }

    function rebalanceTo(uint16 weight) external {
        weight = uint16(bound(uint256(weight), 0, 10000));

        // `rebalanceTo` returns early without emitting a receipt when TVL is
        // zero or the move is below the threshold, so count the vault's own
        // counter rather than assuming every non-reverting call was a rebalance.
        uint256 before = vault.rebalanceCount();
        vault.rebalanceTo(weight); // this handler holds KEEPER_ROLE
        if (vault.rebalanceCount() > before) {
            rebalanceCalls++;
        }
    }

    /// @dev Oracle moves are the only thing that should change NAV per share.
    function movePrice(uint256 priceSeed) external {
        // Stay inside the vault's staleness and sanity envelope.
        int256 p = int256(bound(priceSeed, 1_000 * 1e8, 200_000 * 1e8));
        oracle.setPrice(p);
        priceMoves++;
    }
}

contract VaultInvariantsTest is StdInvariant, Test {
    SpotVaultMinimal vault;
    MockERC20 asset;
    MockERC20 cash;
    MockOracle oracle;
    MockSpotAdapter adapter;
    VaultHandler handler;

    function setUp() public {
        vm.warp(1_700_000_000);

        asset = new MockERC20("Asset", "A", 8);
        cash = new MockERC20("Cash", "C", 6);
        oracle = new MockOracle(50_000 * 1e8, 8);
        adapter = new MockSpotAdapter(address(asset), address(cash), address(oracle));

        vault = new SpotVaultMinimal(
            address(asset),
            address(cash),
            address(oracle),
            1 hours,
            "Vault",
            "V",
            0, // rebalanceThresholdBps: always act, so rebalances are exercised
            100,
            0, // performanceFeeBps
            address(this),
            address(this),
            0
        );
        vault.setSwapAdapter(address(adapter));

        handler = new VaultHandler(vault, asset, cash, oracle, adapter);

        // Without this the handler cannot rebalance at all; the defect behind
        // V-05.
        vault.grantRole(vault.KEEPER_ROLE(), address(handler));

        // The venue needs deep inventory on both legs, or swaps revert and the
        // rebalance path silently stops being covered again.
        asset.mint(address(adapter), 1_000_000 * 1e8);
        cash.mint(address(adapter), 1_000_000_000 * 1e6);

        targetContract(address(handler));
    }

    // ─── Invariants ──────────────────────────────────────────────────────────

    /// Accrued fees can never exceed the assets backing them.
    function invariant_FeesNeverExceedAssets() public view {
        assertLe(
            vault.performanceFeeAccrued(),
            vault.grossValue(),
            "accrued fees exceed everything the vault holds"
        );
    }

    /// The V-01 class of failure: outstanding shares backed by nothing, while
    /// the vault still accepts deposits; so the next depositor funds the hole.
    ///
    /// ERC-4626 rounding can legitimately leave dust shares whose assets floor
    /// to zero, so the state itself is not the bug. The bug is being OPEN in
    /// that state. Both guards are asserted: closed to new capital, and the
    /// residual is genuinely worth nothing rather than someone being short.
    function invariant_WorthlessSharesMeanClosedVault() public view {
        if (vault.totalSupply() == 0) return;
        if (vault.totalAssets() > 0) return;

        assertEq(vault.maxDeposit(address(1)), 0, "vault open for deposits while shares are worthless");
        assertEq(vault.maxMint(address(1)), 0, "vault open for mints while shares are worthless");
        assertEq(
            vault.convertToAssets(vault.totalSupply()),
            0,
            "shares claim assets the vault does not have"
        );
    }

    /// While the vault is open for business, a share must be worth something.
    function invariant_OpenVaultHasNonZeroSharePrice() public view {
        if (vault.totalSupply() == 0) return;
        if (vault.maxDeposit(address(1)) == 0) return; // closed, covered above
        assertGt(vault.totalAssets(), 0, "open vault with zero backing");
        assertGt(vault.getNavPerShare(), 0, "open vault with zero share price");
    }

    /// Every share outstanding must be redeemable from what the vault holds. If
    /// this breaks, the last redeemer out is short.
    function invariant_TotalSupplyIsFullyBacked() public view {
        uint256 supply = vault.totalSupply();
        if (supply == 0) return;
        assertLe(
            vault.convertToAssets(supply),
            vault.totalAssets(),
            "outstanding shares claim more than the vault holds"
        );
    }

    /// `totalAssets` is the net figure; it can never exceed the gross holdings.
    function invariant_NetNeverExceedsGross() public view {
        assertLe(vault.totalAssets(), vault.grossValue(), "net exceeds gross holdings");
    }

    /// The receipt counter must match the number of calls that actually landed.
    /// The old version asserted `rebalanceCount() <= 1000`, which was satisfied
    /// by the counter never moving at all.
    function invariant_RebalanceCountMatchesSuccessfulCalls() public view {
        assertEq(
            vault.rebalanceCount(),
            handler.rebalanceCalls(),
            "receipt count diverged from executed rebalances"
        );
    }

    /// A depositor cannot extract more than was ever put in, at constant price.
    /// Price moves are permitted to make this hold with slack, so only the
    /// gross direction is asserted.
    function invariant_NoValueCreatedFromNothing() public view {
        if (handler.priceMoves() > 0) return; // price moves legitimately change value
        assertLe(
            handler.totalRedeemedAssets(),
            handler.totalDepositedAssets() + 1e6,
            "redeemed more than deposited with no price movement"
        );
    }

    // ─── Coverage floor ──────────────────────────────────────────────────────

    /// @dev Runs once at the end of each invariant run.
    ///
    ///      This is the guard that makes the suite honest. Forge does not fail
    ///      a run in which every single call reverted, so without an explicit
    ///      coverage assertion a fully broken handler reports as green. If the
    ///      fuzzer never successfully deposited or rebalanced, the invariants
    ///      above proved nothing and the run must fail.
    function afterInvariant() public view {
        assertGt(handler.depositCalls(), 0, "no deposit ever succeeded: invariants proved nothing");
        assertGt(
            handler.rebalanceCalls(),
            0,
            "no rebalance ever succeeded: invariants proved nothing"
        );
    }
}

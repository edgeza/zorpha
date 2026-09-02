// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC4626YieldAdapter} from "../../src/adapters/ERC4626YieldAdapter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockERC4626} from "../mocks/MockERC4626.sol";

/// What happens when the venue's share price has been inflated.
///
/// `deposit` took whatever share count the venue handed back and never valued
/// it:
///
///     uint256 shares = target.deposit(toDeposit, address(this));
///     emit Deposited(toDeposit, shares);
///
/// An ERC-4626 whose share price has been pushed up -- donated to while supply
/// was tiny, or simply nearly empty -- mints too few shares for a deposit, and
/// the shortfall is absorbed by the venue's existing holders. The adapter's
/// `totalAssets()` drops the instant the deposit lands, so every YieldVault
/// depositor takes the loss immediately and silently. Nothing reverts.
///
/// This is not hypothetical and was not found by reading. The testnet fixture
/// `TestYieldTarget` at 0x16e0f0b7 reached this state through ordinary repeated
/// drill runs -- `accrue()` donating underlying while share supply sat at 1:
///
///     totalAssets 500000017    totalSupply 1
///     previewDeposit(1e9)  -> 3 shares
///     previewRedeem(3)     -> 750000027 assets
///
/// 1e9 in, 7.5e8 back. A 25% loss on a single deposit, and the yield drill's
/// only symptom was "NAV did not rise after the venue accrued" -- because the
/// vault was on a stub adapter and never reached the venue at all. The real
/// adapter would have taken the loss without a word.
///
/// Mainnet venues are governance-approved, which bounds who can be the target
/// but not what state the target is in. A legitimate venue can be nearly empty
/// on the day it is approved, and a third party can inflate it at any time --
/// the donation costs the attacker nothing they do not get back from the next
/// depositor.
contract ERC4626YieldAdapterTest is Test {
    MockERC20 asset;
    MockERC4626 venue;
    ERC4626YieldAdapter adapter;

    address constant WHALE = address(0xBEEF);

    function setUp() public {
        asset = new MockERC20("Test Global Dollar", "tUSDG", 6);
        venue = new MockERC4626(asset, "Test Curated USDG", "tcUSDG");
        adapter = new ERC4626YieldAdapter(address(asset), address(venue), address(this));
        adapter.grantRole(adapter.VAULT_ROLE(), address(this));

        asset.mint(address(this), 1_000_000e6);
        asset.approve(address(adapter), type(uint256).max);
    }

    /// Reproduce the live fixture's shape: 1 share outstanding against a large
    /// asset balance.
    function _inflateVenue() internal {
        // One wei of shares, held by someone else.
        asset.mint(WHALE, 1);
        vm.startPrank(WHALE);
        asset.approve(address(venue), 1);
        venue.deposit(1, WHALE);
        vm.stopPrank();

        // Then donate. This is what `accrue` does, and what a third party can
        // do to any ERC-4626 with a plain transfer.
        venue.accrue(500_000_000);

        assertEq(venue.totalSupply(), 1, "setup: supply should be 1 share");
        assertGt(venue.totalAssets(), 500_000_000, "setup: assets should be inflated");
    }

    /// The regression. Depositing into an inflated venue must not silently
    /// destroy a quarter of the deposit.
    function test_Deposit_IntoInflatedVenue_DoesNotSilentlyLoseValue() public {
        _inflateVenue();

        uint256 amount = 1_000_000_000; // 1e9, exactly the live figure

        // Establish that the venue really would eat the deposit, so this test
        // cannot pass vacuously against a venue that happens to be fair.
        uint256 wouldGet = venue.previewDeposit(amount);
        uint256 worthBack = venue.previewRedeem(wouldGet);
        assertLt(worthBack, (amount * 99) / 100, "setup: the venue must be lossy for this test to mean anything");

        // Either the adapter refuses, or it deposits and keeps the value. Both
        // are acceptable outcomes; silently losing 25% is not.
        try adapter.deposit(amount) {
            assertGe(
                adapter.totalAssets(),
                (amount * 9_990) / 10_000,
                "the adapter accepted a deposit worth materially less than was paid"
            );
        } catch {
            // Refusing is the safer branch: the vault's deposit reverts and the
            // depositor keeps their money.
            assertEq(asset.balanceOf(address(adapter)), 0, "a refused deposit must not strand assets in the adapter");
        }
    }

    /// The guard must not block the ordinary case. A venue with a normal share
    /// price has to keep working, or the fix bricks the product.
    function test_Deposit_IntoFairVenue_StillWorks() public {
        uint256 amount = 1_000_000_000;
        adapter.deposit(amount);

        assertApproxEqAbs(adapter.totalAssets(), amount, 2, "a fair venue must round-trip within dust");
        assertGt(venue.balanceOf(address(adapter)), 0, "the adapter should hold venue shares");
    }

    /// And it must not block a venue that has legitimately earned yield, which
    /// also raises the share price -- the case the guard could most plausibly
    /// break by mistaking growth for manipulation.
    function test_Deposit_AfterGenuineYield_StillWorks() public {
        adapter.deposit(1_000_000_000);
        venue.accrue(100_000_000); // 10% earned, with real supply outstanding

        uint256 before = adapter.totalAssets();
        adapter.deposit(500_000_000);

        assertApproxEqAbs(
            adapter.totalAssets(),
            before + 500_000_000,
            2,
            "depositing into a venue that has earned yield must still work"
        );
    }

    /// The worst case, and the one the invariant campaign kept walking into: a
    /// venue donated to while it has NO shares outstanding at all.
    ///
    /// OZ's ERC4626 sizes the first deposit as
    /// `assets * (supply + virtualShares) / (totalAssets + 1)`. With supply 0
    /// and totalAssets already large, that rounds to ZERO shares -- so the
    /// depositor pays in full and receives nothing. Not a 25% haircut: a total
    /// loss, and the assets become the property of whoever mints next.
    ///
    /// Measured here: 1e9 paid, shares worth 0 back, `DepositValueLost(1e9, 0)`.
    ///
    /// This is the classic ERC-4626 first-depositor inflation attack seen from
    /// the depositing side, and it costs an attacker only the donation, which
    /// they recover from the next deposit. The guard turns a silent total loss
    /// into a revert.
    function test_Deposit_IntoVenueDonatedToWithZeroShares_RefusesTotalLoss() public {
        venue.accrue(5_000_000_000);  // donate with no shares outstanding
        assertEq(venue.totalSupply(), 0, "setup: the venue must have no shares");
        assertGt(venue.totalAssets(), 0, "setup: but it must hold assets");

        uint256 amount = 1_000_000_000;
        assertEq(venue.previewDeposit(amount), 0, "setup: this must mint zero shares to be the case under test");

        vm.expectRevert(
            abi.encodeWithSelector(ERC4626YieldAdapter.DepositValueLost.selector, amount, 0)
        );
        adapter.deposit(amount);

        assertEq(asset.balanceOf(address(adapter)), 0, "the refusal must not strand assets");
    }

    /// And the same venue works normally once it has real shares outstanding,
    /// which is what genuine yield looks like.
    function test_Deposit_ThenYield_IsNotConfusedForInflation() public {
        adapter.deposit(1_000_000_000);           // real shares now exist
        venue.accrue(5_000_000_000);              // then it earns

        uint256 before = adapter.totalAssets();
        adapter.deposit(1_000_000_000);
        assertGt(adapter.totalAssets(), before, "a deposit after real yield must still land");
    }

    /// Dust deposits must not trip a basis-point tolerance that rounds to zero.
    function test_Deposit_TinyAmount_NotBlockedByRounding() public {
        adapter.deposit(1_000_000_000);
        adapter.deposit(1); // 1 wei, where any bps tolerance is 0
        assertGt(adapter.totalAssets(), 0, "a dust deposit must not revert on rounding alone");
    }
}

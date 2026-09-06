// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {YieldVault} from "../../src/vaults/YieldVault.sol";
import {StubYieldAdapter} from "../../src/adapters/StubYieldAdapter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {ReceiptRenderer} from "../../src/lib/ReceiptRenderer.sol";

contract YieldVaultTest is Test {
    MockERC20 usdc;
    StubYieldAdapter adapter;
    YieldVault vault;

    address alice = makeAddr("alice");
    address keeper = makeAddr("keeper");

    function setUp() public {
        vm.warp(1_700_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        adapter = new StubYieldAdapter(address(usdc), address(this));
        vault = new YieldVault(
            address(usdc), address(adapter),
            "Zorpha Yield Vault", "sqYIELD",
            0, address(this), address(this)
        );
        vault.grantRole(vault.KEEPER_ROLE(), keeper);

        usdc.mint(alice, 1_000_000 * 1e6);
    }

    function _deposit(uint256 amount) internal returns (uint256 shares) {
        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        shares = vault.deposit(amount, alice);
        vm.stopPrank();
    }

    function test_Deposit_RoutesThroughAdapter() public {
        uint256 shares = _deposit(100_000 * 1e6);
        assertGt(shares, 0);
        // Adapter now holds the deposit.
        assertEq(adapter.totalAssets(), 100_000 * 1e6);
        assertEq(usdc.balanceOf(address(vault)), 0, "vault balance zero after deposit");
    }

    /// The assertion that would have caught the worst bug in this codebase on
    /// day one: put N of `asset()` in, take every share back out, count N of
    /// `asset()` returned.
    ///
    /// `RWRotationVault` returned 2 HOOD for 10 deposited, because its
    /// `totalAssets()` was denominated in a different token from `asset()` and
    /// no conversion was overridden. Nine of its tests passed either side of
    /// that, all of them internally consistent in either base units or shares.
    /// Only a single-unit round trip shows it. See
    /// docs/FINDINGS-ROTATION-UNITS.md.
    ///
    /// This vault is believed consistent. Nothing pinned it.
    function test_Units_DepositRedeemRoundTrip() public {
        uint256 amount = 100_000 * 1e6;
        uint256 before_ = usdc.balanceOf(alice);
        uint256 shares = _deposit(amount);
        vm.prank(alice);
        vault.redeem(shares, alice, alice);

        assertEq(
            usdc.balanceOf(alice), before_,
            "a clean round trip must return exactly what went in"
        );
        assertEq(vault.totalSupply(), 0, "and burn every share");
        assertGt(shares, 0, "shares were actually minted");
    }

    function test_Rebalance_EmitsReceipt_AndIncrementsCount() public {
        _deposit(100_000 * 1e6);

        uint256 nav = vault.getNavPerShare();
        uint256 ta = vault.totalAssets();
        uint256 adapterBal = usdc.balanceOf(address(adapter));
        assertEq(adapterBal, 100_000 * 1e6, "deposit must be held by the adapter");

        // Recompute the commitment rather than asserting bytes32(0), which
        // could never match a keccak256 over live values.
        bytes32 expCommit = ReceiptRenderer.commitment(
            keeper, address(vault), 0, nav, ta, adapterBal, 1, block.timestamp, bytes32(0)
        );

        vm.expectEmit(false, false, false, true, address(vault));
        emit YieldVault.Rebalanced(nav, ta, adapterBal, 1, expCommit);

        vm.prank(keeper);
        vault.rebalanceTo();

        assertEq(vault.rebalanceCount(), 1);
    }

    /// AUDIT V-01. The accounting invariant the vault must hold at all times:
    /// everything `totalAssets()` counts is actually held where it is counted.
    function _assertAdapterHoldsEverything(string memory ctx) internal view {
        assertEq(
            adapter.totalAssets(),
            vault.totalAssets() + vault.performanceFeeAccrued(),
            ctx
        );
    }

    function test_AdapterHoldsEverythingAcrossDepositAndWithdraw() public {
        _assertAdapterHoldsEverything("empty");

        uint256 shares = _deposit(250_000 * 1e6);
        _assertAdapterHoldsEverything("after deposit");
        assertEq(usdc.balanceOf(address(vault)), 0, "vault must not sit on idle capital");

        // startPrank, and share balances read OUTSIDE the argument list: an
        // external call inside the arguments consumes a single-shot vm.prank,
        // so `redeem` would execute as the test contract and fail on allowance.
        vm.startPrank(alice);
        vault.redeem(shares / 2, alice, alice);
        vm.stopPrank();
        _assertAdapterHoldsEverything("after partial redeem");

        uint256 remaining = vault.balanceOf(alice);
        vm.startPrank(alice);
        vault.redeem(remaining, alice, alice);
        vm.stopPrank();
        _assertAdapterHoldsEverything("after full redeem");
        assertEq(vault.totalSupply(), 0, "all shares burned");
    }

    /// A depositor must be able to get out for what they put in. This is the
    /// exact scenario that previously returned zero.
    function testFuzz_DepositThenRedeemIsWhole(uint96 amount) public {
        uint256 amt = bound(uint256(amount), 1e6, 1_000_000 * 1e6);
        usdc.mint(alice, amt);

        uint256 before = usdc.balanceOf(alice);
        vm.startPrank(alice);
        usdc.approve(address(vault), amt);
        uint256 shares = vault.deposit(amt, alice);
        uint256 back = vault.redeem(shares, alice, alice);
        vm.stopPrank();

        assertGt(back, 0, "redeeming must return assets");
        // ERC-4626 rounds in the vault's favour by at most 1 wei per operation.
        assertApproxEqAbs(back, amt, 2, "round trip must be whole");
        assertApproxEqAbs(usdc.balanceOf(alice), before, 2, "balance restored");
    }

    /// Swapping the yield source must move the position with it, or the new
    /// adapter reports zero and every share reprices to nothing.
    function test_SetAdapter_MigratesThePosition() public {
        _deposit(100_000 * 1e6);
        assertEq(adapter.totalAssets(), 100_000 * 1e6);

        StubYieldAdapter next = new StubYieldAdapter(address(usdc), address(this));
        vault.grantRole(vault.ADAPTER_SETTER_ROLE(), address(this));
        vault.setAdapter(address(next));

        assertEq(adapter.totalAssets(), 0, "old adapter drained");
        assertEq(next.totalAssets(), 100_000 * 1e6, "new adapter holds the position");
        assertEq(vault.totalAssets(), 100_000 * 1e6, "NAV survives the migration");

        uint256 held = vault.balanceOf(alice);
        vm.startPrank(alice);
        uint256 back = vault.redeem(held, alice, alice);
        vm.stopPrank();
        assertApproxEqAbs(back, 100_000 * 1e6, 2, "still redeemable after migration");
    }

    function test_SetAdapter_NewAdapterWired() public {
        // A second stub adapter
        StubYieldAdapter newAdapter = new StubYieldAdapter(address(usdc), address(this));
        vault.grantRole(vault.ADAPTER_SETTER_ROLE(), address(this));
        vault.setAdapter(address(newAdapter));
        assertEq(address(vault.adapter()), address(newAdapter));
    }

    function test_Withdraw_ReturnsFunds() public {
        uint256 shares = _deposit(100_000 * 1e6);
        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(shares, alice, alice);
        assertEq(usdc.balanceOf(alice), balBefore + 100_000 * 1e6);
    }

    // ─── Equalisation: the first depositor into an empty vault ──────────────
    //
    // A vault with a 10% fee, so the arithmetic is legible.
    function _feeVault() internal returns (YieldVault v, StubYieldAdapter a) {
        a = new StubYieldAdapter(address(usdc), address(this));
        v = new YieldVault(
            address(usdc), address(a),
            "Fee Vault", "sqFEE",
            1000, address(this), address(this)
        );
    }

    function _depositTo(YieldVault v, address who, uint256 amount) internal returns (uint256) {
        vm.startPrank(who);
        usdc.approve(address(v), amount);
        uint256 sh = v.deposit(amount, who);
        vm.stopPrank();
        return sh;
    }

    /// A depositor entering an empty vault that still holds a residue must be
    /// charged only on the gain they actually earn.
    ///
    /// Before the fix, `_evaluateFees` returned early on `totalSupply() == 0`
    /// and left the mark wherever the previous cohort put it. The residue plus
    /// the ERC-4626 offset then lifted the new entry NAV above that stale mark,
    /// and redemption charged from the mark: on testnet 46630 this was measured
    /// at 12-20% over, once per cycle, deterministically.
    ///
    /// Nothing in this suite covered it, which is why twenty tests, six
    /// invariants and a fuzz test were green while it was live.
    /// Does the yield vault carry the fee-claim-backing defect found in the spot
    /// vault? See docs/FINDINGS-FEE-CLAIM-BACKING.md. There the fee claim is
    /// asset-denominated while the backing sits in cash, so a price move splits
    /// the two. The yield vault holds one leg and has no price, so a price move
    /// cannot do it; but a venue *loss* can, and that is not exotic.
    ///
    /// Answer: it did carry it. A venue loss splits the claim from its backing
    /// exactly as a price move does, and a venue taking a haircut is the ordinary
    /// risk case rather than an exotic one. The initial guess in the findings doc
    /// -- that this was probably spot-vault-only -- was wrong, which is why it
    /// was tested instead of assumed.
    ///
    /// Now fixed by `_reconcileFeeClaimWhenEmpty`, so this asserts the depositor
    /// is whole. The 9% it used to cost is recorded in the findings doc.
    function test_UnclaimedFee_AgainstAVenueLoss() public {
        (YieldVault v, StubYieldAdapter a) = _feeVault();
        address bob = makeAddr("bob");
        usdc.mint(bob, 1_000_000 * 1e6);

        // Alice earns, a fee is struck, and she leaves.
        uint256 sh = _depositTo(v, alice, 1_000 * 1e6);
        usdc.mint(address(a), 1_000 * 1e6);
        vm.prank(alice);
        v.redeem(sh, alice, alice);
        assertEq(v.totalSupply(), 0, "empty");

        uint256 claim = v.performanceFeeAccrued();
        assertGt(claim, 0, "a fee is outstanding and unclaimed");

        // The venue now loses most of what backs that claim.
        uint256 backingBeforeLoss = a.totalAssets();
        usdc.burn(address(a), (backingBeforeLoss * 9) / 10);
        assertLt(a.totalAssets(), claim, "the claim now outgrows its backing");

        uint256 backingAfterLoss = a.totalAssets();

        // Bob deposits into that state. `_reconcileFeeClaimWhenEmpty` caps the
        // claim at its backing first, so his principal is not touched.
        uint256 deposited = 1_000 * 1e6;
        uint256 bobShares = _depositTo(v, bob, deposited);
        uint256 bobValue = v.convertToAssets(bobShares);

        assertEq(bobValue, deposited, "bob holds exactly what he paid");
        assertApproxEqAbs(
            v.performanceFeeAccrued(), backingAfterLoss, 1,
            "the claim was capped at what actually backed it, not written to zero"
        );

        // Claiming now pays only the covered part. It used to pay the full stale
        // claim -- `_pullFromAdapter` takes min(needed, available) rather than
        // reverting, so once bob's deposit topped the adapter up the whole 100
        // was payable out of his money, and the books balanced afterwards.
        uint256 recipientBefore = usdc.balanceOf(address(this));
        v.claimFees();
        uint256 paid = usdc.balanceOf(address(this)) - recipientBefore;
        assertLt(paid, claim, "less than the stale claim");
        assertApproxEqAbs(paid, backingAfterLoss, 1, "exactly what was backed");

        // Bob is still whole after the fee recipient has been paid.
        assertEq(
            v.convertToAssets(bobShares), deposited,
            "and paying the fee did not come out of bob"
        );
        // `backingBeforeLoss` is read to make the 90% burn legible above.
        assertGt(backingBeforeLoss, backingAfterLoss, "the venue did lose");
    }

    function test_FirstDepositorIntoADustyVaultPaysOnlyForTheirOwnGain() public {
        (YieldVault v, StubYieldAdapter a) = _feeVault();
        address bob = makeAddr("bob");
        usdc.mint(bob, 1_000_000 * 1e6);

        // Cohort one earns, redeems out, and leaves the mark high.
        uint256 sh1 = _depositTo(v, alice, 1_000 * 1e6);
        usdc.mint(address(a), 1_000 * 1e6);          // venue doubles
        vm.prank(alice);
        v.redeem(sh1, alice, alice);
        assertEq(v.totalSupply(), 0, "cohort one must be fully out");

        uint256 staleMark = v.highWaterMark();
        assertGt(staleMark, 0, "the mark should have ratcheted up");

        // A residue is left behind: rounding dust in practice, forced here so
        // the test does not depend on which way a division happened to go.
        usdc.mint(address(a), 10);

        // Cohort two enters. Their entry price is whatever the residue and the
        // offset make it, and it may well be above the stale mark.
        uint256 sh2 = _depositTo(v, bob, 1_000 * 1e6);
        uint256 entryNav = v.getNavPerShare();

        assertEq(
            v.highWaterMark(), entryNav,
            "the first depositor into an empty vault must mark their own entry price"
        );

        // Now a real gain, and only this gain may be charged.
        uint256 feeBefore = v.performanceFeeAccrued();
        usdc.mint(address(a), 500 * 1e6);
        uint256 gainNav = v.getNavPerShare() - entryNav;

        vm.prank(bob);
        uint256 got = v.redeem(sh2, bob, bob);

        uint256 charged = v.performanceFeeAccrued() - feeBefore;
        uint256 fair = (gainNav * sh2 * 1000) / ((10 ** v.decimals()) * 10_000);

        // Within one unit: the fee is one integer division.
        assertApproxEqAbs(charged, fair, 1, "fee must be charged on this depositor's gain alone");

        // And they must not have paid for the pre-existing NAV.
        assertGt(got, 1_000 * 1e6, "bob should be up on the trade");
    }

    /// The mirror image, and the reason the reset is unconditional: an entry
    /// BELOW a stale high mark used to ride free, with the leader earning
    /// nothing on a real gain.
    function test_FirstDepositorBelowAStaleMarkStillPaysOnTheirGain() public {
        (YieldVault v, StubYieldAdapter a) = _feeVault();
        address bob = makeAddr("bob2");
        usdc.mint(bob, 1_000_000 * 1e6);

        // Push the mark up, then fully unwind.
        uint256 sh1 = _depositTo(v, alice, 1_000 * 1e6);
        // NAV x10. Deliberately not x5: the residue left behind puts a fresh
        // entry at about 5e6, so a x5 peak collides with it exactly and the
        // test would be asserting "below" against an equal value.
        usdc.mint(address(a), 9_000 * 1e6);
        vm.prank(alice);
        v.redeem(sh1, alice, alice);
        uint256 staleMark = v.highWaterMark();

        // Sweep the fee, then drain the adapter entirely.
        //
        // Both are needed, and the second is the interesting one. A clean full
        // redemption leaves a residue of almost exactly `multiple - 1` units,
        // which the ERC-4626 offset turns back into `multiple * 1e6` -- the old
        // NAV. So the next entry lands EXACTLY on the old mark, neither above
        // nor below, and this test's premise cannot be reached that way. (That
        // self-correction is also why the testnet case needed several cycles of
        // drift to push an entry above the mark.)
        //
        // Draining removes the residue so bob genuinely enters at the base
        // price, well under the old peak. Legitimate on a stub whose withdraw
        // is deliberately ungated.
        v.claimFees();
        a.withdraw(a.totalAssets());

        // Bob enters far below that peak.
        uint256 sh2 = _depositTo(v, bob, 1_000 * 1e6);
        uint256 entryNav = v.getNavPerShare();
        assertLt(entryNav, staleMark, "bob must be entering below the old peak");
        assertEq(v.highWaterMark(), entryNav, "the mark follows bob's entry, not the old peak");

        uint256 feeBefore = v.performanceFeeAccrued();
        usdc.mint(address(a), 500 * 1e6);
        vm.prank(bob);
        v.redeem(sh2, bob, bob);

        assertGt(
            v.performanceFeeAccrued() - feeBefore, 0,
            "a real gain must earn a fee even though it is below the old peak"
        );
    }

    /// The early return in `_evaluateFees` exists to stop the empty-vault NAV
    /// sentinel ratcheting the mark out of reach. The fix must not reintroduce
    /// that: `_markFirstEntry` runs after minting, when the NAV is real.
    function test_MarkNeverTakesTheEmptyVaultSentinel() public {
        (YieldVault v,) = _feeVault();
        uint256 sentinel = 10 ** v.decimals();

        _depositTo(v, alice, 1_000 * 1e6);
        assertLt(v.highWaterMark(), sentinel, "the mark must never be the empty-vault sentinel");
        assertGt(v.highWaterMark(), 0, "but it must be set");
    }
}

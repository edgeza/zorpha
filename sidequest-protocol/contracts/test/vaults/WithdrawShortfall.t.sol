// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SpotVaultMinimal} from "../../src/vaults/SpotVaultMinimal.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockOracle} from "../mocks/MockOracle.sol";
import {SlippingSpotAdapter} from "../mocks/SlippingSpotAdapter.sol";

/// @notice A withdrawal that needs the cash leg converted back reverts, and the
///         vault is therefore exitable only up to its asset leg.
///
/// WHY THIS IS NOT COVERED BY test/vaults/SpotVaultMinimal.t.sol
///
/// Two things there hide it, and both are properties of the harness rather than
/// of the vault:
///
///   1. `MockSpotAdapter` fills at the oracle price exactly. `_withdraw` rounds
///      the shortfall DOWN into cash units and then allows the fill to come
///      back up to `maxSlippageBps` short, so it needs a venue that actually
///      charges to under-deliver. `SlippingSpotAdapter` is used here, at the
///      0.05% the live NVDA/USDG pool charges.
///
///   2. That suite pairs an 8-decimal asset with 6-decimal cash. One cash unit
///      is 100 asset units, so rounding the conversion down loses ~100 wei and
///      `previewRedeem`'s own truncation absorbs it. The live stock vault pairs
///      an 18-decimal asset with 6-decimal cash: one USDG unit is 4.3e9 NVDA
///      wei, so the same rounding loses billions of wei and nothing absorbs it.
///
/// The decimal gap is the whole mechanism, so this test reproduces it: 18dp
/// asset, 6dp cash, fee-charging venue.
///
/// MEASURED ON MAINNET, vault 0xB129495f0ad616EdD2f28b3B49470FC1f0FAD413 at a
/// 50/50 position, forked 7 September 2026:
///
///     redeem  40%  ok
///     redeem  50%  ERC20InsufficientBalance(vault, 27710798703467998,
///                                                  27710807884585675)
///
/// a gap of 9,181,117,677 wei -- 2.13 USDG units of granularity, on a leg of
/// 0.0277 NVDA. The swap ran and bought asset; it simply bought slightly less
/// than the transfer that followed demanded.
contract WithdrawShortfallTest is Test {
    MockERC20 stock;   // 18dp, like the tokenised equities on 4663
    MockERC20 cash;    // 6dp, like USDG
    MockOracle oracle;
    SlippingSpotAdapter venue;
    SpotVaultMinimal vault;

    address alice = makeAddr("alice");
    address keeper = makeAddr("keeper");

    int256 constant PRICE = 232 * 1e8;   // ~NVDA
    uint256 constant DEPOSIT = 100e18;

    function setUp() public {
        vm.warp(1_700_000_000);
        stock = new MockERC20("Tokenised NVDA", "NVDA", 18);
        cash = new MockERC20("Global Dollar", "USDG", 6);
        oracle = new MockOracle(PRICE, 8);
        venue = new SlippingSpotAdapter(address(stock), address(cash), address(oracle));
        venue.setFee(5); // 0.05%, the live pool's tier

        vault = new SpotVaultMinimal(
            address(stock), address(cash), address(oracle), 1 hours,
            "Zorpha NVDA Vault", "zqNVDA",
            0, 100, 0,
            address(this), address(this),
            1 hours
        );
        vault.setSwapAdapter(address(venue));
        vault.grantRole(vault.KEEPER_ROLE(), keeper);

        stock.mint(address(venue), 1_000_000e18);
        cash.mint(address(venue), 1_000_000_000e6);
        stock.mint(alice, DEPOSIT);

        vm.startPrank(alice);
        stock.approve(address(vault), DEPOSIT);
        vault.deposit(DEPOSIT, alice);
        vm.stopPrank();

        // Half into cash, which is the state the live vault was left in by
        // receipt one.
        vm.prank(keeper);
        vault.rebalanceTo(5000);
    }

    /// The exit a depositor is most likely to attempt: all of it.
    ///
    /// Note the balance in the revert is the one AFTER the shortfall swap ran,
    /// not the leg before it. The swap succeeds and buys asset; it just buys
    /// less than the transfer on the next line demands. The gap is the venue
    /// fee on the shortfall, which `minOut` on line 353 explicitly permits.
    function test_FullRedeem_RevertsWhenCashMustBeConverted() public {
        uint256 shares = vault.balanceOf(alice);
        uint256 owed = vault.previewRedeem(shares);
        uint256 legBefore = stock.balanceOf(address(vault));
        assertGt(owed, legBefore, "setup: the exit must need a conversion to be a test of one");

        vm.prank(alice);
        (bool ok, bytes memory err) = address(vault).call(
            abi.encodeCall(vault.redeem, (shares, alice, alice))
        );
        assertFalse(ok, "the redeem must fail, or there is no bug to regress");
        assertEq(bytes4(err), IERC20Errors.ERC20InsufficientBalance.selector, "wrong revert");

        (address who, uint256 held, uint256 needed) =
            abi.decode(_body(err), (address, uint256, uint256));
        assertEq(who, address(vault), "the vault is the one short of asset");
        assertGt(held, legBefore, "the swap did run and bought asset");
        assertLt(held, needed, "and still came back short of the transfer");

        // The gap is fee-scale, not economic: 5bps of the shortfall, give or
        // take the down-rounding into cash units.
        uint256 shortfall = owed - legBefore;
        assertApproxEqRel(needed - held, (shortfall * 5) / 10000, 0.01e18, "gap should be the venue fee");
    }

    /// Strip the selector so the revert args can be decoded.
    function _body(bytes memory err) private pure returns (bytes memory out) {
        out = new bytes(err.length - 4);
        for (uint256 i = 0; i < out.length; i++) out[i] = err[i + 4];
    }

    /// And the boundary is exactly the asset leg: anything the leg covers
    /// outright succeeds, anything past it reverts. That is what makes this a
    /// "the cash leg is unreachable" bug rather than a rounding curiosity.
    function test_ExitableFractionIsExactlyTheAssetLeg() public {
        uint256 shares = vault.balanceOf(alice);
        uint256 lastOk;
        uint256 firstFail;

        for (uint256 pct = 5; pct <= 100; pct += 5) {
            uint256 snap = vm.snapshotState();
            vm.prank(alice);
            try vault.redeem((shares * pct) / 100, alice, alice) {
                lastOk = pct;
            } catch {
                if (firstFail == 0) firstFail = pct;
            }
            vm.revertToState(snap);
        }

        assertEq(firstFail, lastOk + 5, "the boundary must be a single cliff, not scattered failures");
        assertLt(firstFail, 100, "some exit size must fail, or there is no bug to regress");

        // The cliff sits where the asset leg runs out, ~50% here because the
        // position is 50/50.
        uint256 legShare = (stock.balanceOf(address(vault)) * 100) / vault.totalAssets();
        assertApproxEqAbs(lastOk, legShare, 5, "cliff should track the asset leg's share of NAV");

        console2.log("largest exit that works (%)", lastOk);
        console2.log("asset leg as % of NAV      ", legShare);
    }

    /// The mitigation batch L applies: with the position all in the asset, no
    /// withdrawal needs a conversion, so every size clears.
    function test_FullyLongVault_IsExitableAtEverySize() public {
        vm.prank(keeper);
        vault.rebalanceTo(10000);

        uint256 shares = vault.balanceOf(alice);
        for (uint256 pct = 10; pct <= 100; pct += 10) {
            uint256 snap = vm.snapshotState();
            vm.prank(alice);
            vault.redeem((shares * pct) / 100, alice, alice);
            vm.revertToState(snap);
        }
    }

    /// Not something a tighter slippage bound fixes. A vault built with zero
    /// tolerance cannot even reach the broken state: `rebalanceTo` requires the
    /// venue to fill at the oracle price exactly, and a venue that charges for
    /// liquidity refuses. So the two settings fail in opposite directions --
    /// tolerance lets the withdrawal swap come back short of what the transfer
    /// demands, and no tolerance stops the vault trading at all. Redeploying
    /// with different bps is not the fix; line 350 is.
    function test_ZeroSlippageBound_CannotEvenRebalance() public {
        SpotVaultMinimal tight = new SpotVaultMinimal(
            address(stock), address(cash), address(oracle), 1 hours,
            "Zorpha NVDA Vault", "zqNVDA",
            0, 0, 0,
            address(this), address(this),
            1 hours
        );
        tight.setSwapAdapter(address(venue));
        tight.grantRole(tight.KEEPER_ROLE(), keeper);

        stock.mint(alice, DEPOSIT);
        vm.startPrank(alice);
        stock.approve(address(tight), DEPOSIT);
        tight.deposit(DEPOSIT, alice);
        vm.stopPrank();

        vm.prank(keeper);
        vm.expectRevert("venue: slippage");
        tight.rebalanceTo(5000);
    }
}

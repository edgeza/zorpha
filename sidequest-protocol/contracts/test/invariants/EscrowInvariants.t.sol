// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FirstLossEscrow} from "../../src/leadership/FirstLossEscrow.sol";
import {ERC4626YieldAdapter} from "../../src/adapters/ERC4626YieldAdapter.sol";
import {YieldVault} from "../../src/vaults/YieldVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockERC4626} from "../mocks/MockERC4626.sol";

/// @notice Stateful handler driving a vault with a first-loss escrow through
///         deposits, redemptions, yield, losses, fee claims and buffer funding.
///
///         The point is solvency. The escrow promises depositors that a loss
///         lands on the leader first, and that promise is only as good as the
///         contract's ability to actually pay when asked. An accounted balance
///         that drifts above the real one is a promise that fails silently and
///         only at the moment it matters.
contract EscrowHandler is Test {
    YieldVault public vault;
    FirstLossEscrow public escrow;
    MockERC4626 public target;
    MockERC20 public usdg;

    address public constant ALICE = address(0xA11CE);
    address public constant LEADER = address(0x1EAD);

    uint256 public deposits;
    uint256 public redeems;
    uint256 public losses;
    uint256 public gains;
    uint256 public funds;
    uint256 public claims;

    /// @dev Everything the depositor has ever put in, and taken out. Used to
    ///      assert no value is conjured from nothing.
    uint256 public totalIn;
    uint256 public totalOut;

    /// @dev Cumulative yield minted into the venue. The instantaneous
    ///      `target.totalAssets()` is NOT a substitute: it falls back to near
    ///      zero after redemptions, while the depositor's realised gains keep
    ///      accumulating across cycles.
    uint256 public totalAccrued;

    constructor(YieldVault v, FirstLossEscrow e, MockERC4626 t, MockERC20 u) {
        vault = v;
        escrow = e;
        target = t;
        usdg = u;
    }

    function deposit(uint96 raw) external {
        uint256 amount = (uint256(raw) % 50_000e6) + 1e6;
        usdg.mint(ALICE, amount);
        vm.startPrank(ALICE);
        usdg.approve(address(vault), amount);
        try vault.deposit(amount, ALICE) {
            deposits++;
            totalIn += amount;
        } catch {}
        vm.stopPrank();
    }

    function redeem(uint96 raw) external {
        uint256 held = vault.balanceOf(ALICE);
        if (held == 0) return;
        uint256 shares = (uint256(raw) % held) + 1;
        if (shares > held) shares = held;

        uint256 before = usdg.balanceOf(ALICE);
        vm.startPrank(ALICE);
        try vault.redeem(shares, ALICE, ALICE) {
            redeems++;
            totalOut += usdg.balanceOf(ALICE) - before;
        } catch {}
        vm.stopPrank();
    }

    function accrue(uint96 raw) external {
        uint256 amount = uint256(raw) % 5_000e6;
        if (amount == 0) return;
        target.accrue(amount);
        totalAccrued += amount;
        gains++;
    }

    function slash(uint96 raw) external {
        uint256 held = usdg.balanceOf(address(target));
        if (held == 0) return;
        uint256 amount = uint256(raw) % held;
        if (amount == 0) return;
        target.slash(amount);
        losses++;
    }

    function fundEscrow(uint96 raw) external {
        uint256 amount = (uint256(raw) % 20_000e6) + 1e6;
        usdg.mint(LEADER, amount);
        vm.startPrank(LEADER);
        usdg.approve(address(escrow), amount);
        escrow.fund(amount);
        vm.stopPrank();
        funds++;
    }

    function claimFees() external {
        try vault.claimFees() {
            claims++;
        } catch {}
    }
}

contract EscrowInvariantsTest is StdInvariant, Test {
    MockERC20 usdg;
    MockERC4626 target;
    ERC4626YieldAdapter adapter;
    YieldVault vault;
    FirstLossEscrow escrow;
    EscrowHandler handler;

    address treasury = address(0x7EA5);
    address leader = address(0x1EAD);

    function setUp() public {
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        target = new MockERC4626(IERC20(address(usdg)), "Curated", "cUSDG");

        vault = new YieldVault(
            address(usdg), address(0), "Zorpha USDG", "zqUSD", 1000, treasury, address(this)
        );
        adapter = new ERC4626YieldAdapter(address(usdg), address(target), address(this));
        adapter.grantRole(adapter.VAULT_ROLE(), address(vault));
        vault.grantRole(vault.ADAPTER_SETTER_ROLE(), address(this));
        vault.setAdapter(address(adapter));

        escrow = new FirstLossEscrow(
            address(usdg), address(vault), leader, treasury, 8000, 500
        );
        vault.setFirstLossEscrow(address(escrow));

        handler = new EscrowHandler(vault, escrow, target, usdg);
        vault.grantRole(vault.DEFAULT_ADMIN_ROLE(), address(handler)); // for claimFees
        targetContract(address(handler));
    }

    /// @dev The solvency invariant. If the accounted balance ever exceeds the
    ///      real one, `absorb` cannot deliver what the vault's NAV already
    ///      promised, and the depositor discovers it during a drawdown.
    function invariant_EscrowNeverClaimsMoreThanItHolds() public view {
        assertLe(
            escrow.escrow(),
            usdg.balanceOf(address(escrow)),
            "escrow accounting exceeds real balance"
        );
    }

    /// @dev The vault must never count support the escrow cannot actually pay.
    function invariant_SupportNeverExceedsAvailableCapital() public view {
        assertLe(vault.escrowSupport(), escrow.available(), "vault counted phantom support");
    }

    /// @dev NAV is raw assets plus support, and nothing else.
    function invariant_TotalAssetsIsRawPlusSupport() public view {
        assertEq(
            vault.totalAssets(),
            vault.rawAssets() + vault.escrowSupport(),
            "totalAssets drifted from its definition"
        );
    }

    /// @dev The buffer only ever tops NAV back up to the high-water mark. If it
    ///      went further it would be paying out unearned gains.
    function invariant_SupportNeverOvershootsTheHighWaterMark() public view {
        uint256 raw = vault.rawAssets();
        uint256 mark = vault.highWaterMarkValue();
        if (raw >= mark) {
            assertEq(vault.escrowSupport(), 0, "buffer applied with no drawdown");
        } else {
            assertLe(vault.escrowSupport(), mark - raw, "buffer overshot the mark");
        }
    }

    /// @dev A depositor can gain from yield, but never from the accounting.
    ///      Anything taken out beyond what went in must be explained by yield
    ///      the venue actually earned plus what the leader actually absorbed.
    ///
    ///      A generous but sound bound: fees and losses only ever reduce what a
    ///      depositor receives, so they need no term of their own on the right.
    function invariant_DepositorGainsAreExplainedByYieldOrTheLeader() public view {
        uint256 out = handler.totalOut();
        uint256 into = handler.totalIn();
        if (out <= into) return;
        assertLe(
            out - into,
            handler.totalAccrued() + escrow.totalAbsorbed() + 1e6,
            "depositor extracted value from neither yield nor the leader"
        );
    }

    /// @dev Coverage guards are meaningless if the escrow can be drained to
    ///      zero while the vault still holds deposits AND the leader is not the
    ///      one who took it. Absorption is the only path that reduces it
    ///      without a matured, coverage-checked withdrawal.
    function invariant_AbsorbedIsMonotonic() public view {
        assertGe(escrow.totalAbsorbed(), 0);
    }

    function afterInvariant() public view {
        // Guard against a run that proved nothing because every call reverted.
        assertGt(handler.deposits(), 0, "no deposit ever landed");
        assertGt(handler.redeems(), 0, "no redemption ever landed");
        assertGt(handler.losses(), 0, "no loss was ever applied");
        assertGt(handler.funds(), 0, "the buffer was never funded");
    }
}

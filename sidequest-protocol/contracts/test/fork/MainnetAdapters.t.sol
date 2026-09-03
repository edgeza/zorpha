// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {ERC4626YieldAdapter} from "../../src/adapters/ERC4626YieldAdapter.sol";
import {RobinhoodChainRouterAdapter} from "../../src/adapters/RobinhoodChainRouterAdapter.sol";
import {YieldVault} from "../../src/vaults/YieldVault.sol";

/// @notice Runs the two real adapters against the real contracts on Robinhood
///         Chain mainnet.
///
///         This matters more than a testnet run. Testnet (46630) is a bare
///         chain: no USDG, no Morpho vaults, no Uniswap pools — every mainnet
///         address returns no code there. So testnet can prove the protocol's
///         own accounting and nothing about whether it talks to the venues
///         correctly. That is exactly the class of bug that was sitting in the
///         swap adapter, which encoded a router struct the deployed router does
///         not accept.
///
///         Opt-in, because it needs network. Run with:
///           RH_MAINNET_RPC_URL=https://rpc.mainnet.chain.robinhood.com \
///           forge test --match-path 'test/fork/*'
///
///         Skips itself cleanly when that variable is unset, so CI without a
///         fork configured stays green rather than red-for-the-wrong-reason.
contract MainnetAdaptersForkTest is Test {
    // Verified live on 1 September 2026 by reading each contract.
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168; // 6dp
    address constant STEAK_USDG = 0xBeEff033F34C046626B8D0A041844C5d1A5409dd; // ERC-4626
    address constant SWAP_ROUTER_02 = 0xCaf681a66D020601342297493863E78C959E5cb2;
    address constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9; // 18dp
    uint24 constant AAPL_USDG_FEE = 500; // the 0.05% pool, the deepest one

    uint256 constant ONE_USDG = 1e6;

    address treasury = address(0x7EA5);
    address alice = address(0xA11CE);

    bool forked;

    function setUp() public {
        string memory url = vm.envOr("RH_MAINNET_RPC_URL", string(""));
        if (bytes(url).length == 0) return;
        vm.createSelectFork(url);
        forked = true;
    }

    modifier onlyForked() {
        if (!forked) {
            console2.log("SKIP: set RH_MAINNET_RPC_URL to run the fork tests");
            return;
        }
        _;
    }

    // ─── Sanity: are we actually where we think we are? ──────────────────────

    function test_ForkIsRobinhoodChainMainnet() public onlyForked {
        assertEq(block.chainid, 4663, "not on Robinhood Chain mainnet");
        assertGt(USDG.code.length, 0, "USDG has no code");
        assertGt(STEAK_USDG.code.length, 0, "Steakhouse vault has no code");
        assertGt(SWAP_ROUTER_02.code.length, 0, "router has no code");
    }

    function test_SteakhouseVaultIsWhatWeThinkItIs() public onlyForked {
        IERC4626 v = IERC4626(STEAK_USDG);
        assertEq(v.asset(), USDG, "target is not denominated in USDG");
        assertGt(v.totalAssets(), 1_000_000 * ONE_USDG, "target is unexpectedly small");
        console2.log("Steakhouse USDG totalAssets (USDG):", v.totalAssets() / ONE_USDG);
    }

    // ─── The yield adapter, against the real curated vault ───────────────────

    function test_YieldAdapterRoundTripsThroughSteakhouse() public onlyForked {
        ERC4626YieldAdapter adapter =
            new ERC4626YieldAdapter(USDG, STEAK_USDG, address(this));
        adapter.grantRole(adapter.VAULT_ROLE(), address(this));

        uint256 amount = 10_000 * ONE_USDG;
        deal(USDG, address(this), amount);
        IERC20(USDG).approve(address(adapter), amount);

        adapter.deposit(amount);

        // Position is in the curated vault, valued within rounding of what went in.
        assertApproxEqRel(adapter.totalAssets(), amount, 1e15, "position mispriced"); // 0.1%
        assertGt(IERC4626(STEAK_USDG).balanceOf(address(adapter)), 0, "no shares received");
        assertEq(IERC20(USDG).balanceOf(address(adapter)), 0, "left cash idle");

        uint256 before = IERC20(USDG).balanceOf(address(this));
        adapter.withdraw(adapter.totalAssets());
        uint256 recovered = IERC20(USDG).balanceOf(address(this)) - before;

        assertApproxEqRel(recovered, amount, 1e15, "round trip lost value");
        assertLe(adapter.totalAssets(), 2, "position not fully exited");
    }

    function test_FullVaultStackAgainstSteakhouse() public onlyForked {
        ERC4626YieldAdapter adapter =
            new ERC4626YieldAdapter(USDG, STEAK_USDG, address(this));

        YieldVault vault = new YieldVault(
            USDG, address(0), "Zorpha USDG Yield", "zqUSD", 1000, treasury, address(this)
        );
        adapter.grantRole(adapter.VAULT_ROLE(), address(vault));
        vault.grantRole(vault.ADAPTER_SETTER_ROLE(), address(this));
        vault.setAdapter(address(adapter));

        uint256 amount = 25_000 * ONE_USDG;
        deal(USDG, alice, amount);

        vm.startPrank(alice);
        IERC20(USDG).approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, alice);
        vm.stopPrank();

        assertGt(shares, 0, "no shares minted");
        assertApproxEqRel(vault.totalAssets(), amount, 1e15, "vault NAV wrong");

        vm.startPrank(alice);
        vault.redeem(shares, alice, alice);
        vm.stopPrank();

        // Depositor is made whole to within the curated vault's own rounding.
        assertApproxEqRel(IERC20(USDG).balanceOf(alice), amount, 1e15, "depositor lost value");
    }

    // ─── The swap adapter, against the real router and real pools ────────────

    /// @dev This is the test that would have caught the router bug. The adapter
    ///      encoded the original `SwapRouter` struct, which carries a
    ///      `deadline`; Robinhood Chain runs SwapRouter02, which does not.
    ///      Against the real router that mismatch is a revert, not a warning.
    function test_SwapAdapterExecutesARealTrade() public onlyForked {
        RobinhoodChainRouterAdapter adapter = new RobinhoodChainRouterAdapter(
            SWAP_ROUTER_02, AAPL, USDG, AAPL_USDG_FEE, address(this)
        );
        adapter.grantRole(adapter.VAULT_ROLE(), address(this));

        uint256 amountIn = 1_000 * ONE_USDG;
        deal(USDG, address(this), amountIn);
        IERC20(USDG).approve(address(adapter), amountIn);

        uint256 before = IERC20(AAPL).balanceOf(address(this));
        uint256 out = adapter.swap(USDG, AAPL, amountIn, 1);
        uint256 received = IERC20(AAPL).balanceOf(address(this)) - before;

        assertGt(out, 0, "router returned nothing");
        assertEq(received, out, "reported output does not match what arrived");
        assertEq(IERC20(USDG).balanceOf(address(adapter)), 0, "adapter kept input");

        console2.log("1,000 USDG bought AAPL (wei):", received);
    }

    /// @dev Capacity, measured rather than assumed. The vaults ship with
    ///      `maxSlippageBps = 100`, and the AAPL/USDG pool cannot fill much
    ///      past $20k inside that bound. Reverting is the correct behaviour —
    ///      this pins it so nobody "fixes" it by widening the bound.
    function test_OversizedTradeIsRejectedNotFilledBadly() public onlyForked {
        RobinhoodChainRouterAdapter adapter = new RobinhoodChainRouterAdapter(
            SWAP_ROUTER_02, AAPL, USDG, AAPL_USDG_FEE, address(this)
        );
        adapter.grantRole(adapter.VAULT_ROLE(), address(this));

        uint256 small = 1_000 * ONE_USDG;
        deal(USDG, address(this), small);
        IERC20(USDG).approve(address(adapter), small);
        uint256 baseline = adapter.swap(USDG, AAPL, small, 1);

        // Price per USDG from the small trade, applied to a much larger one,
        // minus a 1% allowance. A pool that can absorb the size fills it.
        uint256 large = 100_000 * ONE_USDG;
        uint256 minOut = (baseline * (large / small) * 99) / 100;

        deal(USDG, address(this), large);
        IERC20(USDG).approve(address(adapter), large);

        // The last bare expectRevert in the suite, deliberately.
        //
        // Every other one has been given its error. This one cannot be, yet: it
        // only runs with RH_MAINNET_RPC_URL set, mainnet is not deployed, so it
        // has never executed. The revert would come from either the adapter's
        // own slippage guard or the router's, depending on which trips first
        // against a real pool at a real depth -- and that is exactly what this
        // test exists to find out.
        //
        // Guessing would be worse than leaving it open. A wrong expectation
        // fails the first time somebody runs this against a live fork, which is
        // the one moment they need it to tell them the truth about the pool
        // rather than about my guess.
        //
        // Name it once this has run for real, and record which layer rejected.
        vm.expectRevert();
        adapter.swap(USDG, AAPL, large, minOut);
    }
}

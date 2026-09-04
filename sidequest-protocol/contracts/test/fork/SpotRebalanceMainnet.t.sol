// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SpotVaultMinimal} from "../../src/vaults/SpotVaultMinimal.sol";
import {RobinhoodChainRouterAdapter} from "../../src/adapters/RobinhoodChainRouterAdapter.sol";
import {StrategyExecutor} from "../../src/executor/StrategyExecutor.sol";
import {MockOracle} from "../mocks/MockOracle.sol";

/// @notice A signed rebalance, executed through the real Uniswap pool.
///
///         The one gap no testnet drill can close. Chain 46630 has no DEX at
///         all -- SwapRouter02 has no code there -- which is why SWAP_ROUTER is
///         unset and the deployed adapter is StubSwapAdapter, swapping 1:1 while
///         ignoring price and decimals. Every drill that rebalances on testnet
///         moves tokens through a venue with no market in it, so maxSlippageBps
///         has never decided anything on a real chain.
///
///         Pointing testnet at a real pool is not an option. Running the same
///         path against a mainnet fork is, and it is strictly better evidence:
///
///             signed EIP-712 instruction
///               -> StrategyExecutor  (nonce, expiry, rate limit, signer)
///                 -> SpotVaultMinimal.rebalanceTo
///                   -> RobinhoodChainRouterAdapter
///                     -> the live AAPL/USDG 0.05% pool
///
///         with real depth, real price impact and a real counterparty.
contract SpotRebalanceMainnetForkTest is Test {
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168; // 6dp
    address constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9; // 18dp
    address constant SWAP_ROUTER_02 = 0xCaf681a66D020601342297493863E78C959E5cb2;
    uint24 constant FEE = 500;

    uint256 constant ONE_USDG = 1e6;
    uint16 constant MAX_SLIPPAGE_BPS = 100;   // 1%

    SpotVaultMinimal vault;
    RobinhoodChainRouterAdapter adapter;
    StrategyExecutor executor;
    MockOracle oracle;

    uint256 signerPk = 0x51611E4;
    address signer;
    address alice = address(0xA11CE);

    bool forked;

    function setUp() public {
        string memory url = vm.envOr("RH_MAINNET_RPC_URL", string(""));
        if (bytes(url).length == 0) return;
        vm.createSelectFork(url);
        forked = true;

        signer = vm.addr(signerPk);

        // The oracle has to agree with the pool, or minOut is computed off a
        // price the venue will not honour and every rebalance reverts for the
        // wrong reason. So the price is READ FROM THE POOL rather than pinned to
        // a constant that goes stale the moment AAPL moves.
        adapter = new RobinhoodChainRouterAdapter(SWAP_ROUTER_02, AAPL, USDG, FEE, address(this));
        adapter.grantRole(adapter.VAULT_ROLE(), address(this));

        uint256 probe = 1_000 * ONE_USDG;
        deal(USDG, address(this), probe);
        IERC20(USDG).approve(address(adapter), probe);
        uint256 got = adapter.swap(USDG, AAPL, probe, 1);

        // USDG per AAPL at 8 decimals:
        //   (in / 1e6) / (out / 1e18) * 1e8  ==  in * 1e20 / out
        uint256 price = (probe * 1e20) / got;
        oracle = new MockOracle(int256(price), 8);
        console2.log("AAPL/USDG read from the pool (8dp):", price);

        vault = new SpotVaultMinimal(
            AAPL, USDG, address(oracle), 1 hours,
            "Zorpha tAAPL Long/Flat", "zqtAAPL",
            0,                       // rebalance on any drift
            MAX_SLIPPAGE_BPS,
            0, address(this), address(this), 0
        );

        // A fresh adapter owned by the vault, so VAULT_ROLE is not shared with
        // the test contract that just used it for a price probe.
        adapter = new RobinhoodChainRouterAdapter(SWAP_ROUTER_02, AAPL, USDG, FEE, address(this));
        adapter.grantRole(adapter.VAULT_ROLE(), address(vault));
        vault.setSwapAdapter(address(adapter));

        executor = new StrategyExecutor(address(this));
        executor.setAuthorizedSigner(signer);
        executor.grantRole(executor.KEEPER_ROLE(), address(this));
        executor.setDailyLimit(address(vault), 10);
        vault.grantRole(vault.KEEPER_ROLE(), address(executor));
    }

    modifier onlyForked() {
        if (!forked) { vm.skip(true); }
        _;
    }

    function _deposit(uint256 amount) internal {
        deal(AAPL, alice, amount);
        vm.startPrank(alice);
        IERC20(AAPL).approve(address(vault), amount);
        vault.deposit(amount, alice);
        vm.stopPrank();
    }

    function _sign(uint16 weight, uint256 nonce, uint256 expiry) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(executor.REBALANCE_TYPEHASH(), address(vault), weight, nonce, expiry)
        );
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", executor.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// The whole path, once, against real liquidity. A vault holding only AAPL
    /// is told to go half cash, and half the book crosses the live pool.
    function test_ASignedInstructionTradesThroughTheRealPool() public onlyForked {
        _deposit(100e18);                       // ~100 AAPL, well inside depth

        uint256 aaplBefore = IERC20(AAPL).balanceOf(address(vault));
        uint256 usdgBefore = IERC20(USDG).balanceOf(address(vault));
        uint256 valueBefore = vault.grossValue();
        assertEq(usdgBefore, 0, "the vault started with cash");

        uint256 expiry = block.timestamp + 600;
        executor.executeRebalance(address(vault), 5000, 1, expiry, _sign(5000, 1, expiry));

        uint256 aaplAfter = IERC20(AAPL).balanceOf(address(vault));
        uint256 usdgAfter = IERC20(USDG).balanceOf(address(vault));

        assertLt(aaplAfter, aaplBefore, "no AAPL was sold");
        assertGt(usdgAfter, 0, "no USDG came back");
        assertEq(vault.rebalanceCount(), 1, "the rebalance was not recorded");

        // The cost is real and it is bounded. Both halves matter: a stub venue
        // would show zero cost, and a broken bound would show more than 1%.
        uint256 valueAfter = vault.grossValue();
        uint256 lostBps = ((valueBefore - valueAfter) * 10000) / valueBefore;
        console2.log("AAPL sold (wei):", aaplBefore - aaplAfter);
        console2.log("USDG received  :", usdgAfter);
        console2.log("cost to the vault (bps):", lostBps);

        assertLe(lostBps, MAX_SLIPPAGE_BPS, "the trade cost more than maxSlippageBps allows");
        assertGt(lostBps, 0, "a real pool charged nothing, so this was not a real pool");
    }

    /// Capacity, end to end. The pool absorbs a hundred AAPL and refuses a
    /// hundred thousand, and the refusal reaches the executor rather than being
    /// absorbed somewhere in the middle. A vault sized past the venue is a vault
    /// that cannot rebalance -- correct, and worth proving rather than assuming.
    function test_AVaultTooBigForThePoolCannotRebalance() public onlyForked {
        _deposit(100_000e18);

        // Built BEFORE expectRevert. _sign reads REBALANCE_TYPEHASH and
        // DOMAIN_SEPARATOR off the executor, and those external calls consume
        // the expectation, leaving the real call unguarded -- the same trap as
        // vm.prank being eaten by an inline argument. It presented here as the
        // pool cheerfully absorbing $16m.
        uint256 expiry = block.timestamp + 600;
        bytes memory sig = _sign(5000, 1, expiry);

        vm.expectRevert();
        executor.executeRebalance(address(vault), 5000, 1, expiry, sig);

        assertEq(vault.rebalanceCount(), 0, "an unfillable rebalance was booked");
        assertEq(IERC20(USDG).balanceOf(address(vault)), 0, "a partial fill landed");
    }

    /// And the executor gates still apply when the venue is real. Same signature
    /// twice: the second is refused on the nonce, before any trade is attempted,
    /// so a replayed instruction cannot cross the pool a second time.
    function test_AReplayedInstructionNeverReachesTheVenue() public onlyForked {
        _deposit(100e18);

        uint256 expiry = block.timestamp + 600;
        bytes memory sig = _sign(5000, 1, expiry);
        executor.executeRebalance(address(vault), 5000, 1, expiry, sig);

        uint256 usdgAfterFirst = IERC20(USDG).balanceOf(address(vault));

        vm.expectRevert(
            abi.encodeWithSelector(StrategyExecutor.NonceAlreadyUsed.selector, address(vault), 1)
        );
        executor.executeRebalance(address(vault), 5000, 1, expiry, sig);

        assertEq(IERC20(USDG).balanceOf(address(vault)), usdgAfterFirst, "the replay traded");
        assertEq(vault.rebalanceCount(), 1, "the replay was booked");
    }

    /// Round trip. Half out to cash and all the way back to the equity, paying
    /// the venue twice. Two crossings at the pool fee plus impact must still
    /// leave the depositor with most of what they came with -- and the exact
    /// figure is logged, because "how much does rebalancing actually cost" is a
    /// product question this is the only place that answers.
    function test_ARoundTripCostsTwoCrossingsAndNoMore() public onlyForked {
        _deposit(100e18);
        uint256 valueBefore = vault.grossValue();

        uint256 e1 = block.timestamp + 600;
        executor.executeRebalance(address(vault), 5000, 1, e1, _sign(5000, 1, e1));

        uint256 e2 = block.timestamp + 600;
        executor.executeRebalance(address(vault), 10000, 2, e2, _sign(10000, 2, e2));

        uint256 valueAfter = vault.grossValue();
        uint256 lostBps = ((valueBefore - valueAfter) * 10000) / valueBefore;
        console2.log("round-trip cost (bps):", lostBps);

        assertEq(vault.rebalanceCount(), 2, "the return leg did not execute");
        assertLt(IERC20(USDG).balanceOf(address(vault)), 1e6, "the vault did not return to the equity");
        assertLe(lostBps, uint256(MAX_SLIPPAGE_BPS) * 2, "a round trip cost more than two bounded crossings");
    }

    /// The balance-delta check from #38, now against a venue nobody here wrote.
    /// The router reports its own amountOut; the vault ignores that and measures
    /// what arrived. Both should agree here -- the point is that they are
    /// checked against each other on real infrastructure.
    function test_WhatTheRouterReportsIsWhatTheVaultReceives() public onlyForked {
        _deposit(50e18);

        uint256 before = IERC20(USDG).balanceOf(address(vault));
        uint256 expiry = block.timestamp + 600;

        vm.recordLogs();
        executor.executeRebalance(address(vault), 5000, 1, expiry, _sign(5000, 1, expiry));

        uint256 arrived = IERC20(USDG).balanceOf(address(vault)) - before;
        assertGt(arrived, 0, "nothing arrived");

        // The adapter emits its own view of the fill; it must match the balance.
        uint256 reported;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("Swapped(address,address,address,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == topic) {
                // Only `caller` is indexed, so tokenIn, tokenOut, amountIn and
                // amountOut all sit in data.
                (,, , uint256 amountOut) =
                    abi.decode(logs[i].data, (address, address, uint256, uint256));
                reported = amountOut;
            }
        }
        assertEq(reported, arrived, "the router reported a fill the vault did not receive");
    }
}

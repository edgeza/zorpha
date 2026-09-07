// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SpotVaultMinimal} from "../../src/vaults/SpotVaultMinimal.sol";
import {UniswapV3TwapAdapter} from "../../src/oracle/UniswapV3TwapAdapter.sol";

interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256);
}

/// @notice Rehearses the seed batch against the DEPLOYED vault, as the Safe,
///         using the Safe's real USDG balance. The point is to produce the
///         exact amounts the Safe batch will carry, rather than estimate them.
contract SeedStockVaultTest is Test {
    address constant VAULT = 0xB129495f0ad616EdD2f28b3B49470FC1f0FAD413;
    address constant ORACLE = 0xaBefb351777d8E68FCafa4D2F8A5848F326298cA;
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant ROUTER = 0xCaf681a66D020601342297493863E78C959E5cb2;
    address constant SAFE = 0xC75E64Ccf3ce6E2F40939Ab58255681769BcF8C4;
    uint24 constant FEE = 500;

    uint256 constant SWAP_USDG = 13_000_000; // 13.000000 USDG, round, leaves a margin

    /// The swap's amountOutMinimum AND the exact deposit, deliberately the same
    /// number. A Safe batch cannot read the swap's output and feed it to the
    /// deposit, so the floor becomes the contract: clear it and the deposit is
    /// guaranteed to have the tokens, miss it and the swap reverts and takes
    /// the whole batch with it. Rehearsal produced 55,993,818,356,212,997 at
    /// $231.998, so this sits about 1.06% below, which is room for the price to
    /// move between signing and execution. Anything above it stays in the Safe.
    uint256 constant SEED_NVDA = 55_400_000_000_000_000; // 0.0554 NVDA

    bool forked;

    function setUp() public {
        string memory url = vm.envOr("RH_MAINNET_RPC_URL", string(""));
        if (bytes(url).length == 0) return;
        vm.createSelectFork(url);
        forked = true;
    }

    function test_SeedAndFirstRebalance() public {
        if (!forked) { vm.skip(true); }

        SpotVaultMinimal vault = SpotVaultMinimal(VAULT);
        console2.log("Safe USDG before   :", IERC20(USDG).balanceOf(SAFE));
        (, int256 answer, , , ) = UniswapV3TwapAdapter(ORACLE).latestRoundData();
        console2.log("oracle (1e8)       :", uint256(answer));

        vm.startPrank(SAFE);

        // 1. approve the router, 2. swap USDG for NVDA
        IERC20(USDG).approve(ROUTER, SWAP_USDG);
        uint256 got = ISwapRouter02(ROUTER).exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: USDG,
                tokenOut: NVDA,
                fee: FEE,
                recipient: SAFE,
                amountIn: SWAP_USDG,
                amountOutMinimum: SEED_NVDA,
                sqrtPriceLimitX96: 0
            })
        );
        console2.log("NVDA received      :", got);
        console2.log("implied price 1e8  :", (SWAP_USDG * 1e20) / got);

        // 3. approve the vault, 4. deposit
        // The batch approves and deposits the FIXED amount, not `got`.
        IERC20(NVDA).approve(VAULT, SEED_NVDA);
        uint256 shares = vault.deposit(SEED_NVDA, SAFE);
        console2.log("NVDA left in Safe  :", IERC20(NVDA).balanceOf(SAFE));
        console2.log("shares minted      :", shares);
        console2.log("vault totalAssets  :", vault.totalAssets());

        // 5. the first real manager call: half out of NVDA, into cash.
        vault.rebalanceTo(5000);
        vm.stopPrank();

        console2.log("--- after rebalanceTo(5000) ---");
        console2.log("rebalanceCount     :", vault.rebalanceCount());
        console2.log("targetWeightBps    :", vault.targetWeightBps());
        console2.log("NVDA leg           :", IERC20(NVDA).balanceOf(VAULT));
        console2.log("USDG leg           :", IERC20(USDG).balanceOf(VAULT));
        console2.log("totalAssets        :", vault.totalAssets());
        console2.log("navPerShare        :", vault.getNavPerShare());

        assertEq(vault.rebalanceCount(), 1, "no receipt emitted");
        assertGt(IERC20(USDG).balanceOf(VAULT), 0, "no cash leg");
        assertGt(IERC20(NVDA).balanceOf(VAULT), 0, "no asset leg");
    }
}

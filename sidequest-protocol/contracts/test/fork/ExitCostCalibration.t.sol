// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ISpotSwap { function swap(address, address, uint256, uint256) external returns (uint256); }
interface IAgg { function latestRoundData() external view returns (uint80,int256,uint256,uint256,uint80); }

/// @notice What does converting the cash leg ACTUALLY cost on the live pool?
///
/// exitCostBps is immutable and prices every exit, so its value is a one-shot
/// decision at deploy. Too low and a large exit reverts under price impact;
/// too high and every exit donates the difference to whoever stays. The range
/// is "above the fee tier, well below a rebalance bound", which is not a
/// number. This measures the number.
///
/// Method: ask the real router adapter to convert USDG into NVDA at sizes a
/// real exit would need, and compare what it delivers against the oracle's
/// price. The gap is the realised cost, fee plus impact, in basis points.
///
/// MEASURED 8 September 2026, and the result inverts the naive expectation:
///
///     USDG in            realised vs oracle-fair
///     1 to 1,000         22 bps BETTER than fair
///     10,000             21 bps better
///     100,000            15 bps better, so impact is about 7 bps there
///
/// The conversion currently GAINS about 22 bps, because the 30 minute TWAP lags
/// spot and spot had drifted down. The 5 bps pool fee is swamped by
/// TWAP-versus-spot drift, and that drift changes sign with market direction.
///
/// WHICH IS WHY exitCostBps CANNOT BE SET AT THE FEE TIER. The adapter reports
/// a price up to maxSpotDivergenceBps, 200, away from spot and still answers,
/// so an adverse conversion can cost up to 207 bps including impact. Set
/// exitCostBps below that and an exit during adverse-but-tolerated divergence
/// reverts on minOut after maxRedeem advertised it, which is the lying-bound
/// defect this whole slice exists to remove. Set it above and the exiter is
/// charged 207 bps when the realised cost is negative, all of it a windfall to
/// whoever stays.
///
/// Re-run this before choosing the value; drift moves.
contract ExitCostCalibrationTest is Test {
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant ORACLE = 0xaBefb351777d8E68FCafa4D2F8A5848F326298cA;
    address constant SWAP = 0x8E50FC336f87b454cc44a89dA3a7267412B045dc;
    address constant OLD_VAULT = 0xB129495f0ad616EdD2f28b3B49470FC1f0FAD413;
    bytes32 constant VAULT_ROLE =
        0x31e0210044b4f6757ce6aa31f9c6e8d4896d24a755014887391a926c5224d959;
    address constant TIMELOCK = 0x813D69B8e1DBE2E08bcB892BE203A6BCE99b36Fc;

    bool forked;
    function setUp() public {
        string memory url = vm.envOr("RH_MAINNET_RPC_URL", string(""));
        if (bytes(url).length == 0) return;
        vm.createSelectFork(url); forked = true;
    }

    function test_RealisedConversionCostBySize() public {
        if (!forked) { vm.skip(true); }

        (, int256 answer,,,) = IAgg(ORACLE).latestRoundData();
        uint256 p = uint256(answer);           // NVDA per USDG, 8dp
        console2.log("oracle answer (8dp)", p);
        console2.log("");

        // Let this test contract use the adapter directly.
        vm.prank(TIMELOCK);
        (bool ok,) = SWAP.call(
            abi.encodeWithSignature("grantRole(bytes32,address)", VAULT_ROLE, address(this)));
        require(ok, "grant failed");

        // Sizes a real exit would convert, in USDG. The live vault's whole
        // position is about 13 USDG, so start well below it and climb past
        // anything plausible for early depositors.
        uint256[6] memory sizes = [uint256(1e6), 10e6, 100e6, 1_000e6, 10_000e6, 100_000e6];
        for (uint256 i = 0; i < sizes.length; i++) {
            uint256 snap = vm.snapshotState();
            uint256 cashIn = sizes[i];
            deal(USDG, address(this), cashIn);
            IERC20(USDG).approve(SWAP, cashIn);

            // Oracle-priced expectation for this much cash, in NVDA wei.
            uint256 fair = (cashIn * 1e18 * 1e8) / (1e6 * p);

            uint256 before = IERC20(NVDA).balanceOf(address(this));
            (bool sok, bytes memory ret) = SWAP.call(
                abi.encodeWithSignature("swap(address,address,uint256,uint256)",
                                        USDG, NVDA, cashIn, 0));
            if (!sok) {
                console2.log("USDG in", cashIn / 1e6);
                console2.log("   SWAP REVERTED, size beyond the pool");
                vm.revertToState(snap);
                continue;
            }
            ret;
            uint256 got = IERC20(NVDA).balanceOf(address(this)) - before;

            console2.log("USDG in", cashIn / 1e6);
            console2.log("   fair (NVDA wei)    ", fair);
            console2.log("   received           ", got);
            if (got < fair) {
                console2.log("   realised cost, bps ", ((fair - got) * 10000) / fair);
            } else {
                console2.log("   received MORE than oracle fair, bps better",
                             ((got - fair) * 10000) / fair);
            }
            vm.revertToState(snap);
        }
        console2.log("");
        console2.log("exitCostBps must exceed the realised cost at the sizes you");
        console2.log("intend to serve, or those exits revert instead of overcharging.");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RobinhoodChainRouterAdapter} from "../../src/adapters/RobinhoodChainRouterAdapter.sol";

/// @notice What the AAPL/USDG pool can actually absorb, today.
contract PoolDepthProbe is Test {
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant SWAP_ROUTER_02 = 0xCaf681a66D020601342297493863E78C959E5cb2;
    address constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    uint24 constant FEE = 500;
    uint256 constant ONE_USDG = 1e6;

    bool forked;

    function setUp() public {
        string memory url = vm.envOr("RH_MAINNET_RPC_URL", string(""));
        if (bytes(url).length == 0) return;
        vm.createSelectFork(url);
        forked = true;
    }

    function test_MeasureDepth() public {
        if (!forked) { vm.skip(true); }

        RobinhoodChainRouterAdapter adapter = new RobinhoodChainRouterAdapter(
            SWAP_ROUTER_02, AAPL, USDG, FEE, address(this)
        );
        adapter.grantRole(adapter.VAULT_ROLE(), address(this));

        // Reference price from a small trade.
        uint256 ref = 1_000 * ONE_USDG;
        deal(USDG, address(this), ref);
        IERC20(USDG).approve(address(adapter), ref);
        uint256 refOut = adapter.swap(USDG, AAPL, ref, 1);
        console2.log("reference: 1,000 USDG ->", refOut);

        uint256[7] memory sizes = [
            uint256(10_000), 20_000, 40_000, 100_000, 250_000, 500_000, 1_000_000
        ];

        for (uint256 i = 0; i < sizes.length; i++) {
            uint256 amt = sizes[i] * ONE_USDG;
            deal(USDG, address(this), amt);
            IERC20(USDG).approve(address(adapter), amt);

            uint256 snap = vm.snapshotState();
            uint256 got = adapter.swap(USDG, AAPL, amt, 1);
            vm.revertToState(snap);

            // Linear-extrapolated fair output from the reference trade.
            uint256 fair = (refOut * amt) / ref;
            uint256 costBps = fair > got ? ((fair - got) * 10000) / fair : 0;
            console2.log("size (USDG):", sizes[i]);
            console2.log("   cost bps:", costBps);

            // And who refuses it at a 100bps bound: the router, or our adapter?
            uint256 bound = (fair * 9900) / 10000;
            uint256 s2 = vm.snapshotState();
            try adapter.swap(USDG, AAPL, amt, bound) returns (uint256) {
                console2.log("   at 100bps bound: FILLED");
            } catch Error(string memory reason) {
                console2.log("   at 100bps bound: refused ->", reason);
            } catch (bytes memory raw) {
                console2.log("   at 100bps bound: refused, selector:", vm.toString(bytes4(raw)));
            }
            vm.revertToState(s2);
        }
    }
}

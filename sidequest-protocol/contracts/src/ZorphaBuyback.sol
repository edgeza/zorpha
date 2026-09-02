// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ISpotSwapAdapter} from "./adapters/RobinhoodChainRouterAdapter.sol";

interface IZorphaBurnable {
    function burn(uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
}

/// @title ZorphaBuyback
/// @dev    Every USDC in this file used to say USDC, including the public
///         `usdc` immutable, `totalUsdcSpent`, `withdrawUsdc` and the
///         `UsdcWithdrawn` event. Robinhood Chain has no canonical USDC
///         deployment; its stablecoin is Paxos USDG, which is what the vaults
///         actually hold and therefore what fee revenue arrives as. Renamed
///         before mainnet on purpose: `withdrawUsdc` and `UsdcWithdrawn` are
///         a selector and a topic hash, so changing them afterwards would
///         either break integrators or leave the wrong name on chain forever.
/// @notice Converts protocol fee revenue (USDG) into $ZOR on the open market
///         and burns it, permanently reducing supply.
///
///         Execution is permissionless: anyone may call `execute` once the USDG
///         balance clears `minBuybackThreshold`. The caller supplies
///         `minZorOut`, so a sandwich attempt cannot force the protocol to
///         accept an arbitrarily bad fill.
///
///         Every `BuybackExecuted` event reports the USDG actually spent and
///         the ZOR actually burned, both measured by balance delta rather than
///         by return value, so an adapter cannot over-report a burn.
contract ZorphaBuyback is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice The $ZOR token. Burned, never sent to a dead address, so
    ///         `totalSupply()` is always the truthful circulating ceiling.
    IERC20 public immutable zor;

    /// @notice Fee revenue asset (USDG).
    IERC20 public immutable usdg;

    /// @notice Swap venue used to convert USDG -> ZOR.
    ISpotSwapAdapter public router;

    /// @notice Minimum USDG balance before a buyback may run.
    uint256 public minBuybackThreshold;

    /// @notice Running total of USDG actually spent on buybacks.
    uint256 public totalUsdgSpent;

    /// @notice Running total of ZOR actually burned.
    uint256 public totalZorBurned;

    event BuybackExecuted(address indexed caller, uint256 usdgSpent, uint256 zorBurned);
    event RouterUpdated(address indexed oldRouter, address indexed newRouter);
    event ThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    event UsdgWithdrawn(address indexed to, uint256 amount);

    error BelowThreshold(uint256 currentBalance, uint256 threshold);
    error RouterNotSet();
    error NothingSwapped();
    error InsufficientOutput(uint256 received, uint256 minExpected);
    error ZeroAddress();

    constructor(address zor_, address usdg_, uint256 minThreshold_, address owner_)
        Ownable(owner_)
    {
        if (zor_ == address(0) || usdg_ == address(0) || owner_ == address(0)) {
            revert ZeroAddress();
        }
        zor = IERC20(zor_);
        usdg = IERC20(usdg_);
        minBuybackThreshold = minThreshold_;
    }

    /// @notice Buy $ZOR with the full USDG balance and burn everything received.
    /// @param minZorOut Minimum ZOR the caller will accept for the swap. Callers
    ///        should quote offchain and apply their own slippage tolerance.
    /// @return usdgSpent USDG actually consumed by the swap.
    /// @return zorBurned ZOR actually burned.
    // slither: the balance snapshots either side of the swap ARE the defence,
    // not a stale read. execute() is nonReentrant, every other entrypoint here
    // is Timelock-only, and the router itself is set by the Timelock, so there
    // is no path for a swap callee to re-enter and move these balances. Both
    // deltas are also floored by the post-call balance, so a router that
    // donates tokens mid-swap can only revert the call, never inflate a burn.
    // The ignored swap() return is the point: see the comment below it.
    // slither-disable-next-line reentrancy-balance,unused-return
    function execute(uint256 minZorOut)
        external
        nonReentrant
        returns (uint256 usdgSpent, uint256 zorBurned)
    {
        ISpotSwapAdapter router_ = router;
        if (address(router_) == address(0)) revert RouterNotSet();

        uint256 usdgBefore = usdg.balanceOf(address(this));
        if (usdgBefore < minBuybackThreshold) {
            revert BelowThreshold(usdgBefore, minBuybackThreshold);
        }

        uint256 zorBefore = zor.balanceOf(address(this));

        // Approve exactly what we intend to spend, then clear any residual.
        usdg.forceApprove(address(router_), usdgBefore);
        router_.swap(address(usdg), address(zor), usdgBefore, minZorOut);
        usdg.forceApprove(address(router_), 0);

        // Measure both legs by balance delta. Never trust the adapter's return
        // value: a malicious or buggy router could over-report the fill.
        usdgSpent = usdgBefore - usdg.balanceOf(address(this));
        zorBurned = zor.balanceOf(address(this)) - zorBefore;

        if (usdgSpent == 0) revert NothingSwapped();
        if (zorBurned < minZorOut) revert InsufficientOutput(zorBurned, minZorOut);

        totalUsdgSpent += usdgSpent;
        totalZorBurned += zorBurned;

        IZorphaBurnable(address(zor)).burn(zorBurned);

        emit BuybackExecuted(msg.sender, usdgSpent, zorBurned);
    }

    /// @notice Point buybacks at a new swap venue. Owner is the Timelock.
    function setRouter(address newRouter) external onlyOwner {
        if (newRouter == address(0)) revert ZeroAddress();
        emit RouterUpdated(address(router), newRouter);
        router = ISpotSwapAdapter(newRouter);
    }

    function setThreshold(uint256 newThreshold) external onlyOwner {
        emit ThresholdUpdated(minBuybackThreshold, newThreshold);
        minBuybackThreshold = newThreshold;
    }

    /// @notice Escape hatch so fee revenue can never be permanently stranded
    ///         here if no ZOR route exists yet. Timelock-gated.
    function withdrawUsdg(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        emit UsdgWithdrawn(to, amount);
        usdg.safeTransfer(to, amount);
    }

    /// @notice Recover a token misrouted to this contract. USDG and ZOR are
    ///         excluded: USDG has its own timelocked path above, and ZOR held
    ///         here is destined for the burn.
    function rescueToken(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        require(
            token != address(zor) && token != address(usdg),
            "ZorphaBuyback: use withdrawUsdg / burn path"
        );
        IERC20(token).safeTransfer(to, amount);
    }
}

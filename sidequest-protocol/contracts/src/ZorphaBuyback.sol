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
/// @notice Converts protocol fee revenue (USDC) into $ZOR on the open market
///         and burns it, permanently reducing supply.
///
///         Execution is permissionless: anyone may call `execute` once the USDC
///         balance clears `minBuybackThreshold`. The caller supplies
///         `minZorOut`, so a sandwich attempt cannot force the protocol to
///         accept an arbitrarily bad fill.
///
///         Every `BuybackExecuted` event reports the USDC actually spent and
///         the ZOR actually burned, both measured by balance delta rather than
///         by return value, so an adapter cannot over-report a burn.
contract ZorphaBuyback is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice The $ZOR token. Burned, never sent to a dead address, so
    ///         `totalSupply()` is always the truthful circulating ceiling.
    IERC20 public immutable zor;

    /// @notice Fee revenue asset (USDC).
    IERC20 public immutable usdc;

    /// @notice Swap venue used to convert USDC -> ZOR.
    ISpotSwapAdapter public router;

    /// @notice Minimum USDC balance before a buyback may run.
    uint256 public minBuybackThreshold;

    /// @notice Running total of USDC actually spent on buybacks.
    uint256 public totalUsdcSpent;

    /// @notice Running total of ZOR actually burned.
    uint256 public totalZorBurned;

    event BuybackExecuted(address indexed caller, uint256 usdcSpent, uint256 zorBurned);
    event RouterUpdated(address indexed oldRouter, address indexed newRouter);
    event ThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    event UsdcWithdrawn(address indexed to, uint256 amount);

    error BelowThreshold(uint256 currentBalance, uint256 threshold);
    error RouterNotSet();
    error NothingSwapped();
    error InsufficientOutput(uint256 received, uint256 minExpected);
    error ZeroAddress();

    constructor(address zor_, address usdc_, uint256 minThreshold_, address owner_)
        Ownable(owner_)
    {
        if (zor_ == address(0) || usdc_ == address(0) || owner_ == address(0)) {
            revert ZeroAddress();
        }
        zor = IERC20(zor_);
        usdc = IERC20(usdc_);
        minBuybackThreshold = minThreshold_;
    }

    /// @notice Buy $ZOR with the full USDC balance and burn everything received.
    /// @param minZorOut Minimum ZOR the caller will accept for the swap. Callers
    ///        should quote offchain and apply their own slippage tolerance.
    /// @return usdcSpent USDC actually consumed by the swap.
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
        returns (uint256 usdcSpent, uint256 zorBurned)
    {
        ISpotSwapAdapter router_ = router;
        if (address(router_) == address(0)) revert RouterNotSet();

        uint256 usdcBefore = usdc.balanceOf(address(this));
        if (usdcBefore < minBuybackThreshold) {
            revert BelowThreshold(usdcBefore, minBuybackThreshold);
        }

        uint256 zorBefore = zor.balanceOf(address(this));

        // Approve exactly what we intend to spend, then clear any residual.
        usdc.forceApprove(address(router_), usdcBefore);
        router_.swap(address(usdc), address(zor), usdcBefore, minZorOut);
        usdc.forceApprove(address(router_), 0);

        // Measure both legs by balance delta. Never trust the adapter's return
        // value: a malicious or buggy router could over-report the fill.
        usdcSpent = usdcBefore - usdc.balanceOf(address(this));
        zorBurned = zor.balanceOf(address(this)) - zorBefore;

        if (usdcSpent == 0) revert NothingSwapped();
        if (zorBurned < minZorOut) revert InsufficientOutput(zorBurned, minZorOut);

        totalUsdcSpent += usdcSpent;
        totalZorBurned += zorBurned;

        IZorphaBurnable(address(zor)).burn(zorBurned);

        emit BuybackExecuted(msg.sender, usdcSpent, zorBurned);
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
    function withdrawUsdc(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        emit UsdcWithdrawn(to, amount);
        usdc.safeTransfer(to, amount);
    }

    /// @notice Recover a token misrouted to this contract. USDC and ZOR are
    ///         excluded: USDC has its own timelocked path above, and ZOR held
    ///         here is destined for the burn.
    function rescueToken(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        require(
            token != address(zor) && token != address(usdc),
            "ZorphaBuyback: use withdrawUsdc / burn path"
        );
        IERC20(token).safeTransfer(to, amount);
    }
}

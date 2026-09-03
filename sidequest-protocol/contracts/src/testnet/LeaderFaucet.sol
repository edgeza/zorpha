// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface ILauncherParams {
    function bondAmount() external view returns (uint256);
    function minSeedEscrow() external view returns (uint256);
}

interface IMintable {
    function mint(address to, uint256 amount) external;
}

/// @title LeaderFaucet
/// @notice Hands a prospective vault leader exactly one bond plus one seed, so
///         they can launch a testnet vault without asking anybody.
///
/// WHY THIS HAS TO EXIST
///
/// The leader programme is the protocol's whole differentiator: a leader posts
/// a refundable $ZOR bond and their own first-loss capital, and competes on a
/// record they cannot edit. It has been live on testnet since day one, and
/// exactly one person has ever used it -- the person who deployed it.
///
/// Not for lack of interest. It was impossible. `launchYieldVault` needs
/// 10,000 ZOR for the bond, and Zorpha has NO MINT FUNCTION: the entire supply
/// is minted in the constructor and distributed atomically. There is no faucet,
/// no testnet mint, nothing. A stranger who wanted to run a vault had to ask
/// governance to send them tokens by hand, which is not a programme, it is a
/// favour.
///
/// That matters more than it sounds. The only live precedent for the launch
/// mechanism this protocol intends to use -- Aztec's Continuous Clearing
/// Auction -- raised $59M from roughly 17,000 bidders, and HALF the capital
/// came from their existing community of testnet operators and early users. A
/// testnet nobody outside the team can participate in produces no such cohort.
///
/// WHAT IT DOES NOT DO
///
/// It does not hand out ETH for gas. That comes from the chain's own faucet and
/// is not this contract's business.
///
/// It does not make anybody a leader. It provides the entry ticket; the bond is
/// still at risk, the first-loss capital is still theirs, and the record is
/// still public.
///
/// TESTNET ONLY, ENFORCED
///
/// `claim` reverts on chain 4663. Not a comment, not a deploy-time flag -- a
/// runtime check, because a faucet that hands out real bonds is a hole in the
/// treasury and this contract would otherwise be one `LIQUIDITY_RECIPIENT`
/// mistake away from being funded on mainnet.
contract LeaderFaucet is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @dev Robinhood Chain mainnet. Kept local rather than imported so this
    ///      testnet fixture pulls in nothing from the production tree.
    uint256 public constant MAINNET_CHAIN_ID = 4663;

    IERC20 public immutable zor;
    IMintable public immutable usdg;
    ILauncherParams public immutable launcher;

    /// @notice One claim per address, ever.
    mapping(address => bool) public hasClaimed;

    /// @notice How many tickets have been handed out.
    uint256 public claimCount;

    /// @notice Hard ceiling, so a compromised faucet cannot drain the float in
    ///         one block even if the per-address guard is somehow bypassed.
    uint256 public maxClaims;

    error NotOnMainnet();
    error AlreadyClaimed(address who);
    error FaucetExhausted(uint256 claimed, uint256 cap);
    error FaucetEmpty(uint256 have, uint256 need);
    error ZeroAddress();

    event Claimed(address indexed leader, uint256 bond, uint256 seed);
    event MaxClaimsSet(uint256 previous, uint256 next);
    event Swept(address indexed to, uint256 amount);

    constructor(
        address zor_,
        address usdg_,
        address launcher_,
        address owner_,
        uint256 maxClaims_
    ) Ownable(owner_) {
        if (zor_ == address(0) || usdg_ == address(0) || launcher_ == address(0)) {
            revert ZeroAddress();
        }
        zor = IERC20(zor_);
        usdg = IMintable(usdg_);
        launcher = ILauncherParams(launcher_);
        maxClaims = maxClaims_;
    }

    /// @notice Amounts a claim will pay out, read live from the launcher.
    ///
    /// @dev Read rather than stored. If governance raises `bondAmount`, a
    ///      faucet holding a stale copy would hand out too little and every
    ///      launch attempt would revert on an allowance the claimant had no
    ///      way to understand. Coupling it to the source is the difference
    ///      between a faucet and a trap.
    function ticket() public view returns (uint256 bond, uint256 seed) {
        bond = launcher.bondAmount();
        seed = launcher.minSeedEscrow();
    }

    /// @notice How many more leaders this faucet can onboard.
    ///
    /// @dev Bounded by both the cap and the actual ZOR balance, because
    ///      "42 claims remaining" is a lie if the float ran out at 3.
    function claimsRemaining() external view returns (uint256) {
        if (claimCount >= maxClaims) return 0;
        (uint256 bond,) = ticket();
        if (bond == 0) return maxClaims - claimCount;

        uint256 byBalance = zor.balanceOf(address(this)) / bond;
        uint256 byCap = maxClaims - claimCount;
        return byBalance < byCap ? byBalance : byCap;
    }

    /// @notice Take one bond and one seed. Once per address.
    function claim() external nonReentrant returns (uint256 bond, uint256 seed) {
        // First, and unconditionally.
        if (block.chainid == MAINNET_CHAIN_ID) revert NotOnMainnet();

        if (hasClaimed[msg.sender]) revert AlreadyClaimed(msg.sender);
        if (claimCount >= maxClaims) revert FaucetExhausted(claimCount, maxClaims);

        (bond, seed) = ticket();

        uint256 held = zor.balanceOf(address(this));
        if (held < bond) revert FaucetEmpty(held, bond);

        // Set before transferring. The guard makes re-entry impossible anyway,
        // but a faucet is the last place to rely on one guard.
        hasClaimed[msg.sender] = true;
        claimCount += 1;

        zor.safeTransfer(msg.sender, bond);
        // TestUSDG's mint is deliberately open, so the seed costs the float
        // nothing and cannot run out independently of the bond.
        usdg.mint(msg.sender, seed);

        emit Claimed(msg.sender, bond, seed);
    }

    // ─── Governance ─────────────────────────────────────────────────────────

    function setMaxClaims(uint256 next) external onlyOwner {
        emit MaxClaimsSet(maxClaims, next);
        maxClaims = next;
    }

    /// @notice Recover the unclaimed float.
    ///
    /// @dev Deliberately not restricted to "only what is unclaimed", because
    ///      there is no such distinction: every ZOR here is unclaimed until
    ///      somebody claims it. The owner funded it and can take it back.
    function sweep(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        zor.safeTransfer(to, amount);
        emit Swept(to, amount);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/*
 * ─────────────────────────────────────────────────────────────────────────────
 *  TESTNET ONLY. NOTHING IN THIS FILE MAY BE DEPLOYED TO MAINNET.
 *
 *  Every contract here mints for free to anyone who asks. On a chain with real
 *  money that is not a test fixture, it is an unlimited printing press.
 *
 *  These exist because Robinhood Chain testnet (46630) is a bare chain: no
 *  USDG, no Morpho vaults, no Uniswap pools. Verified by calling the mainnet
 *  addresses against the testnet RPC, where none of them have code. Without
 *  stand-ins there is nothing on testnet to test the protocol against.
 *
 *  `DeployTestnetFixtures.s.sol` refuses to run on chain 4663.
 * ─────────────────────────────────────────────────────────────────────────────
 */

/// @notice Stand-in for Global Dollar (USDG): six decimals, like the real one.
/// @dev Six decimals is the detail that matters. Testing a vault against an
///      18-decimal mock and deploying against a 6-decimal asset is how decimal
///      bugs reach production, and this protocol already carries a 6-place
///      share offset that interacts with it.
contract TestUSDG is ERC20 {
    constructor() ERC20("Test Global Dollar", "tUSDG") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Open faucet. See the banner above.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Stand-in for a tokenised equity: eighteen decimals, as on mainnet.
contract TestEquity is ERC20 {
    uint8 private constant DECIMALS = 18;

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function decimals() public pure override returns (uint8) {
        return DECIMALS;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Stand-in for a curated ERC-4626 vault such as Steakhouse USDG.
///
///         `accrue()` is what makes this useful: it donates underlying to the
///         vault, raising the share price exactly the way earned yield does.
///         Without a way to make the target appreciate on demand, a testnet
///         run cannot demonstrate that yield reaches depositors, which is the
///         single behaviour the whole yield vault exists for.
contract TestYieldTarget is ERC4626 {
    constructor(IERC20 asset_) ERC4626(asset_) ERC20("Test Curated USDG", "tcUSDG") {}

    /// @notice Simulate earned yield.
    function accrue(uint256 amount) external {
        TestUSDG(asset()).mint(address(this), amount);
    }
}

/// @notice A curated-vault stand-in that can lose money as well as make it.
/// @dev    TestYieldTarget above only accrues. That makes the one mechanism
///         this protocol exists for -- the leader's capital absorbing a loss
///         before any depositor's -- impossible to demonstrate on a live
///         chain. There is no drain on an ERC-4626, TestUSDG has no burn, and
///         assets cannot leave a vault without shares. The fixture is
///         structurally incapable of going down.
///
///         The absorption path is well covered by unit tests, but those mock
///         the venue. What they cannot exercise is the real integration: the
///         vault pulls from ERC4626YieldAdapter, which measures what it
///         recovered by balance delta rather than by trusting the venue's
///         return value. A venue that gives back less than asked for is
///         precisely the case that accounting exists to handle, and precisely
///         the case a mock is least likely to reproduce faithfully.
///
///         `lose()` sends underlying to a burn address rather than burning it,
///         so this needs no change to TestUSDG and no redeploy of the token
///         every other fixture already points at. The effect on share price is
///         identical: the same shares, backed by fewer assets.
contract LossyYieldTarget is ERC4626 {
    /// @dev Not address(0): ERC-20 transfers to the zero address revert.
    address public constant SINK = 0x000000000000000000000000000000000000dEaD;

    constructor(IERC20 asset_) ERC4626(asset_) ERC20("Test Lossy USDG", "tlUSDG") {}

    /// @notice Simulate earned yield.
    function accrue(uint256 amount) external {
        TestUSDG(asset()).mint(address(this), amount);
    }

    /// @notice Simulate a loss. Same shares outstanding, fewer assets behind
    ///         them, so the share price falls exactly as it would if the
    ///         venue's holdings had fallen in value.
    function lose(uint256 amount) external {
        IERC20(asset()).transfer(SINK, amount);
    }
}

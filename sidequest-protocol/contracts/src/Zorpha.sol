// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";

/// @title Zorpha ($ZOR)
/// @notice Fixed-supply ERC-20 for the Zorpha protocol.
///
///         Supply: 1,000,000,000 ZOR, 18 decimals, minted once in the
///         constructor. There is no mint function, no owner, no admin, no
///         pause, no blocklist, no transfer hook and no upgrade path. The
///         entire supply exists at deploy time and can only ever go down,
///         via `burn` / `burnFrom`.
///
///         Voting: the token carries ERC20Votes checkpoints, so holders have
///         real, measurable onchain voting weight. No Governor is wired at
///         launch — see docs/GOVERNANCE.md for the honest statement of what
///         that does and does not mean today.
///
///         Clock: checkpoints are keyed to `block.timestamp` (ERC-6372), not
///         block numbers. Robinhood Chain block times are not guaranteed
///         stable, so a block-number clock would make any future governance
///         period drift in wall-clock terms.
contract Zorpha is ERC20Votes, ERC20Permit {
    /// @notice Total (and maximum) supply: 1,000,000,000 ZOR.
    uint256 public constant MAX_SUPPLY = 1_000_000_000 * 10 ** 18;

    /// @param initialHolder Address that receives the entire supply. Intended
    ///        to be the distribution script / Safe that atomically splits the
    ///        supply across the published allocation buckets.
    constructor(address initialHolder)
        ERC20("Zorpha", "ZOR")
        ERC20Permit("Zorpha")
    {
        require(initialHolder != address(0), "Zorpha: zero initial holder");
        _mint(initialHolder, MAX_SUPPLY);
    }

    /// @notice Burn `amount` from the caller, permanently reducing total supply.
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    /// @notice Burn `amount` from `account` using the caller's allowance.
    function burnFrom(address account, uint256 amount) external {
        _spendAllowance(account, msg.sender, amount);
        _burn(account, amount);
    }

    // ─── ERC-6372: timestamp-based voting clock ──────────────────────────────

    /// @notice Voting checkpoints are keyed to block timestamps.
    function clock() public view override returns (uint48) {
        return uint48(block.timestamp);
    }

    /// @notice ERC-6372 machine-readable description of `clock()`.
    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }

    // ─── Diamond-inheritance resolution ─────────────────────────────────────

    /// @dev Both ERC20 and ERC20Votes define `_update`.
    function _update(address from, address to, uint256 value)
        internal
        override(ERC20, ERC20Votes)
    {
        super._update(from, to, value);
    }

    /// @dev Both ERC20Permit and Nonces define `nonces`.
    function nonces(address owner)
        public
        view
        override(ERC20Permit, Nonces)
        returns (uint256)
    {
        return super.nonces(owner);
    }

    /// @dev Pin the ERC20Votes safe-supply ceiling to the published max supply.
    ///      Nothing can mint, so this is a belt-and-braces invariant rather
    ///      than a live constraint.
    function _maxSupply() internal pure override returns (uint256) {
        return MAX_SUPPLY;
    }
}

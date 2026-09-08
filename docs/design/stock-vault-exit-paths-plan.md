# Stock Vault Exit Paths Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `SpotVaultMinimal` deliver what its ERC-4626 interface advertises, so the stock vault can be opened to depositors.

**Architecture:** One contract changes. The withdrawal swap is made to fully cover its shortfall or revert; `maxRedeem`, `maxWithdraw`, `maxDeposit` and `maxMint` are bounded by what the vault can actually deliver and return zero rather than reverting when the oracle refuses; the in-kind exit stops being gated by the circuit breaker. The contract is immutable on mainnet, so this ships as a fresh deployment plus a migration of the one live vault, whose only shareholder is the governance Safe.

**Tech Stack:** Solidity 0.8.28, Foundry (forge), OpenZeppelin ERC4626/AccessControl, Uniswap V3 via `RobinhoodChainRouterAdapter`, Safe Transaction Builder JSON, Supabase (Postgres), Next.js for the site constants.

**Spec:** `docs/design/stock-vault-exit-paths.md`

## Global Constraints

- Solidity `^0.8.28`. Contracts live in `sidequest-protocol/contracts`.
- Every file starts with `// SPDX-License-Identifier: MIT`.
- **Line endings: LF, matching the file you are editing.** `.gitattributes`
  enforces LF for `*.sh` only and exempts `contracts/lib`, so `*.sol` has no rule,
  but measured at byte level the Solidity sources are LF:
  `SpotVaultMinimal.sol` 656 LF and 0 CRLF, `TickMath.sol` 84 LF and 0 CRLF.
  `test/mocks/MockOracle.sol` is a pre-existing CRLF outlier (32 of 32) and must be
  left that way rather than normalised in passing.
  Measure with bytes, not `grep`: `grep -c $'$'` returns the LINE count here, not
  the CRLF count, and an earlier revision of this plan asserted "all 68 Solidity
  files are CRLF" on the strength of it. That was false. Use
  `python -c "d=open(f,'rb').read(); print(d.count(b'
'), d.count(b'
'))"`.
- 403 existing tests must stay green, apart from the four rewrites in Task 5.
- Fork tests live in `test/fork/`, read `RH_MAINNET_RPC_URL` via `vm.envOr`, and `vm.skip(true)` when it is unset. CI sets no fork RPC, so they must skip cleanly.
- **The launch gates workflow fails the build on any em-dash (U+2014) outside single quotes**, repo-wide except `sidequest-protocol/contracts/lib`. Use a comma, semicolon, colon or parentheses. Check with `git grep -nP "(?<!')\x{2014}(?!')" -- . ':!sidequest-protocol/contracts/lib'` before committing.
- **No hot-key signing, ever.** Every on-chain action is a Safe batch JSON under `sidequest-protocol/contracts/safe-batches/` that a human signs. Every batch gets a fork test that replays the artifact read off disk before it is signed.
- **No AI attribution anywhere.** No `Co-Authored-By`, no "Generated with", no mention of Claude, Anthropic or AI in any commit message, PR body, code comment or document.

### Mainnet addresses (chain 4663)

| What | Address |
|---|---|
| NVDA (18dp) | `0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC` |
| USDG (6dp) | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` |
| TWAP adapter (oracle) | `0xaBefb351777d8E68FCafa4D2F8A5848F326298cA` |
| Swap adapter | `0x8E50FC336f87b454cc44a89dA3a7267412B045dc` |
| OLD vault (zqNVDA) | `0xB129495f0ad616EdD2f28b3B49470FC1f0FAD413` |
| Governance Safe (2-of-2) | `0xC75E64Ccf3ce6E2F40939Ab58255681769BcF8C4` |
| Timelock (48h) | `0x813D69B8e1DBE2E08bcB892BE203A6BCE99b36Fc` |
| Protocol treasury | `0x3D9FE37DC0D08BeD0CD48c74Cb344064df9fB3C6` |
| `VAULT_ROLE` on the swap adapter | `0x31e0210044b4f6757ce6aa31f9c6e8d4896d24a755014887391a926c5224d959` |

### Two dead ends. Do not re-attempt either.

Both were prototyped and measured before the spec was written.

1. **Removing the swap from `_withdraw` entirely.** Looks clean. Leaves a fully flat vault (100% cash) at **zero** standard withdrawal capacity, which is half a long/flat vault's strategy space.
2. **Bounding `maxRedeem` by conversion alone**, i.e. `return _convertToShares(deliverable, Floor);` with no exact-case short-circuit. OpenZeppelin's virtual-share offset (`_decimalsOffset() == 6` here) makes it come out **501 wei** below the supply, so a vault holding no cash at all is refused a full exit. That is the original defect in a new form.

---

## File Structure

**Modified**

- `sidequest-protocol/contracts/src/vaults/SpotVaultMinimal.sol`: the only contract that changes. Tasks 1 to 4.
- `sidequest-protocol/contracts/test/vaults/WithdrawShortfall.t.sol`: bug-reproduction tests become fixed-behaviour tests. Task 5.
- `sidequest-protocol/contracts/test/vaults/SpotVaultMinimal.t.sol`: one test's expected revert changes. Task 5.
- `sidequest-protocol/contracts/test/mocks/MockOracle.sol`: gains a revert mode. Task 6.
- `zorpha-web/lib/deployment.ts`, `zorpha-web/lib/contracts.ts`: repointed. Task 11.

**Created**

- `sidequest-protocol/contracts/test/vaults/ExitCapacity.t.sol`: the capacity table as assertions. Task 2.
- `sidequest-protocol/contracts/test/invariants/ExitInvariants.t.sol`: the executability invariant. Task 7.
- `sidequest-protocol/contracts/script/DeployStockVaultV2.s.sol`: deploys the fixed vault. Task 8.
- `sidequest-protocol/contracts/safe-batches/M-grant-vault-role-timelock.json`: the timelocked `VAULT_ROLE` grant. Task 9.
- `sidequest-protocol/contracts/safe-batches/N-migrate-stock-vault.json`: the migration batch. Task 10.
- `sidequest-protocol/contracts/test/fork/GrantVaultRoleBatch.t.sol`: replays batch M. Task 9.
- `sidequest-protocol/contracts/test/fork/MigrateStockVaultBatch.t.sol`: replays batch N. Task 10.
- `sidequest-protocol/contracts/test/fork/StockVaultV2Live.t.sol`: capacity against the live position. Task 8.
- `zorpha-web/migrations/015-stock-vault-v2.sql`: registers the new vault. Task 11.

**Untouched, deliberately.** `FirstLossEscrow.sol`, `YieldVault.sol`, `RWRotationVault.sol`, `VaultLauncher.sol`. The first-loss coverage decay is real and belongs to slice 3; see the spec's "What this deliberately does not do".

---

## Task 1: The withdrawal swap must fully cover, or revert

**Files:**
- Modify: `sidequest-protocol/contracts/src/vaults/SpotVaultMinimal.sol:343-357`
- Test: `sidequest-protocol/contracts/test/vaults/WithdrawShortfall.t.sol`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `_withdraw` that either delivers `assets` in full or reverts. Task 2's bounds rely on the swap not silently under-delivering.

**Background.** The deployed code rounds the cash input DOWN, then allows the fill to come back up to `maxSlippageBps` short, then transfers the full amount and reverts on the transfer. Measured on mainnet at a 50/50 position: `redeem 40%` succeeded, `redeem 50%` reverted `ERC20InsufficientBalance(vault, 27710798703467998, 27710807884585675)`, short by 9,181,117,677 wei.

- [ ] **Step 1: Write the failing test**

Add to `test/vaults/WithdrawShortfall.t.sol`. The existing fixture in that file already pairs an 18dp asset with 6dp cash through `SlippingSpotAdapter` at 5bps, which is what makes this reproduce; do not change it.

```solidity
    /// A withdrawal that needs the cash leg converted must be delivered in
    /// full. The venue's cut comes out of the cash leg, not out of the
    /// depositor's payment.
    ///
    /// WHY 70% AND NOT HALF. An exact-half redeem does NOT enter the shortfall
    /// branch, so a test built on it passes with or without this fix and proves
    /// nothing. After rebalanceTo(5000) the asset leg is 50e18 while
    /// totalAssets is 99.975e18, because the rebalance paid the venue fee out
    /// of the position: half of NAV is therefore LESS than half of the original
    /// position, and the asset leg covers it outright. Measured against this
    /// fixture, pre-fix against post-fix:
    ///
    ///     45%, 50%      pass / pass    no conversion needed
    ///     55% .. 80%    FAIL / pass    conversion needed
    ///
    /// 70% sits well inside the band at both ends.
    function test_SeventyPercentExit_ConvertsAndDeliversInFull() public {
        uint256 shares = vault.balanceOf(alice);
        uint256 want = (shares * 70) / 100;
        uint256 owed = vault.previewRedeem(want);

        // Confirm the test is not vacuous: this exit MUST need a conversion.
        assertGt(owed, stock.balanceOf(address(vault)), "test must exercise the shortfall branch");

        uint256 before = stock.balanceOf(alice);
        vm.prank(alice);
        uint256 got = vault.redeem(want, alice, alice);

        assertEq(got, owed, "redeem must return what previewRedeem promised");
        assertEq(stock.balanceOf(alice) - before, owed, "and actually transfer it");
    }
```

- [ ] **Step 2: Run it and confirm it fails**

```bash
cd sidequest-protocol/contracts
forge test --match-test test_SeventyPercentExit_ConvertsAndDeliversInFull -vv
```

Expected: FAIL with `ERC20InsufficientBalance`, the vault short by a few units of cash granularity. If it PASSES, the fixture is not reaching the shortfall branch and the test is worthless: check the `assertGt` above, which exists to catch exactly that.

- [ ] **Step 3: Replace the shortfall block**

In `src/vaults/SpotVaultMinimal.sol`, replace the body of `_withdraw`. The existing body is:

```solidity
        uint256 bal = IERC20(asset()).balanceOf(address(this));
        if (bal < assets) {
            uint256 shortfall = assets - bal;
            uint256 cashIn = assetToCash(shortfall);
            uint256 cashBal = cashAsset.balanceOf(address(this));
            if (cashIn > cashBal) cashIn = cashBal;
            uint256 minOut = (shortfall * (10000 - maxSlippageBps)) / 10000;
            _swap(address(cashAsset), asset(), cashIn, minOut);
        }
        super._withdraw(caller, receiver, owner, assets, shares);
```

Replace with:

```solidity
        // The conversion must FULLY cover the shortfall or revert. The old
        // version rounded the cash input down and accepted a fill up to
        // maxSlippageBps short, then transferred the full amount anyway, so the
        // tolerance that kept the swap from reverting was exactly what made the
        // transfer revert. Measured on mainnet: a 50% exit from a 50/50
        // position came up 9,181,117,677 wei short on a 0.0277 NVDA leg.
        //
        // Three changes. Round the cash input UP, so the dust case cannot ask
        // the venue for zero. Gross it up by the slippage allowance, so the
        // venue's cut is paid out of the cash leg rather than out of the
        // depositor's delivery. And set minOut to the whole shortfall, so a
        // fill that cannot cover fails inside _swap instead of at the transfer
        // with ERC20InsufficientBalance.
        //
        // minOut is the guarantee, not the gross-up. _swap ends in
        // require(received >= minOut, "slippage"), so under-delivery is
        // impossible whatever the arithmetic above does; the gross-up only
        // makes the fill LIKELY to clear that bound. Note the revert is a plain
        // Error(string) and not a custom error, which is what an integrator
        // will actually see.
        uint256 bal = IERC20(asset()).balanceOf(address(this));
        if (bal < assets) {
            uint256 shortfall = assets - bal;
            uint256 cashIn = assetToCash(shortfall);
            if (cashToAsset(cashIn) < shortfall) cashIn += 1;
            cashIn = (cashIn * (10000 + maxSlippageBps)) / 10000 + 1;
            uint256 cashBal = cashAsset.balanceOf(address(this));
            if (cashIn > cashBal) cashIn = cashBal;
            _swap(address(cashAsset), asset(), cashIn, shortfall);
        }
        super._withdraw(caller, receiver, owner, assets, shares);
```

- [ ] **Step 4: Run it and confirm it passes**

```bash
forge test --match-test test_SeventyPercentExit_ConvertsAndDeliversInFull -vv
```

Expected: PASS.

- [ ] **Step 5: Confirm what this alone does NOT fix**

```bash
forge test --match-path 'test/vaults/WithdrawShortfall.t.sol' -vv
```

Expected: exactly three failures, all in this file: `test_ExitableFractionIsExactlyTheAssetLeg` with "some exit size must fail" (the cliff moved past every tested size), `test_FullRedeem_RevertsWhenCashMustBeConverted` and `test_FullyLongVault_OneUnitOfDust_CannotFullyExit` with a changed revert selector. `test_FullyLongVault_OneUnitOfDust_StrandsOnlyDust` keeps passing. Any OTHER failure is a real defect. That is correct at this point: Task 5 rewrites them. Do not touch them yet.

- [ ] **Step 6: Commit**

```bash
git add src/vaults/SpotVaultMinimal.sol test/vaults/WithdrawShortfall.t.sol
git commit -m "fix(vault): the withdrawal swap must cover the shortfall or revert"
```

---

## Task 2: Bound the withdrawal maximums by what is deliverable

**Files:**
- Modify: `sidequest-protocol/contracts/src/vaults/SpotVaultMinimal.sol` (add helpers and two overrides immediately above `maxDeposit`, currently line 239)
- Test: `sidequest-protocol/contracts/test/vaults/ExitCapacity.t.sol` (create)

**Interfaces:**
- Consumes: Task 1's covering `_withdraw`.
- Produces:
  - `_cashLegValue() internal view returns (uint256 value, bool priced)`
  - `_deliverableAssets() internal view returns (uint256 amount, bool priced)`
  - `maxRedeem(address owner) public view override returns (uint256)`
  - `maxWithdraw(address owner) public view override returns (uint256)`

  Tasks 3 and 7 both call `_deliverableAssets`.

**Background.** `maxRedeem` is not overridden today, so it inherits OpenZeppelin's `balanceOf(owner)` and reports shares as redeemable while `redeem` reverts. `maxWithdraw` calls `totalAssets()` and reverts outright when the oracle refuses.

- [ ] **Step 1: Write the failing test**

Create `test/vaults/ExitCapacity.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {SpotVaultMinimal} from "../../src/vaults/SpotVaultMinimal.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockOracle} from "../mocks/MockOracle.sol";
import {SlippingSpotAdapter} from "../mocks/SlippingSpotAdapter.sol";

/// @notice Whatever the vault advertises as withdrawable must actually execute.
///
/// The pairing is 18dp asset against 6dp cash, through a venue that charges
/// 5bps, because that is the live NVDA/USDG configuration and the decimal gap
/// is what makes the rounding matter. The suite's other spot vault fixture
/// pairs 8dp with 6dp through a perfect-fill venue, where neither the venue
/// cost nor the rounding can appear.
contract ExitCapacityTest is Test {
    MockERC20 stock;
    MockERC20 cash;
    MockOracle oracle;
    SlippingSpotAdapter venue;
    SpotVaultMinimal vault;

    address alice = makeAddr("alice");
    address keeper = makeAddr("keeper");

    uint256 constant DEPOSIT = 100e18;

    function setUp() public {
        vm.warp(1_700_000_000);
        stock = new MockERC20("Tokenised NVDA", "NVDA", 18);
        cash = new MockERC20("Global Dollar", "USDG", 6);
        oracle = new MockOracle(232 * 1e8, 8);
        venue = new SlippingSpotAdapter(address(stock), address(cash), address(oracle));
        venue.setFee(5);

        vault = new SpotVaultMinimal(
            address(stock), address(cash), address(oracle), 1 hours,
            "Zorpha NVDA Long/Flat", "zqNVDA",
            0, 100, 0,
            address(this), address(this),
            0
        );
        vault.setSwapAdapter(address(venue));
        vault.grantRole(vault.KEEPER_ROLE(), keeper);

        stock.mint(address(venue), 1_000_000e18);
        cash.mint(address(venue), 1_000_000_000e6);
        stock.mint(alice, DEPOSIT);

        vm.startPrank(alice);
        stock.approve(address(vault), DEPOSIT);
        vault.deposit(DEPOSIT, alice);
        vm.stopPrank();
    }

    /// The headline property: the advertised maximum executes, at every
    /// position a long/flat manager can choose.
    function test_AdvertisedMaximumExecutesAtEveryPosition() public {
        uint16[5] memory targets = [uint16(10000), 7500, 5000, 2500, 0];
        for (uint256 i = 0; i < targets.length; i++) {
            uint256 snap = vm.snapshotState();
            vm.prank(keeper);
            vault.rebalanceTo(targets[i]);

            uint256 held = vault.balanceOf(alice);
            uint256 mr = vault.maxRedeem(alice);
            assertLe(mr, held, "cannot advertise more shares than are held");
            assertGt(mr, 0, "a solvent vault must advertise some capacity");

            vm.prank(alice);
            vault.redeem(mr, alice, alice);

            console2.log("target", targets[i]);
            console2.log("   capacity bps", (mr * 10000) / held);
            vm.revertToState(snap);
        }
    }

    /// A vault holding no cash at all must be fully redeemable. This is the
    /// virtual-share offset trap: deriving the bound by conversion alone comes
    /// out 501 wei short of the supply and refuses this exit.
    function test_ZeroCashLeg_IsFullyRedeemable() public {
        vm.prank(keeper);
        vault.rebalanceTo(10000);
        assertEq(cash.balanceOf(address(vault)), 0, "fixture must reach a zero cash leg");

        uint256 held = vault.balanceOf(alice);
        assertEq(vault.maxRedeem(alice), held, "a zero-cash vault must be fully redeemable");
        vm.prank(alice);
        vault.redeem(held, alice, alice);
        assertEq(vault.balanceOf(alice), 0, "and the exit must complete");
    }

    /// maxWithdraw must agree with maxRedeem about reality.
    function test_MaxWithdrawExecutes() public {
        vm.prank(keeper);
        vault.rebalanceTo(5000);
        uint256 mw = vault.maxWithdraw(alice);
        assertGt(mw, 0, "a solvent vault must advertise some capacity");
        vm.prank(alice);
        vault.withdraw(mw, alice, alice);
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

```bash
forge test --match-path 'test/vaults/ExitCapacity.t.sol' -vv
```

Expected: `test_AdvertisedMaximumExecutesAtEveryPosition` FAILS, because `maxRedeem` returns the full holding and the resulting `redeem` cannot be covered at partial positions.

- [ ] **Step 3: Add the import**

At `src/vaults/SpotVaultMinimal.sol:10`, after the `ReentrancyGuard` import, add:

```solidity
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
```

- [ ] **Step 4: Add the helpers and overrides**

Insert immediately above the `/// @notice Refuse deposits when halted or when share price is undefined.` comment that precedes `maxDeposit`:

```solidity
    /// @dev Value the cash leg, or report that the oracle is refusing to price
    ///      it. The zero short-circuit matters: a vault holding no cash needs
    ///      no oracle to answer and must not be gated on one.
    function _cashLegValue() internal view returns (uint256 value, bool priced) {
        uint256 cashBal = cashAsset.balanceOf(address(this));
        if (cashBal == 0) return (0, true);
        try this.cashToAsset(cashBal) returns (uint256 v) {
            return (v, true);
        } catch {
            return (0, false);
        }
    }

    /// @dev What an exit could actually realise: the asset leg outright, plus
    ///      the cash leg net of the venue's cut for converting it.
    ///
    ///      `totalAssets()` values the cash leg at the oracle price, and
    ///      realising that value means crossing a venue that charges. The gap
    ///      between those two numbers is the whole defect this fixes, so the
    ///      bounds are computed from the realisable figure and never from
    ///      `totalAssets()`.
    function _deliverableAssets() internal view returns (uint256 amount, bool priced) {
        (uint256 cashValue, bool ok) = _cashLegValue();
        if (!ok) return (0, false);
        uint256 realisable = (cashValue * (10000 - maxSlippageBps)) / 10000;
        return (IERC20(asset()).balanceOf(address(this)) + realisable, true);
    }

    /// @notice Shares this owner can redeem through the standard path right now.
    ///
    ///         Previously inherited, which returned `balanceOf(owner)` and
    ///         reported shares as redeemable while `redeem` reverted.
    function maxRedeem(address owner) public view override returns (uint256) {
        if (isCircuitBreakerActive) return 0;
        (uint256 deliverable, bool priced) = _deliverableAssets();
        if (!priced) return 0;
        uint256 held = balanceOf(owner);
        // Exact case first, and this is not an optimisation. Deriving the bound
        // by conversion alone loses wei to the virtual-share offset: measured
        // 501 wei below the supply, which refused a full exit on a vault
        // holding no cash at all.
        if (previewRedeem(held) <= deliverable) return held;
        return _convertToShares(deliverable, Math.Rounding.Floor);
    }

    /// @notice Assets this owner can withdraw through the standard path.
    function maxWithdraw(address owner) public view override returns (uint256) {
        if (isCircuitBreakerActive) return 0;
        (uint256 deliverable, bool priced) = _deliverableAssets();
        if (!priced) return 0;
        uint256 byShares = _convertToAssets(balanceOf(owner), Math.Rounding.Floor);
        return byShares < deliverable ? byShares : deliverable;
    }

```

- [ ] **Step 5: Run it and confirm it passes**

```bash
forge test --match-path 'test/vaults/ExitCapacity.t.sol' -vv
```

Expected: PASS, with the logged capacities being 10000, 9975, 9950, 9925 and 9899 bps for targets 10000, 7500, 5000, 2500 and 0. If a fully flat vault logs 0, the exact-case short-circuit or Task 1 is missing.

- [ ] **Step 6: Commit**

```bash
git add src/vaults/SpotVaultMinimal.sol test/vaults/ExitCapacity.t.sol
git commit -m "fix(vault): bound the withdrawal maximums by what the vault can deliver"
```

---

## Task 3: `maxDeposit` and `maxMint` must return zero, not revert

**Files:**
- Modify: `sidequest-protocol/contracts/src/vaults/SpotVaultMinimal.sol:239-250`
- Modify: `sidequest-protocol/contracts/test/mocks/MockOracle.sol`
- Test: `sidequest-protocol/contracts/test/vaults/ExitCapacity.t.sol`

**Interfaces:**
- Consumes: `_cashLegValue()` from Task 2.
- Produces: `maxDeposit` and `maxMint` that never revert, and
  `MockOracle.setRevertOnRead(bool)` plus the public getter `revertOnRead()`.
  Task 6's tests and Task 7's handler both use them.

**Background.** Both reach `totalAssets()`, which reverts when the oracle refuses. Measured against the deployed contract: `maxDeposit` callable on an empty vault (it short-circuits on `totalSupply() == 0`), not callable once supply is non-zero; `maxMint` not callable. A caller cannot currently even ask whether the vault is open.

- [ ] **Step 1: Write the failing test**

Append to `test/vaults/ExitCapacity.t.sol`:

```solidity
    /// An integrator must be able to ask whether the vault is open, even when
    /// the oracle is refusing. Both of these reach totalAssets() today and
    /// revert rather than answering.
    function test_DepositMaximumsAnswerWhenTheOracleRefuses() public {
        vm.prank(keeper);
        vault.rebalanceTo(5000);
        oracle.setRevertOnRead(true);

        assertEq(vault.maxDeposit(alice), 0, "closed, not unanswerable");
        assertEq(vault.maxMint(alice), 0, "closed, not unanswerable");
        assertEq(vault.maxRedeem(alice), 0, "and the same for the exit side");
        assertEq(vault.maxWithdraw(alice), 0, "and the same for the exit side");
    }
```

- [ ] **Step 2: Teach `MockOracle` to refuse**

The test above needs an oracle that reverts, and the mock cannot currently do
it. In `test/mocks/MockOracle.sol`, add:

```solidity
    /// @notice Make reads revert, which is what the real TWAP adapter does when
    ///         any of its five guards fires. Returning a stale or non-positive
    ///         answer, which is all this mock could previously do, exercises a
    ///         different branch: the vault's own staleness checks rather than a
    ///         caller's ability to cope with an oracle that will not answer.
    bool public revertOnRead;

    function setRevertOnRead(bool v) external { revertOnRead = v; }
```

and as the first line of `latestRoundData()`:

```solidity
        if (revertOnRead) revert("MockOracle: refusing");
```

If `latestRoundData` is declared `pure`, change it to `view`.

`MockOracle` is used across the suite, so run the whole thing after this to
confirm a defaulted-false flag disturbs nothing:

```bash
forge test
```

- [ ] **Step 3: Run the new test and confirm it fails**

```bash
forge test --match-test test_DepositMaximumsAnswerWhenTheOracleRefuses -vv
```

Expected: FAIL, reverting inside `maxDeposit`.

- [ ] **Step 4: Guard both functions**

Replace the two existing functions at `src/vaults/SpotVaultMinimal.sol:239-250`. The existing code is:

```solidity
    /// @notice Refuse deposits when halted or when share price is undefined.
    function maxDeposit(address) public view override returns (uint256) {
        if (isCircuitBreakerActive) return 0;
        if (totalSupply() > 0 && totalAssets() == 0) return 0;
        return type(uint256).max;
    }

    function maxMint(address) public view override returns (uint256) {
        if (isCircuitBreakerActive) return 0;
        if (totalSupply() > 0 && totalAssets() == 0) return 0;
        return type(uint256).max;
    }
```

Replace with:

```solidity
    /// @notice Refuse deposits when halted, when the share price is undefined,
    ///         or when the cash leg cannot be priced.
    ///
    ///         The last case used to REVERT rather than answer, because
    ///         `totalAssets()` reads the oracle and the oracle is built to
    ///         refuse. A caller could not find out whether the vault was open.
    ///         Returning zero says "closed right now", which is the truth and
    ///         is a thing an integrator can act on.
    function maxDeposit(address) public view override returns (uint256) {
        if (isCircuitBreakerActive) return 0;
        (, bool priced) = _cashLegValue();
        if (!priced) return 0;
        if (totalSupply() > 0 && totalAssets() == 0) return 0;
        return type(uint256).max;
    }

    function maxMint(address) public view override returns (uint256) {
        if (isCircuitBreakerActive) return 0;
        (, bool priced) = _cashLegValue();
        if (!priced) return 0;
        if (totalSupply() > 0 && totalAssets() == 0) return 0;
        return type(uint256).max;
    }
```

- [ ] **Step 5: Run it and confirm it passes**

```bash
forge test --match-path 'test/vaults/ExitCapacity.t.sol' -vv
```

Expected: PASS, all four assertions.

- [ ] **Step 6: Commit**

```bash
git add src/vaults/SpotVaultMinimal.sol test/mocks/MockOracle.sol test/vaults/ExitCapacity.t.sol
git commit -m "fix(vault): the deposit maximums answer instead of reverting"
```

---

## Task 4: The in-kind exit stops being gated by the circuit breaker

**Files:**
- Modify: `sidequest-protocol/contracts/src/vaults/SpotVaultMinimal.sol:512`
- Test: `sidequest-protocol/contracts/test/vaults/ExitCapacity.t.sol`

**Interfaces:**
- Consumes: nothing.
- Produces: `redeemEmergency` reachable while the breaker is active.

**Background.** `redeemEmergency` is the only path that needs neither oracle nor venue, and it pays both legs exactly pro-rata. It is currently blocked by `isCircuitBreakerActive`, which is backwards: a breaker should suspend the paths that can misprice and preserve the one that cannot.

The per-owner cooldown stays. Note it is constructed as `0` on the live deployment (`EMERGENCY_REDEEM_COOLDOWN = 0` in `script/DeployStockVault.s.sol`), so today it imposes no delay; the mechanism is kept because a future deployment may want one.

- [ ] **Step 1: Write the failing test**

Append to `test/vaults/ExitCapacity.t.sol`. `setUp` already grants this contract `DEFAULT_ADMIN_ROLE`; grant the risk council role to itself so the breaker can be set.

```solidity
    /// A breaker must not remove the one exit that cannot misprice. It exists
    /// to suspend the paths that can.
    function test_BreakerSuspendsTheStandardPathButNotTheInKindOne() public {
        vault.grantRole(vault.RISK_COUNCIL_ROLE(), address(this));
        vm.prank(keeper);
        vault.rebalanceTo(5000);
        vault.setCircuitBreaker(true);

        assertEq(vault.maxRedeem(alice), 0, "standard path must be shut");
        assertEq(vault.maxDeposit(alice), 0, "deposits must be shut");

        uint256 held = vault.balanceOf(alice);
        uint256 stockBefore = stock.balanceOf(alice);
        uint256 cashBefore = cash.balanceOf(alice);

        vm.prank(alice);
        vault.redeemEmergency(held, alice, alice);

        assertEq(vault.balanceOf(alice), 0, "the in-kind exit must still work");
        assertGt(stock.balanceOf(alice) - stockBefore, 0, "paid the asset leg");
        assertGt(cash.balanceOf(alice) - cashBefore, 0, "and the cash leg, in kind");
    }
```

- [ ] **Step 2: Run it and confirm it fails**

```bash
forge test --match-test test_BreakerSuspendsTheStandardPathButNotTheInKindOne -vv
```

Expected: FAIL with `EmergencyBreakerActive()`.

- [ ] **Step 3: Remove the gate**

At `src/vaults/SpotVaultMinimal.sol:512`, delete this line:

```solidity
        if (isCircuitBreakerActive) revert EmergencyBreakerActive();
```

and put this in its place:

```solidity
        // Deliberately NOT gated on isCircuitBreakerActive. This is the only
        // path that reads no oracle and calls no venue, and it pays both legs
        // exactly pro-rata, so it is the one thing a breaker should preserve
        // rather than remove. The per-owner cooldown below still applies.
```

Leave `error EmergencyBreakerActive();` declared at line 97: it is still thrown elsewhere. Confirm with `grep -n "EmergencyBreakerActive" src/vaults/SpotVaultMinimal.sol`; if that grep shows the declaration only, delete the declaration too, or the build will warn on an unused error.

- [ ] **Step 4: Run it and confirm it passes**

```bash
forge test --match-path 'test/vaults/ExitCapacity.t.sol' -vv
forge build
```

Expected: tests PASS, build clean with no unused-declaration warning.

- [ ] **Step 5: Commit**

```bash
git add src/vaults/SpotVaultMinimal.sol test/vaults/ExitCapacity.t.sol
git commit -m "fix(vault): a breaker must not remove the in-kind exit"
```

---

## Task 5: Rewrite the four bug-reproduction tests

**Files:**
- Modify: `sidequest-protocol/contracts/test/vaults/WithdrawShortfall.t.sol:97-130`, `:131-166`, `:198-227`
- Modify: `sidequest-protocol/contracts/test/vaults/SpotVaultMinimal.t.sol:312`

**Interfaces:**
- Consumes: Tasks 1 to 4.
- Produces: a green suite.

**Background.** These four assert that the defect exists. They fail now because it does not. The refusal has moved from `ERC20InsufficientBalance` (selector `0xe450d38c`) to the typed `ERC4626ExceededMaxRedeem` (selector `0xb94abeec`), which is the improvement, so the rewrites assert the new selector rather than deleting the coverage.

- [ ] **Step 1: Confirm exactly these four fail, and no others**

```bash
cd sidequest-protocol/contracts
forge test 2>&1 | grep -E "^\[FAIL"
```

Expected, exactly four:
- `test_ExitableFractionIsExactlyTheAssetLeg`: "some exit size must fail, or there is no bug to regress"
- `test_FullRedeem_RevertsWhenCashMustBeConverted`: wrong revert, `0xb94abeec` vs `0xe450d38c`
- `test_FullyLongVault_OneUnitOfDust_CannotFullyExit`: same
- `test_EmergencyRedeem_WorksWhenTheVenueIsDry`: same

**If any other test fails, stop and investigate.** No production test broke under the prototype; a fifth failure means this implementation diverged from the spec.

- [ ] **Step 2: Replace `test_ExitableFractionIsExactlyTheAssetLeg`**

It asserted a cliff at the asset leg. There is no cliff now. Replace the whole function with:

```solidity
    /// The cliff is gone. It used to sit exactly where the asset leg ran out,
    /// which on a 50/50 position meant half the vault was unreachable. Now
    /// every advertised size clears and the advertised size is nearly all of
    /// the holding.
    function test_NoCliff_AdvertisedCapacityIsNearlyTheWholeHolding() public {
        uint256 shares = vault.balanceOf(alice);
        uint256 mr = vault.maxRedeem(alice);

        // 99.5% at a 50/50 position: the missing half percent is the venue's
        // cut for converting the cash leg, which is real money.
        assertGe((mr * 10000) / shares, 9900, "capacity should be within 1% of the holding");

        for (uint256 pct = 10; pct <= 100; pct += 10) {
            uint256 want = (mr * pct) / 100;
            if (want == 0) continue;
            uint256 snap = vm.snapshotState();
            vm.prank(alice);
            vault.redeem(want, alice, alice);
            vm.revertToState(snap);
        }
    }
```

- [ ] **Step 3: Replace `test_FullRedeem_RevertsWhenCashMustBeConverted`**

Keep the coverage, change what it asserts: the refusal is now typed and bounded, not an ERC-20 surprise.

The error is declared on `ERC4626` itself, at `lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol:94`, **not** in `draft-IERC6093.sol`. Add this import at the top of the file:

```solidity
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
```

and reference the selector as `ERC4626.ERC4626ExceededMaxRedeem.selector`, which is verified to compile and to equal `0xb94abeec`. Prefer it over the literal: a named selector survives someone changing the error's arguments, and a magic `bytes4` does not.

```solidity
    /// A full exit still cannot happen through the standard path, because the
    /// last of the cash leg cannot be converted for free. What changed is that
    /// the vault now says so in advance and refuses in a typed, standard way,
    /// instead of advertising the shares and failing inside an ERC-20 transfer.
    function test_FullRedeem_IsRefusedInAdvanceAndTyped() public {
        uint256 shares = vault.balanceOf(alice);
        uint256 mr = vault.maxRedeem(alice);
        assertLt(mr, shares, "a vault holding cash cannot promise a full exit");

        vm.prank(alice);
        (bool ok, bytes memory err) = address(vault).call(
            abi.encodeCall(vault.redeem, (shares, alice, alice))
        );
        assertFalse(ok, "the over-large request must be refused");
        // ERC4626ExceededMaxRedeem(address,uint256,uint256)
        assertEq(
            bytes4(err),
            ERC4626.ERC4626ExceededMaxRedeem.selector,
            "refusal must be the typed ERC-4626 error"
        );

        // And the advertised amount goes through.
        vm.prank(alice);
        vault.redeem(mr, alice, alice);
    }
```

- [ ] **Step 4: Replace `test_FullyLongVault_OneUnitOfDust_CannotFullyExit`**

```solidity
    /// The dust case, which used to strand the whole exit. One unit of a
    /// 6-decimal cash asset is billions of wei of an 18-decimal one, and
    /// converting it back rounded to nothing, so `_withdraw` swapped zero and
    /// the transfer came up short. Now the bound accounts for it in advance and
    /// everything the vault advertises is delivered.
    function test_FullyLongVault_OneUnitOfDust_AdvertisesAndDelivers() public {
        vm.prank(keeper);
        vault.rebalanceTo(10000);
        cash.mint(address(vault), 1);

        uint256 mr = vault.maxRedeem(alice);
        assertGt(mr, 0, "one unit of dust must not close the vault");

        uint256 before = stock.balanceOf(alice);
        vm.prank(alice);
        uint256 got = vault.redeem(mr, alice, alice);
        assertEq(stock.balanceOf(alice) - before, got, "delivered in full");
    }
```

- [ ] **Step 5: Fix `test_EmergencyRedeem_WorksWhenTheVenueIsDry`**

At `test/vaults/SpotVaultMinimal.t.sol:312`. The test asserts the standard path fails when the venue is dry, then that the emergency path works. Only the expected error changes. Find the line expecting `IERC20Errors.ERC20InsufficientBalance` and replace the expectation with the typed ERC-4626 refusal:

```solidity
        // The standard path is now refused in advance rather than failing
        // inside a transfer: a dry venue reduces what the cash leg can
        // realise, so maxRedeem shrinks and an over-large request is bounced
        // by ERC-4626 itself.
        vm.prank(alice);
        (bool ok, bytes memory err) = address(vault).call(
            abi.encodeCall(vault.redeem, (shares, alice, alice))
        );
        assertFalse(ok, "the standard path must still refuse");
        assertEq(bytes4(err), ERC4626.ERC4626ExceededMaxRedeem.selector, "wrong refusal");
```

Leave the rest of that test, including its emergency-path assertions, unchanged.

- [ ] **Step 6: Run the whole suite**

```bash
forge test
```

Expected: 0 failed. The count will be a little above 403 because Tasks 2 to 4 added tests.

- [ ] **Step 7: Commit**

```bash
git add test/vaults/WithdrawShortfall.t.sol test/vaults/SpotVaultMinimal.t.sol
git commit -m "test(vault): the exit tests assert the fix instead of the defect"
```

---

## Task 6: A reverting oracle, and the harness gaps that hid all this

**Files:**
- Test: `sidequest-protocol/contracts/test/vaults/ExitCapacity.t.sol`

**Interfaces:**
- Consumes: `MockOracle.setRevertOnRead(bool)`, added in Task 3.
- Produces: nothing later tasks depend on.

**Background, and this is the important part of the task.** Three defects survived a suite of 403 tests. Each of the four reasons is a property of the harness:

1. `MockSpotAdapter` fills at the oracle price exactly, so no fill could ever come short. `SlippingSpotAdapter` exists precisely because the slippage bound had never been exercised; it hid this too. The new fixtures in Tasks 2 and 7 use `SlippingSpotAdapter` at the live pool's 5bps.
2. The spot vault suite pairs an 8-decimal asset with 6-decimal cash. One cash unit is 100 asset units there and `previewRedeem`'s truncation absorbs the rounding. The live pair is 18 against 6, where one USDG unit is 4.3e9 NVDA wei. The decimal gap is the mechanism, so the new fixtures pair 18 against 6.
3. **No test ever made the oracle revert.** Stale and non-positive answers were covered. Reverting is what the TWAP adapter's five guards actually do, and it is the case that locks every holder out of the standard path. Task 3 gave `MockOracle` the ability; this task spends it.
4. No test asserted that `maxDeposit` could be called at all. Task 3 fixes that.

- [ ] **Step 1: Write the tests**

Append to `test/vaults/ExitCapacity.t.sol`:

```solidity
    /// The lockout case. When the oracle refuses, the standard path must close
    /// itself rather than advertise shares it cannot pay, and the in-kind path
    /// must still work, because it reads no oracle.
    function test_RefusingOracle_ClosesTheStandardPathAndLeavesTheInKindOne() public {
        vm.prank(keeper);
        vault.rebalanceTo(5000);
        oracle.setRevertOnRead(true);

        assertEq(vault.maxRedeem(alice), 0, "must not advertise a path that reverts");
        assertEq(vault.maxWithdraw(alice), 0, "same");

        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        (bool ok,) = address(vault).call(abi.encodeCall(vault.redeem, (shares, alice, alice)));
        assertFalse(ok, "and the standard path must indeed be shut");

        // Read the balance BEFORE pranking: an argument that is itself a call
        // consumes the prank.
        uint256 held = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeemEmergency(held, alice, alice);
        assertEq(vault.balanceOf(alice), 0, "the in-kind exit must always work");
    }

    /// A vault holding NO cash needs no oracle to serve an exit, and must not
    /// be gated on one. This is why _cashLegValue short-circuits at zero.
    function test_RefusingOracle_ZeroCashVaultStillExits() public {
        vm.prank(keeper);
        vault.rebalanceTo(10000);
        assertEq(cash.balanceOf(address(vault)), 0, "fixture must reach a zero cash leg");
        oracle.setRevertOnRead(true);

        uint256 held = vault.balanceOf(alice);
        assertEq(vault.maxRedeem(alice), held, "no cash leg means no oracle dependency");
        vm.prank(alice);
        vault.redeem(held, alice, alice);
    }
```

- [ ] **Step 2: Run and confirm they pass**

```bash
forge test --match-path 'test/vaults/ExitCapacity.t.sol' -vv
```

Expected: PASS. Both depend only on Tasks 2 to 4, so no contract change is needed here: this task is coverage for behaviour those tasks already built.

`test_RefusingOracle_ZeroCashVaultStillExits` is the load-bearing one: if it fails, `_cashLegValue`'s zero short-circuit was dropped, and a fully long vault would be frozen by an oracle it does not need.

- [ ] **Step 3: Confirm the whole suite still passes**

```bash
forge test
```

Expected: 0 failed. `MockOracle` is used widely; adding a defaulted-false flag must not disturb anything.

- [ ] **Step 4: Commit**

```bash
git add test/vaults/ExitCapacity.t.sol
git commit -m "test(vault): cover an oracle that refuses, not just one that is stale"
```

---

## Task 7: The executability invariant

**Files:**
- Create: `sidequest-protocol/contracts/test/invariants/ExitInvariants.t.sol`

**Interfaces:**
- Consumes: `maxRedeem`, `maxWithdraw`, `redeemEmergency`, `MockOracle.setRevertOnRead`.
- Produces: nothing later tasks depend on.

**Background.** Nothing in the suite asserted that the advertised maximums execute, which is why a `maxRedeem` returning `balanceOf(owner)` unconditionally survived 403 tests. This is the property that would have caught all three defects at once:

```
for any position, and any holder:
    redeem(maxRedeem(owner))          must succeed
    withdraw(maxWithdraw(owner))      must succeed
    redeemEmergency(balanceOf(owner)) must succeed, whatever the oracle does
```

Follow the shape of `test/invariants/VaultInvariants.t.sol`: a `Handler` contract holding the fuzzable actions, `targetContract(address(handler))` in `setUp`, and `invariant_` functions asserting the property.

- [ ] **Step 1: Write the invariant test**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, StdInvariant, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SpotVaultMinimal} from "../../src/vaults/SpotVaultMinimal.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockOracle} from "../mocks/MockOracle.sol";
import {SlippingSpotAdapter} from "../mocks/SlippingSpotAdapter.sol";

/// @notice Drives the vault through positions, flows and oracle failures.
contract ExitHandler is Test {
    SpotVaultMinimal public vault;
    MockERC20 public stock;
    MockERC20 public cash;
    MockOracle public oracle;
    address public alice;
    address public keeper;

    uint256 public rebalances;
    uint256 public deposits;

    constructor(
        SpotVaultMinimal v, MockERC20 s, MockERC20 c, MockOracle o,
        address alice_, address keeper_
    ) {
        vault = v; stock = s; cash = c; oracle = o;
        alice = alice_; keeper = keeper_;
    }

    function rebalance(uint16 target) external {
        target = uint16(bound(target, 0, 10000));
        vm.prank(keeper);
        try vault.rebalanceTo(target) { rebalances++; } catch {}
    }

    function deposit(uint96 amount) external {
        uint256 amt = bound(amount, 1e15, 50e18);
        stock.mint(alice, amt);
        vm.startPrank(alice);
        stock.approve(address(vault), amt);
        try vault.deposit(amt, alice) { deposits++; } catch {}
        vm.stopPrank();
    }

    /// Withdraw a fraction of what the vault SAYS is available. Every one of
    /// these must succeed, which is the whole point.
    function withdrawSome(uint8 pct) external {
        uint256 mr = vault.maxRedeem(alice);
        if (mr == 0) return;
        uint256 want = (mr * bound(pct, 1, 100)) / 100;
        if (want == 0) return;
        vm.prank(alice);
        vault.redeem(want, alice, alice);
    }

    function breakOracle(bool broken) external {
        oracle.setRevertOnRead(broken);
    }

    function movePrice(uint96 p) external {
        if (oracle.revertOnRead()) return;
        oracle.setPrice(int256(uint256(bound(p, 50e8, 900e8))));
    }
}

/// @notice The advertised maximums must be executable, always.
///
/// Nothing asserted this before, which is how a maxRedeem that returned
/// balanceOf(owner) unconditionally survived a suite of 403 tests while the
/// standard withdrawal path was broken above 40% of a 50/50 position.
contract ExitInvariantsTest is StdInvariant, Test {
    SpotVaultMinimal vault;
    MockERC20 stock;
    MockERC20 cash;
    MockOracle oracle;
    SlippingSpotAdapter venue;
    ExitHandler handler;

    address alice = makeAddr("alice");
    address keeper = makeAddr("keeper");

    function setUp() public {
        vm.warp(1_700_000_000);
        stock = new MockERC20("Tokenised NVDA", "NVDA", 18);
        cash = new MockERC20("Global Dollar", "USDG", 6);
        oracle = new MockOracle(232 * 1e8, 8);
        venue = new SlippingSpotAdapter(address(stock), address(cash), address(oracle));
        venue.setFee(5);

        vault = new SpotVaultMinimal(
            address(stock), address(cash), address(oracle), 365 days,
            "Zorpha NVDA Long/Flat", "zqNVDA",
            0, 100, 0,
            address(this), address(this),
            0
        );
        vault.setSwapAdapter(address(venue));
        vault.grantRole(vault.KEEPER_ROLE(), keeper);

        stock.mint(address(venue), 100_000_000e18);
        cash.mint(address(venue), 100_000_000_000e6);
        stock.mint(alice, 100e18);
        vm.startPrank(alice);
        stock.approve(address(vault), 100e18);
        vault.deposit(100e18, alice);
        vm.stopPrank();

        handler = new ExitHandler(vault, stock, cash, oracle, alice, keeper);
        targetContract(address(handler));
    }

    /// Staleness is set to 365 days above on purpose: this suite is about
    /// whether the advertised bound is executable, and a staleness revert would
    /// close the path for an unrelated reason and make the invariant vacuous.

    /// The headline. Whatever the vault says is redeemable must redeem.
    function invariant_MaxRedeemIsExecutable() public {
        uint256 mr = vault.maxRedeem(alice);
        if (mr == 0) return;
        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        vault.redeem(mr, alice, alice);
        vm.revertToState(snap);
    }

    /// And the same on the asset-denominated side.
    function invariant_MaxWithdrawIsExecutable() public {
        uint256 mw = vault.maxWithdraw(alice);
        if (mw == 0) return;
        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        vault.withdraw(mw, alice, alice);
        vm.revertToState(snap);
    }

    /// The in-kind exit needs no oracle and no venue, so it must work in every
    /// state the handler can reach, including a refusing oracle.
    function invariant_InKindExitAlwaysWorks() public {
        uint256 held = vault.balanceOf(alice);
        if (held == 0) return;
        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        vault.redeemEmergency(held, alice, alice);
        vm.revertToState(snap);
    }

    /// The bound must never exceed the holding, or it is not a bound.
    function invariant_MaxRedeemNeverExceedsHolding() public view {
        assertLe(vault.maxRedeem(alice), vault.balanceOf(alice));
    }

    /// Coverage floor. An invariant suite where the handler never lands is
    /// green and worthless, which is a mistake this repo has made before.
    function afterInvariant() public view {
        assertGt(handler.rebalances(), 0, "no rebalance ever succeeded: suite is vacuous");
    }
}
```

- [ ] **Step 2: Run it**

```bash
forge test --match-path 'test/invariants/ExitInvariants.t.sol' -vv
```

Expected: PASS, and `afterInvariant` confirms rebalances landed. If `afterInvariant` fails, the handler's actions are all reverting and the suite proves nothing; check that `bound` is imported via `Test` and that the venue has been minted enough of both tokens.

- [ ] **Step 3: Prove the invariant bites**

Temporarily revert `maxRedeem` to the inherited behaviour by adding `return balanceOf(owner);` as its first line, then run again.

```bash
forge test --match-path 'test/invariants/ExitInvariants.t.sol'
```

Expected: `invariant_MaxRedeemIsExecutable` FAILS. **Then remove the temporary line.** An invariant that cannot fail is not a test, and this repo has shipped a vacuous one before.

- [ ] **Step 4: Full suite**

```bash
forge test
```

Expected: 0 failed.

- [ ] **Step 5: Commit**

```bash
git add test/invariants/ExitInvariants.t.sol
git commit -m "test(vault): assert the advertised maximums are executable"
```

---

## Task 8: Deploy script and the live-position fork test

**Files:**
- Create: `sidequest-protocol/contracts/script/DeployStockVaultV2.s.sol`
- Create: `sidequest-protocol/contracts/test/fork/StockVaultV2Live.t.sol`

**Interfaces:**
- Consumes: the fixed `SpotVaultMinimal`.
- Produces: a deployed vault address, needed by Tasks 9, 10 and 11.

**Background.** Reuse the existing TWAP oracle `0xaBefb351777d8E68FCafa4D2F8A5848F326298cA` and the existing swap adapter `0x8E50FC336f87b454cc44a89dA3a7267412B045dc`; only the vault is redeployed. Admin lands on the **Safe**, not the Timelock, so the role batch in Task 10 can complete atomically. Deploying straight to the Timelock would need three separate 48-hour proposals while the vault sits on chain unable to trade.

Slice-1 parameters, from `script/DeployStockVault.s.sol`: `MAX_ORACLE_STALENESS = 3600`, `REBALANCE_THRESHOLD_BPS = 100`, `MAX_SLIPPAGE_BPS = 100`, `PERFORMANCE_FEE_BPS = 1000`, `EMERGENCY_REDEEM_COOLDOWN = 0`, `feeRecipient = TREASURY`.

- [ ] **Step 1: Write the fork test first**

Create `test/fork/StockVaultV2Live.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SpotVaultMinimal} from "../../src/vaults/SpotVaultMinimal.sol";

/// @notice A freshly deployed vault, seeded with the live position, against the
///         real oracle and the real venue. This is the capacity table in the
///         spec, checked rather than asserted from a unit fixture.
contract StockVaultV2LiveTest is Test {
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant ORACLE = 0xaBefb351777d8E68FCafa4D2F8A5848F326298cA;
    address constant SWAP_ADAPTER = 0x8E50FC336f87b454cc44a89dA3a7267412B045dc;
    address constant OLD_VAULT = 0xB129495f0ad616EdD2f28b3B49470FC1f0FAD413;
    address constant SAFE = 0xC75E64Ccf3ce6E2F40939Ab58255681769BcF8C4;
    address constant TIMELOCK = 0x813D69B8e1DBE2E08bcB892BE203A6BCE99b36Fc;
    address constant TREASURY = 0x3D9FE37DC0D08BeD0CD48c74Cb344064df9fB3C6;

    bytes32 constant VAULT_ROLE =
        0x31e0210044b4f6757ce6aa31f9c6e8d4896d24a755014887391a926c5224d959;

    bool forked;

    function setUp() public {
        string memory url = vm.envOr("RH_MAINNET_RPC_URL", string(""));
        if (bytes(url).length == 0) return;
        vm.createSelectFork(url);
        forked = true;
    }

    function _deploy() internal returns (SpotVaultMinimal v) {
        v = new SpotVaultMinimal(
            NVDA, USDG, ORACLE, 3600,
            "Zorpha NVDA Long/Flat", "zqNVDA",
            100, 100, 1000,
            TREASURY, SAFE, 0
        );
        vm.startPrank(SAFE);
        v.setSwapAdapter(SWAP_ADAPTER);
        v.grantRole(v.KEEPER_ROLE(), SAFE);
        vm.stopPrank();

        // The swap adapter gates callers by VAULT_ROLE and its admin is the
        // Timelock, so a fresh vault cannot trade until a 48-hour proposal
        // grants it. That is Task 9, and a migration step, not a test artifact.
        vm.prank(TIMELOCK);
        (bool granted,) = SWAP_ADAPTER.call(
            abi.encodeWithSignature("grantRole(bytes32,address)", VAULT_ROLE, address(v))
        );
        require(granted, "VAULT_ROLE grant failed");
    }

    function test_CapacityAtEveryPosition() public {
        if (!forked) { vm.skip(true); }
        SpotVaultMinimal v = _deploy();

        uint256 seed = IERC20(NVDA).balanceOf(OLD_VAULT);
        require(seed > 0, "old vault holds nothing to size against");
        deal(NVDA, SAFE, seed);
        vm.startPrank(SAFE);
        IERC20(NVDA).approve(address(v), seed);
        v.deposit(seed, SAFE);
        vm.stopPrank();

        uint16[3] memory targets = [uint16(10000), 5000, 0];
        for (uint256 i = 0; i < targets.length; i++) {
            uint256 snap = vm.snapshotState();
            vm.prank(SAFE);
            v.rebalanceTo(targets[i]);

            uint256 held = v.balanceOf(SAFE);
            uint256 mr = v.maxRedeem(SAFE);
            assertGt(mr, 0, "a solvent vault must advertise capacity at every target");
            // The spec's table: 10000 gives 100%, 5000 gives 99.50%, 0 gives
            // 98.99%. Assert the floor rather than the exact figure, which
            // moves with the pool.
            assertGe((mr * 10000) / held, 9800, "capacity floor");

            vm.prank(SAFE);
            v.redeem(mr, SAFE, SAFE);

            console2.log("target", targets[i]);
            console2.log("   capacity bps", (mr * 10000) / held);
            vm.revertToState(snap);
        }
    }
}
```

- [ ] **Step 2: Run it**

```bash
RH_MAINNET_RPC_URL=https://rpc.mainnet.chain.robinhood.com \
  forge test --match-path 'test/fork/StockVaultV2Live.t.sol' -vv
```

Expected: PASS, logging roughly 10000, 9950 and 9899 bps.

- [ ] **Step 3: Confirm it skips without the RPC**

```bash
forge test --match-path 'test/fork/StockVaultV2Live.t.sol'
```

Expected: 1 skipped. CI sets no fork RPC, so a test that fails instead of skipping breaks the build.

- [ ] **Step 4: Write the deploy script**

Create `script/DeployStockVaultV2.s.sol`. Copy the header style of `script/DeployStockVault.s.sol`, including its explanation of why admin lands on the Safe, and print a read-back before broadcasting:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {SpotVaultMinimal} from "../src/vaults/SpotVaultMinimal.sol";

/// @notice Redeploys the NVDA long/flat vault with the exit paths fixed.
///
///         WHY A REDEPLOY. SpotVaultMinimal is immutable and has no proxy. The
///         defects are in its withdrawal accounting, so they cannot be patched
///         in place. See docs/design/stock-vault-exit-paths.md.
///
///         WHAT IS REUSED. The TWAP oracle and the swap adapter are unchanged
///         and stay at their existing addresses; both are already verified.
///         Only the vault is new.
///
///         WHY ADMIN LANDS ON THE SAFE. The end state is admin on the Timelock.
///         Deploying straight to it would mean the Timelock has to grant
///         KEEPER_ROLE, grant RISK_COUNCIL_ROLE and set the swap adapter, which
///         is three separate 48-hour proposals during which the vault exists on
///         chain and cannot trade. safe-batches/N-migrate-stock-vault.json does
///         all of it in one atomic transaction ending with the Safe renouncing
///         its own admin.
///
///         THE READ-BACK IS NOT DECORATION. Confirm maxRedeem on an empty vault
///         and assetToCash(1e18) before you trust the address.
///
///         RUN, dry (sends nothing):
///           forge script script/DeployStockVaultV2.s.sol:DeployStockVaultV2 \
///             --rpc-url https://rpc.mainnet.chain.robinhood.com
///
///         RUN, for real:
///           forge script script/DeployStockVaultV2.s.sol:DeployStockVaultV2 \
///             --rpc-url https://rpc.mainnet.chain.robinhood.com \
///             --account mainnet-deploy --broadcast --slow
///
///         Never pass --password. Let it prompt, so the passphrase stays out of
///         shell history.
contract DeployStockVaultV2 is Script {
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC; // 18dp
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168; // 6dp
    address constant ORACLE = 0xaBefb351777d8E68FCafa4D2F8A5848F326298cA;
    address constant SAFE = 0xC75E64Ccf3ce6E2F40939Ab58255681769BcF8C4;
    address constant TREASURY = 0x3D9FE37DC0D08BeD0CD48c74Cb344064df9fB3C6;

    // Slice-1 parameters, unchanged.
    uint256 constant MAX_ORACLE_STALENESS = 3600;
    uint16 constant REBALANCE_THRESHOLD_BPS = 100;
    uint16 constant MAX_SLIPPAGE_BPS = 100;
    uint256 constant PERFORMANCE_FEE_BPS = 1000;
    uint256 constant EMERGENCY_REDEEM_COOLDOWN = 0;

    function run() external {
        vm.startBroadcast();
        SpotVaultMinimal vault = new SpotVaultMinimal(
            NVDA, USDG, ORACLE, MAX_ORACLE_STALENESS,
            "Zorpha NVDA Long/Flat", "zqNVDA",
            REBALANCE_THRESHOLD_BPS, MAX_SLIPPAGE_BPS, PERFORMANCE_FEE_BPS,
            TREASURY, SAFE,
            EMERGENCY_REDEEM_COOLDOWN
        );
        vm.stopBroadcast();

        console2.log("vault              ", address(vault));
        console2.log("asset              ", vault.asset());
        console2.log("oracle             ", address(vault.oracle()));
        console2.log("maxSlippageBps     ", vault.maxSlippageBps());
        console2.log("assetToCash(1e18)  ", vault.assetToCash(1e18));
        console2.log("maxRedeem(SAFE)    ", vault.maxRedeem(SAFE));
        console2.log("");
        console2.log("NEXT: verify on Blockscout, then batch M, then wait 48h.");
    }
}
```

- [ ] **Step 5: Dry-run it**

```bash
forge script script/DeployStockVaultV2.s.sol:DeployStockVaultV2 \
  --rpc-url https://rpc.mainnet.chain.robinhood.com
```

Expected: simulates, prints the read-back. `assetToCash(1e18)` should look like an NVDA price in USDG units (about `232000000`), and `maxRedeem(SAFE)` should be 0 on an empty vault without reverting.

- [ ] **Step 6: Commit**

```bash
git add script/DeployStockVaultV2.s.sol test/fork/StockVaultV2Live.t.sol
git commit -m "feat(vault): deploy script for the fixed stock vault"
```

- [ ] **Step 7: Broadcast, then verify on Blockscout**

Run the script with `--account mainnet-deploy --broadcast --slow`. Record the address.

Then verify. Do **not** use `forge verify-contract`: its user agent gets Cloudflare-challenged on this Blockscout.

The recipe is documented in the header of `script/verify-mainnet.sh`, lines 20 to 45. Read it rather than improvising. In summary: POST the standard-json input to
`$EXPLORER/api/v2/smart-contracts/<addr>/verification/via/standard-input` with a full Chrome user agent plus `Accept` and `Referer` headers, `compiler_version=v0.8.28+commit.7893614a`, `license_type=mit`, and the constructor args as hex. Retry until HTTP 200.

GET on `/api/v2/smart-contracts` and POST to the verification endpoint have **separate** rate limits, so a 429 on one says nothing about the other.

Confirm the contract reads as verified on Blockscout before continuing. Nothing downstream is safe to sign against an unverified address.

---

## Task 9: Batch M, the timelocked `VAULT_ROLE` grant

**Files:**
- Create: `sidequest-protocol/contracts/safe-batches/M-grant-vault-role-timelock.json`
- Create: `sidequest-protocol/contracts/test/fork/GrantVaultRoleBatch.t.sol`

**Interfaces:**
- Consumes: the deployed address from Task 8.
- Produces: a new vault holding `VAULT_ROLE` on the swap adapter, 48 hours later.

**Background, and this is the long pole.** The swap adapter gates callers by `VAULT_ROLE`, and its `DEFAULT_ADMIN_ROLE` is the **Timelock**, not the Safe, whose minimum delay is 172,800 seconds. So the grant is a Timelock proposal the Safe schedules and later executes, and the new vault cannot trade for 48 hours.

The alternative, deploying a fresh swap adapter with the Safe as admin, skips the wait and adds an address nobody has verified or reviewed. Take the 48 hours.

Read `script/safe-batches.sh` and an existing timelocked batch, `safe-batches/3-treasury-execute.json`, for the `schedule` and `execute` calldata shape this Timelock expects.

- [ ] **Step 1: Build the batch JSON**

Two files, or one file with two transactions if this Timelock allows scheduling and executing from the same batch (it does not; the delay sits between them). Produce the **schedule** batch now. Its single transaction targets the Timelock with the encoded `grantRole(VAULT_ROLE, NEW_VAULT)` call on the swap adapter.

Generate the inner calldata with:

```bash
cast calldata "grantRole(bytes32,address)" \
  0x31e0210044b4f6757ce6aa31f9c6e8d4896d24a755014887391a926c5224d959 \
  <NEW_VAULT_ADDRESS>
```

On Windows, pipe through `tr -d '\r'`: Python's `print` appends a carriage return that turns the hex into an odd digit count, and `cast` will still display a correct-looking string.

The JSON follows the existing batches: `version` "1.0", `chainId` "4663", a `meta.name` and a `meta.description` explaining why the 48 hours exists, and `txBuilderVersion` "1.16.5".

- [ ] **Step 2: Write the fork test that replays it**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";

/// @notice Replays safe-batches/M-grant-vault-role-timelock.json as the Safe,
///         then warps past the delay and confirms the grant lands.
contract GrantVaultRoleBatchTest is Test {
    address constant SAFE = 0xC75E64Ccf3ce6E2F40939Ab58255681769BcF8C4;
    address constant TIMELOCK = 0x813D69B8e1DBE2E08bcB892BE203A6BCE99b36Fc;
    address constant SWAP_ADAPTER = 0x8E50FC336f87b454cc44a89dA3a7267412B045dc;
    bytes32 constant VAULT_ROLE =
        0x31e0210044b4f6757ce6aa31f9c6e8d4896d24a755014887391a926c5224d959;

    bool forked;

    function setUp() public {
        string memory url = vm.envOr("RH_MAINNET_RPC_URL", string(""));
        if (bytes(url).length == 0) return;
        vm.createSelectFork(url);
        forked = true;
    }

    function test_ReplayBatchM() public {
        if (!forked) { vm.skip(true); }

        // Read the batch off disk, so this tests the file that gets signed and
        // not a transcription of it.
        string memory json = vm.readFile("safe-batches/M-grant-vault-role-timelock.json");
        address to = vm.parseJsonAddress(json, ".transactions[0].to");
        bytes memory data = vm.parseJsonBytes(json, ".transactions[0].data");
        assertEq(to, TIMELOCK, "batch M must target the Timelock");

        vm.prank(SAFE);
        (bool scheduled,) = TIMELOCK.call(data);
        assertTrue(scheduled, "the Safe must be able to schedule this");

        // The delay is the point of the task. Confirm it is real.
        (, bytes memory d) = TIMELOCK.staticcall(abi.encodeWithSignature("getMinDelay()"));
        uint256 delay = abi.decode(d, (uint256));
        assertEq(delay, 172800, "48 hours; if this changed, revisit the plan");
        vm.warp(block.timestamp + delay + 1);

        console2.log("scheduled, delay", delay);
    }
}
```

Extend it with the `execute` call once the executing calldata is settled: assert `hasRole(VAULT_ROLE, newVault)` is false before and true after.

- [ ] **Step 3: Run both checks**

```bash
RH_MAINNET_RPC_URL=https://rpc.mainnet.chain.robinhood.com \
  forge test --match-path 'test/fork/GrantVaultRoleBatch.t.sol' -vv
forge test --match-path 'test/fork/GrantVaultRoleBatch.t.sol'
```

Expected: PASS with the RPC, 1 skipped without it.

- [ ] **Step 4: Commit, and open a PR before asking for a signature**

```bash
git add safe-batches/M-grant-vault-role-timelock.json test/fork/GrantVaultRoleBatch.t.sol
git commit -m "chore(safe-batches): schedule the VAULT_ROLE grant for the new vault"
```

Push and **open a pull request.** A batch that has been pushed without a PR has twice been reported as missing in this repo.

- [ ] **Step 5: Human signs, then wait**

Before proposing, check the Safe queue is empty via the Transaction Service; see `safe-batches/README.md`. After execution, wait out the 48 hours, then execute the second half and confirm on chain:

```bash
cast call 0x8E50FC336f87b454cc44a89dA3a7267412B045dc \
  "hasRole(bytes32,address)(bool)" \
  0x31e0210044b4f6757ce6aa31f9c6e8d4896d24a755014887391a926c5224d959 \
  <NEW_VAULT_ADDRESS> \
  --rpc-url https://rpc.mainnet.chain.robinhood.com
```

Expected: `true`. Do not proceed to Task 10 until it is.

---

## Task 10: Batch N, the migration

**Files:**
- Create: `sidequest-protocol/contracts/safe-batches/N-migrate-stock-vault.json`
- Create: `sidequest-protocol/contracts/test/fork/MigrateStockVaultBatch.t.sol`

**Interfaces:**
- Consumes: the deployed and role-granted vault from Tasks 8 and 9.
- Produces: the live position moved, and no EOA holding a role.

**Background.** The Safe holds 100% of the old vault's shares, and `redeemEmergency` provably empties it: measured on a fork, `cash left 0, asset left 0`, nothing stranded. So there is no third party to coordinate with and no dust to write off.

Order matters. `redeemEmergency` first, because everything after it depends on holding the tokens. The Safe renounces its own admin **last**, or the batch strands the vault half-configured.

- [ ] **Step 1: Build the batch, in this order**

1. `redeemEmergency(<all shares>, SAFE, SAFE)` on the OLD vault `0xB129495f0ad616EdD2f28b3B49470FC1f0FAD413`.
2. `approve(<NEW_VAULT>, <nvda amount>)` on NVDA.
3. `deposit(<nvda amount>, SAFE)` on the new vault.
4. `rebalanceTo(<target>)` on the new vault. Choose the target deliberately and say why in the description.
5. `grantRole(KEEPER_ROLE, SAFE)` on the new vault, if the deploy script did not already.
6. `grantRole(RISK_COUNCIL_ROLE, SAFE)` on the new vault.
7. `grantRole(DEFAULT_ADMIN_ROLE, TIMELOCK)` on the new vault.
8. `renounceRole(DEFAULT_ADMIN_ROLE, SAFE)` on the new vault. **Last.**

Amounts for steps 2 and 3 cannot be read from chain inside a Safe batch, so they are fixed numbers. Take them from the fork replay in Step 2 and re-check them immediately before signing; the position moves with the NVDA price.

The USDG leg recovered in step 1 stays in the Safe rather than being deposited: the new vault takes NVDA as its asset, and `rebalanceTo` will buy whatever cash leg the target calls for out of the deposited position.

- [ ] **Step 2: Write the fork test that replays the artifact**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SpotVaultMinimal} from "../../src/vaults/SpotVaultMinimal.sol";

/// @notice Replays every transaction in safe-batches/N-migrate-stock-vault.json
///         as the Safe, in order, and asserts the end state.
contract MigrateStockVaultBatchTest is Test {
    address constant SAFE = 0xC75E64Ccf3ce6E2F40939Ab58255681769BcF8C4;
    address constant TIMELOCK = 0x813D69B8e1DBE2E08bcB892BE203A6BCE99b36Fc;
    address constant OLD_VAULT = 0xB129495f0ad616EdD2f28b3B49470FC1f0FAD413;
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    bool forked;

    function setUp() public {
        string memory url = vm.envOr("RH_MAINNET_RPC_URL", string(""));
        if (bytes(url).length == 0) return;
        vm.createSelectFork(url);
        forked = true;
    }

    function test_ReplayBatchN() public {
        if (!forked) { vm.skip(true); }

        string memory json = vm.readFile("safe-batches/N-migrate-stock-vault.json");
        assertEq(vm.parseJsonString(json, ".chainId"), "4663", "wrong chain");

        // The bound is hardcoded, matching test/fork/AdapterAdminBatch.t.sol.
        // forge-std has no `.length` on a JSON array path, and a loop that
        // silently ran zero iterations would make this test green and useless.
        uint256 n = 8;
        for (uint256 i = 0; i < n; i++) {
            string memory base = string.concat(".transactions[", vm.toString(i), "]");
            address to = vm.parseJsonAddress(json, string.concat(base, ".to"));
            bytes memory data = vm.parseJsonBytes(json, string.concat(base, ".data"));
            vm.prank(SAFE);
            (bool ok,) = to.call(data);
            assertTrue(ok, string.concat("transaction ", vm.toString(i), " reverted"));
        }

        // The old vault is empty.
        assertEq(IERC20(NVDA).balanceOf(OLD_VAULT), 0, "old asset leg must be empty");
        assertEq(IERC20(USDG).balanceOf(OLD_VAULT), 0, "old cash leg must be empty");
        assertEq(SpotVaultMinimal(OLD_VAULT).totalSupply(), 0, "old shares must be burned");

        // And no EOA holds admin on the new one. Read the new vault's address
        // from the batch's deposit transaction target.
        address newVault = vm.parseJsonAddress(json, ".transactions[2].to");
        SpotVaultMinimal v = SpotVaultMinimal(newVault);
        assertTrue(v.hasRole(v.DEFAULT_ADMIN_ROLE(), TIMELOCK), "Timelock must hold admin");
        assertFalse(v.hasRole(v.DEFAULT_ADMIN_ROLE(), SAFE), "Safe must have renounced");
        assertGt(v.totalSupply(), 0, "the new vault must hold the position");
        assertGt(v.maxRedeem(SAFE), 0, "and it must be exitable");

        console2.log("new vault      ", newVault);
        console2.log("maxRedeem bps  ", (v.maxRedeem(SAFE) * 10000) / v.balanceOf(SAFE));
    }
}
```

- [ ] **Step 3: Run both checks**

```bash
RH_MAINNET_RPC_URL=https://rpc.mainnet.chain.robinhood.com \
  forge test --match-path 'test/fork/MigrateStockVaultBatch.t.sol' -vv
forge test --match-path 'test/fork/MigrateStockVaultBatch.t.sol'
```

Expected: PASS with the RPC, 1 skipped without.

- [ ] **Step 4: Commit and open a PR**

```bash
git add safe-batches/N-migrate-stock-vault.json test/fork/MigrateStockVaultBatch.t.sol
git commit -m "chore(safe-batches): migrate the stock vault position to the fixed contract"
```

Push and open a PR.

- [ ] **Step 5: Human signs; then verify on chain**

After execution, confirm each of these rather than assuming the batch held:

```bash
R=https://rpc.mainnet.chain.robinhood.com
cast call 0xB129495f0ad616EdD2f28b3B49470FC1f0FAD413 "totalSupply()(uint256)" --rpc-url $R   # 0
cast call <NEW_VAULT> "totalSupply()(uint256)" --rpc-url $R                                   # > 0
cast call <NEW_VAULT> "rebalanceCount()(uint256)" --rpc-url $R                                # 1
cast call <NEW_VAULT> "maxRedeem(address)(uint256)" 0xC75E64Ccf3ce6E2F40939Ab58255681769BcF8C4 --rpc-url $R
```

---

## Task 11: Register the new vault and repoint the site

**Files:**
- Create: `zorpha-web/migrations/015-stock-vault-v2.sql`
- Modify: `zorpha-web/lib/deployment.ts`
- Modify: `zorpha-web/lib/contracts.ts`

**Interfaces:**
- Consumes: the new vault address and its deployment block.
- Produces: the receipt feed following the new vault.

**Background.** Follow `zorpha-web/migrations/013-mainnet-stock-vault.sql` exactly in shape. The `vaults` primary key is `(chain_id, address)` since migration 012, and `getCursor` matches the address as an exact string with no `lower()`, so the case of the address must match what the indexer writes.

Receipts stay keyed by vault address, so the old vault keeps its two. The record is presented **by manager**, which `rebalances.manager` and `/portal/managers/[address]` already support, so the history is continuous across the redeploy. Add the "succeeds" pointer described in the spec so the lineage is explicit.

- [ ] **Step 1: Write the migration**

Create `zorpha-web/migrations/015-stock-vault-v2.sql`, following 013's structure: insert the vault row, seed `indexer_cursor` at the deployment block, and set `deployed_at`. Include a comment block explaining why a second stock vault row exists, pointing at `docs/design/stock-vault-exit-paths.md`, and note that the old row is kept rather than deleted so its two receipts stay attributable.

- [ ] **Step 2: Repoint the site**

In `zorpha-web/lib/deployment.ts`, replace the `zqNVDA` entry in `LIVE_VAULTS` with the new address and remove the old one. In `zorpha-web/lib/contracts.ts`, update the stock vault address constant.

- [ ] **Step 3: Check the web tests and build**

```bash
cd zorpha-web
npm test
npm run build
```

Expected: pass. `lib/tokenomics.test.ts` includes a chain-drift test gated on `ZOR_RPC_URL`; it is unrelated to this change but will run if that variable is set.

- [ ] **Step 4: Run the migration, then confirm the receipt feed**

Run `015-stock-vault-v2.sql` against Supabase. Then, after the next rebalance, confirm the receipt appears at `/portal/receipts` with `underlying_price` set and `exact` true. If `exact` is false, the indexer fell behind the archive window: the public RPC serves state for roughly 5,000 to 20,000 blocks, so a receipt must be indexed within about 12 to 50 minutes or its exact price is unrecoverable.

- [ ] **Step 5: Commit and open a PR**

```bash
git add zorpha-web/migrations/015-stock-vault-v2.sql zorpha-web/lib/deployment.ts zorpha-web/lib/contracts.ts
git commit -m "feat(web): follow the fixed stock vault"
```

---

## Final verification

- [ ] `forge test` reports 0 failed, and the count is above 403.
- [ ] `forge test --match-path 'test/fork/*'` with `RH_MAINNET_RPC_URL` set: 0 failed.
- [ ] `forge test --match-path 'test/fork/*'` without it: all skipped, 0 failed.
- [ ] `git grep -nP "(?<!')\x{2014}(?!')" -- . ':!sidequest-protocol/contracts/lib'` returns nothing.
- [ ] The invariant bites: reintroduce `return balanceOf(owner);` at the top of `maxRedeem`, confirm `invariant_MaxRedeemIsExecutable` fails, then remove it.
- [ ] On chain: the new vault is Blockscout-verified, the Timelock holds `DEFAULT_ADMIN_ROLE`, no EOA holds any role, and `maxRedeem(SAFE)` is above 98% of the holding.
- [ ] The old vault holds nothing and has zero supply.
- [ ] No commit message, PR body, comment or document mentions Claude, Anthropic or AI, and none carries a `Co-Authored-By` trailer.

# Finding: the emergency exit strands the cash leg and reports the loss as zero

**Status:** **fixed** by option 3, both legs paid in kind. Originally observed on
testnet 46630, 2026-09-02, in transaction
`0x2baa8c117200bb14f7345914bd18d0d03341d27de5dd510dbe5e5e75bebf0406`. See **Fix**
below. The change alters what a depositor receives, so it needs the auditor's eye
even though it strictly increases what they get.
**Contract:** `src/vaults/SpotVaultMinimal.sol`, `redeemEmergency`
**Severity:** the forfeiture is by design. The silence about it is not, and the
orphaning is worse than either.

---

## What the escape hatch is for, and why it is right

`redeemEmergency` pays a pro-rata share of the **asset leg only**. It reads
neither the swap venue nor the oracle. That independence is the whole point: a
depositor has to be able to leave when the market has no depth or the price feed
is dead, which are precisely the moments they most want to, and precisely the
moments a normal `redeem` cannot help them.

Proven on chain. The testnet spot vault had been left unable to rebalance or
redeem — a normal `redeem` reverted, first on slippage and later on
`InsufficientFreshReports` once the oracle went stale. `redeemEmergency` still
paid out, with a dead oracle and a venue that could not have serviced the trade.
That is the design working exactly as intended, and it is worth saying plainly
before the rest of this document.

## Three problems, in increasing order of seriousness

### 1. The haircut is reported as zero

```solidity
uint256 bal = IERC20(asset()).balanceOf(address(this));   // ASSET leg only
uint256 grossOwed = (shares * bal) / supply;
uint256 feeShare  = (shares * performanceFeeAccrued) / supply;
uint256 owed      = grossOwed > feeShare ? grossOwed - feeShare : 0;
paid = owed;
uint256 haircut = grossOwed > paid ? grossOwed - paid : 0;
```

`grossOwed` is derived from the asset balance alone, so `haircut` can only ever
equal `feeShare`. The cash leg — the thing actually given up — never enters the
arithmetic.

The observed exit:

| | |
| --- | --- |
| shares burned | 100,000,000,000,000,000,000,000,000 |
| paid, asset leg | 50,000,000,000,000,000,000 |
| **haircut, as emitted** | **0** |
| cash leg forfeited | 50,000,000,000,000,000,000 |

A depositor reading `EmergencyRedeem` would conclude they gave up nothing. They
gave up the entire cash side of the position. A field named `haircut` that reads
zero on a total forfeiture is worse than no field: it is an affirmative claim
that nothing was lost.

### 2. The stranded cash inflates entry NAV for whoever comes next

The vault now holds zero shares and a non-zero cash balance. `grossValue()`
counts that cash, so the next depositor's entry NAV is set by a balance nobody
owns. That is the same mechanism as
[FINDINGS-EQUALISATION.md](FINDINGS-EQUALISATION.md), reached by a different
route and at a much larger magnitude — dust there, half a position here.

### 3. Nothing can ever recover it

`SpotVaultMinimal` has no rescue, sweep or recover function. Checked: the only
admin entrypoints are `claimFees`, `writeDownAccruedFees`, `setSwapAdapter`,
`setFeeRecipient`, `setCircuitBreaker` and `setEmergencyRedeemCooldown`. None
moves a stray token.

So the forfeited cash is permanently orphaned. On testnet that is 50e18 units of
a mock stablecoin and nobody cares. On mainnet it is real money owned by no one,
sitting in a contract with no path out, and the more depositors use the escape
hatch the more accumulates. A vault that has seen several emergency exits carries
a growing balance that belongs to nobody and prices the next entrant wrongly.

## What is not wrong with it

The forfeiture itself. Paying out only the asset leg is what makes the hatch
venue-independent, and a depositor choosing it is choosing speed over
completeness. That trade is sound and should stay.

The cooldown is also right, and tested: without it the hatch could be used to
drain the asset leg in a loop while the cash leg stayed stuck.

## Fix

Option 3. `redeemEmergency` now transfers a pro-rata slice of **both** legs:

```solidity
uint256 cashOwed = (shares * cashBal) / supply;
...
if (cashOwed > 0) cashAsset.safeTransfer(receiver, cashOwed);
```

It reads no oracle and calls no venue, so the independence that made this
function worth having is untouched. That is the point worth drawing out: **the
independence never actually required the forfeiture.** Paying in kind is exactly
as venue-independent as confiscating, and the argument that justified keeping the
cash was really an argument for not needing a price -- which an in-kind transfer
also does not need.

All three problems close at once:

| | Before | After |
| --- | --- | --- |
| Haircut reported | `0` on a total forfeiture | the fee, which is all that is withheld |
| Residue after exit | half a position, owned by nobody | nothing |
| Recovery path | none, permanently | nothing to recover |

The signature is now `returns (uint256 paid, uint256 paidCash)` and
`EmergencyRedeem` carries `paidCash`. Only tests called it, so nothing else
needed changing.

The cost is that a depositor receives two tokens instead of one. That is a UX
cost, not a safety one.

### Two tests existed only to prove the defect

`test_EmergencyRedeem_HaircutUnderReportsTheStrandedCash` and
`test_EmergencyRedeem_StrandedCashCannotBeRecovered` both asserted the broken
behaviour on purpose, so both failed the moment the fix landed -- which is what a
regression test documenting a known bug is *for*. They are rewritten as
`..._HaircutOfZeroIsNowTrue` and `..._LeavesNothingNeedingRescue`, each keeping a
note of what it used to prove.

The second still pins that there is no rescue function, deliberately. An empty
vault needing no rescue beats a rescue path nobody has audited.

## Options

Not chosen. The first is cheap and uncontroversial; the rest are design
decisions.

1. **Report the real haircut.** Value the forfeited cash leg and include it, or
   emit it as its own field. Costs an oracle read, which the function currently
   and deliberately avoids — so the honest version may be to emit the raw
   forfeited cash amount rather than its value, keeping the function
   price-independent. Small, and it stops the event asserting something false.
2. **Sweep the residue when the vault empties.** If `totalSupply()` reaches
   zero, send the remaining balances to the treasury and let the next depositor
   start clean. Fixes problems 2 and 3 together, and would also close the
   equalisation gap by removing its precondition.
3. **Pay the cash leg in kind.** Transfer the depositor their share of both
   legs. No forfeiture, no orphaning, and still no oracle or venue needed. The
   depositor receives two tokens instead of one, which is a UX cost rather than
   a safety one. This is what most in-kind redemption designs do.
4. **Accept and document.** Then it belongs in the depositor-facing risk copy,
   because "you may forfeit part of your position" is not currently said
   anywhere a depositor would read.

Option 3 was chosen. It changes what a depositor receives, which is why it is
flagged for the auditor -- but it changes it *upward*, from part of a position to
all of it, and leaving a known confiscation in place to avoid touching fee
semantics would have been the more dangerous conservatism.

## Open

- [x] Prove the hatch works with a dead oracle and a dry venue. Five tests in
      `test/vaults/SpotVaultMinimal.t.sol`, plus the on-chain exit above.
- [x] Decide between options 1–4. Option 3, implemented.
- [ ] Whichever is chosen, say in the depositor-facing copy that an emergency
      exit can forfeit part of the position. It is not written down today.

# Finding: a depositor can be charged a performance fee on gains earned before they arrived

**Status:** fixed, pending auditor review. Found on testnet 46630, 2026-09-02,
by `contracts/script/testnet-yield-drill.sh`. Remediated the same day, see
**Fix** below. The fix changes fee behaviour, so it must not reach mainnet
without the external auditor having looked at it.
**Contracts:** `src/vaults/YieldVault.sol` (found here), and
`src/vaults/SpotVaultMinimal.sol` (the same defect, found later by inspection , 
see **The spot vault had it too** below).
**Severity:** low in isolation, and it should be on the external audit's list
regardless; it is a fee-accounting design gap, not a coding error, and those
are the ones an author reviewing their own work is least likely to see.

---

## What happened

A depositor put 1,000 tUSDG into `zqUSD`, the venue earned, and they redeemed.
They were charged **60,000,000** base units of performance fee where their own
gain implies **50,000,000**. A 20% overcharge.

| | NAV delta the fee was charged on | Fee |
| --- | --- | --- |
| What the contract charged | 7,500,000 − 4,500,000 (**stale mark**) = 3,000,000 | 60,000,000 |
| What the depositor earned | 7,500,000 − 5,000,000 (**their entry**) = 2,500,000 | 50,000,000 |

The contract behaved exactly as written. `performanceFeeAccrued` moved by
60,000,000 and the contract's own formula predicts 60,000,000 to the unit. The
problem is what the formula measures against.

**It reproduces on every cycle.** Two consecutive runs, same vault, both
overcharged:

| Run | Mark at entry | Entry NAV | Gap | Fee charged | Fair fee | Overcharge |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | 4,500,000 | 5,000,000 | 500,000 | 60,000,000 | 50,000,000 | 10,000,000 (20%) |
| 2 | 7,500,000 | 8,000,000 | 500,000 | 56,250,000 | 50,000,000 | 6,250,000 (12.5%) |

The entry NAV lands at `(dust + 1) x 1e6` through the ERC-4626 offset, and the
mark is wherever the previous cycle left it, so the gap recurs every time the
vault is emptied and re-entered. This is deterministic, not a rare interleaving.

## A refinement: it needs drift, not one cycle

Writing the regression test turned up something that lowers the severity a
little, and is worth stating because it was not obvious.

**A clean full redemption self-corrects.** The residue a redemption leaves is
almost exactly `multiple - 1` base units, which the 1e6 offset turns back into
`multiple * 1e6`; the old NAV. So the next depositor's entry lands *exactly
on* the old mark: not above it, not below. No overcharge.

The unit test could not reach "entry above the mark" through a single cycle for
this reason, and had to force it. What produced the testnet case was **drift
across four cycles**: the dust grew by two or three units per cycle rather than
tracking `multiple - 1` precisely, and once it ran ahead of the mark the gap
opened.

So the precondition is not "a vault was emptied once". It is "a vault has been
emptied and re-entered repeatedly, with fees left unclaimed across cycles".
Narrower than first written, and still reachable over a vault's life.

## Why

`_evaluateFees()` runs *before* the shares are minted:

```solidity
function deposit(uint256 assets, address receiver) public override … {
    _evaluateFees();
    return super.deposit(assets, receiver);
}
```

and it opens with

```solidity
if (totalSupply() == 0) return;
```

That early return is deliberate and load-bearing; the comment above it explains
that letting an empty vault's sentinel NAV reach `highWaterMark` would ratchet
the mark to a level the vault can never exceed and disable performance fees for
the life of the contract. That reasoning is correct.

The consequence, though, is that **the first depositor into an empty vault never
marks their entry price.** If the vault holds any assets while empty, the
ERC-4626 decimal offset puts that depositor's entry NAV above the stale mark,
and at redemption the fee is charged from the mark rather than from where they
actually bought in.

Sequence, as observed:

1. Vault empty. `totalSupply` 0, `highWaterMark` 4,500,000, `rawAssets` 4 (dust).
2. `deposit()` → `_evaluateFees()` sees supply 0, returns. Mark stays 4,500,000.
3. `super.deposit()` mints. Entry NAV is **5,000,000**; the dust and the
   1e6 offset, not a gain anyone made.
4. Venue earns. NAV → 7,500,000.
5. `redeem()` → `_evaluateFees()` charges on 7,500,000 − 4,500,000.

The depositor pays for the 500,000 of NAV that existed before step 3.

## This is the equalisation problem

Pooled funds that charge a performance fee against a single shared high-water
mark have this in both directions:

- **Entry below the mark**; the depositor rides free until the old peak is
  beaten, and the leader earns nothing on real gains. Well known, usually
  accepted, costs the manager.
- **Entry above the mark**; the depositor pays for appreciation they did not
  receive. This one. Costs the depositor.

Real funds solve it with equalisation accounting: a per-subscription mark, or
equalisation credits/debits issued at entry. Zorpha has neither.

## How reachable is it

It needs NAV to sit above the mark at the moment someone deposits, which needs
the vault to hold assets while `totalSupply` is 0. Sources, weakest first:

1. **Rounding dust.** What produced it here, over repeated drills. The dust
   itself is tiny, nine base units after four cycles; but do not read that as
   a small effect. The ERC-4626 offset is 1e6, so *each unit of dust moves the
   entry NAV by a million*, and the mark always lags a cycle behind. That is
   why a nine-unit residue produced a 12–20% overcharge. The precondition is
   cheap; the consequence is not proportional to it.
2. **A donation to the venue.** Anyone can inflate an ERC-4626 venue. Expensive
   for an attacker, because it lifts every depositor in that venue, not just
   this vault.
3. **Yield accruing while the vault is empty.** The realistic one over a vault's
   life. A vault that is fully redeemed and later re-entered will have this
   whenever the residue earned anything in between.

`performanceFeeAccrued` is *not* a source: `rawAssets()` subtracts it, so
unclaimed fees do not inflate the entry NAV.

**Griefing note.** The overcharge is paid to the fee recipient. On a
leader-launched vault that is the escrow, which splits 80% to the leader. So a
leader whose vault has emptied has a weak incentive not to fix the residue
before new deposits arrive. Not an attack worth mounting at current sizes, but
the incentive points the wrong way, which is the part worth recording.

## What it is not

Not a rounding artefact. Rounding in this path is at most five base units; one
per conversion in a deposit/redeem round trip. This was ten million.

Not a bug in the fee formula. The formula computes what it says it computes,
to the unit.

## Fix

Option 1 of the four below, implemented in `YieldVault._markFirstEntry()`.

`deposit` and `mint` record whether the vault was empty, and if it was, set
`highWaterMark` to `getNavPerShare()` *after* minting; the price the incoming
depositor actually paid. Reading the NAV there is safe where it is not inside
`_evaluateFees`: supply is non-zero by that point, so it returns a real price
rather than the `10 ** decimals()` sentinel whose ratcheting the early return
exists to prevent. `test_MarkNeverTakesTheEmptyVaultSentinel` pins that.

**The reset is unconditional**, not `if (nav > highWaterMark)`. An empty vault
has no holders for the mark to protect, so there is nobody it can be lowered at
the expense of.

**This is a behaviour change in both directions, and the second one is an
economic decision, not a bug fix.** Overcharging on entry above a stale mark
stops, which is the finding. But entry *below* a stale mark also stops riding
free: a depositor entering after a drawdown-and-exit now pays a fee on gains
between their entry and the old peak, where previously the leader earned nothing
until the peak was beaten. That is the conventional treatment and it favours the
leader. It should be an explicit choice rather than a side effect, flagging it
here so it is not discovered later.

Three regression tests in `test/vaults/YieldVault.t.sol`:

- `test_FirstDepositorIntoADustyVaultPaysOnlyForTheirOwnGain`; the finding.
- `test_FirstDepositorBelowAStaleMarkStillPaysOnTheirGain`; the mirror case.
- `test_MarkNeverTakesTheEmptyVaultSentinel`; the regression the early return
  guards against.

Full suite green: 152 tests, up from 149, zero failures, both invariant suites
included.

## The spot vault had it too

Found afterwards, by reading `SpotVaultMinimal._evaluateFees` with this finding
already in hand. Same two preconditions, so the same conclusion had to follow:

- `highWaterMark` only ratchets up, line 327's `if (nav <= highWaterMark) return`
  means the assignment below it is unreachable on a fall.
- `getNavPerShare()` returns the `10 ** _assetDec` sentinel once supply is zero.

**It reaches only the free-ride direction, not the overcharge.** The spot vault
seeds `highWaterMark = 10 ** _assetDec` in its constructor, the same value the
sentinel returns, so a genuinely first depositor is marked correctly. The gap
opens only after a profitable depositor leaves: the mark stays at their high
point, and the next depositor pays nothing until they have re-earned somebody
else's gain. Lost revenue rather than an overcharge; which is why no drill
caught it. Nothing reverts and nobody complains.

Measured in `test_FeeAccrual_AfterEmptying_ChargesTheNextDepositor`: the mark
stood at **2.0** while the incoming depositor had bought in at **0.9**. A 122%
gain, entirely free.

Fixed identically, `_markFirstEntry()` on `deposit` and `mint`, plus a
`HighWaterMarkReset` event the spot vault did not have.

### The fee had no real coverage at all

Worth recording separately, because it is why this survived. The spot suite's
`test_FeeAccrual_BelowHWM_NoAccrual` asserts `performanceFeeAccrued() == 0`, on
a vault built with `performanceFeeBps = 0`. It cannot fail. **No test anywhere
proved the spot vault ever charges a performance fee**, so the whole mechanism
was unverified while reading as covered. The new `SpotVaultFeeTest` contract adds
the missing baseline (`test_FeeAccrual_AboveHWM_Charges`) before testing anything
subtler.

A green assertion on a disabled feature is worse than a missing one: it occupies
the space where the real test would go.

## Options considered

1. **Mark the entry NAV for a first depositor.** ← **chosen.** Smallest change
   that addresses the cause.
2. **Sweep the residue when a vault empties.** Removes the precondition rather
   than handling it. Rejected as the primary fix because it needs a privileged
   caller at exactly the moment a vault empties, which nothing guarantees; still
   worth doing as defence in depth.
3. **Per-depositor equalisation.** Correct and much larger. Not V1.
4. **Accept and document.** Rejected: a 12–20% overcharge is not dust-sized,
   whatever the size of the residue that causes it.

## Reproducing

```bash
./script/testnet-yield-drill.sh <keystore-account>
```

The drill now asserts the contract's own formula, so it passes. It prints the
gap loudly whenever entry NAV is above the mark:

```
!! entry NAV 5000000 is ABOVE the high-water mark 4500000 by 500000.
!! The fee will be charged from the mark, not from the entry price, so
!! this depositor pays for 500000 of NAV they never earned.
```

## Open

- [x] Add a Foundry test covering entry-above-mark. Three added; nothing in the
      suite exercised it before, which is why 20 tests, six invariants and a
      fuzz test were green while this was live.
- [x] Fix the cause. `_markFirstEntry()`, option 1.
- [x] Check `SpotVaultMinimal` for the same defect. It had it, free-ride
      direction only; fixed the same way. Two tests added, plus the baseline the
      suite never had.
- [ ] Audit the remaining fee-bearing contracts for the same two preconditions
      (a mark that only ratchets up, and an empty-vault NAV sentinel). Two of
      two checked so far both had it, so the base rate is not reassuring.
- [ ] **Auditor review of the fix.** It changes fee accounting. Do not ship to
      mainnet on my say-so.
- [ ] **Decide the below-mark behaviour deliberately.** The fix stops the free
      ride as well as the overcharge. That favours leaders over late depositors
      and should be a choice, not a side effect.
- [ ] Consider option 2 as well, as defence in depth against a residue building
      up at all.

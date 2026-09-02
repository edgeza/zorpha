# Finding: a depositor can be charged a performance fee on gains earned before they arrived

**Status:** open, unremediated. Found on testnet 46630, 2026-09-02, by
`contracts/script/testnet-yield-drill.sh`.
**Contract:** `src/vaults/YieldVault.sol`
**Severity:** low in isolation, and it should be on the external audit's list
regardless — it is a fee-accounting design gap, not a coding error, and those
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

That early return is deliberate and load-bearing — the comment above it explains
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
3. `super.deposit()` mints. Entry NAV is **5,000,000** — the dust and the
   1e6 offset, not a gain anyone made.
4. Venue earns. NAV → 7,500,000.
5. `redeem()` → `_evaluateFees()` charges on 7,500,000 − 4,500,000.

The depositor pays for the 500,000 of NAV that existed before step 3.

## This is the equalisation problem

Pooled funds that charge a performance fee against a single shared high-water
mark have this in both directions:

- **Entry below the mark** — the depositor rides free until the old peak is
  beaten, and the leader earns nothing on real gains. Well known, usually
  accepted, costs the manager.
- **Entry above the mark** — the depositor pays for appreciation they did not
  receive. This one. Costs the depositor.

Real funds solve it with equalisation accounting: a per-subscription mark, or
equalisation credits/debits issued at entry. Zorpha has neither.

## How reachable is it

It needs NAV to sit above the mark at the moment someone deposits, which needs
the vault to hold assets while `totalSupply` is 0. Sources, weakest first:

1. **Rounding dust.** What produced it here, over repeated drills. Grows by a
   unit or two per full cycle, so the effect is small and slow.
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

Not a rounding artefact. Rounding in this path is at most five base units — one
per conversion in a deposit/redeem round trip. This was ten million.

Not a bug in the fee formula. The formula computes what it says it computes,
to the unit.

## Options

Listed, not chosen. This should be decided with the external auditor.

1. **Mark the entry NAV for a first depositor.** In `deposit`/`mint`, when
   `totalSupply() == 0` and `totalAssets() > 0`, set `highWaterMark` to the NAV
   the incoming deposit will establish. Smallest change; needs care not to
   reintroduce the sentinel-ratchet problem the early return exists to prevent.
2. **Sweep the residue when a vault empties.** If `totalSupply()` returns to 0,
   send the remaining `rawAssets()` to the treasury and reset the mark. Removes
   the precondition rather than handling it.
3. **Per-depositor equalisation.** Correct and much larger. Probably not V1.
4. **Accept and document.** Defensible while the magnitude is dust-sized, but
   then it belongs in the depositor-facing risk copy, not only here.

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

- [ ] Raise with the external auditor as a named item rather than leaving it to
      be rediscovered.
- [ ] Decide between options 1–4 before mainnet.
- [ ] Add a Foundry test covering entry-above-mark. No test in the suite exercises
      it today, which is why 20 tests and a fuzz test passed while this was live.

# `minCoverageBps` is a minimum on the leader's exit, not on the vault

**Severity:** medium — a stated protection binds in one direction only
**Status:** observed and drilled; **not fixed**, because the fix is a product decision
**Found:** 3 September 2026, while writing the escrow floor drill

## What the code does

`FirstLossEscrow.minCoverageBps` reads as a floor under the leader's first-loss
capital, and `VaultLauncher.vaultSummary` returns `adequatelyCovered` for a
leaderboard to display. There is exactly one place it is enforced:

```solidity
// FirstLossEscrow.executeWithdrawal
if (raw > 0) {
    uint256 after_ = (remaining * 10_000) / raw;
    if (after_ < minCoverageBps) revert WouldBreachMinimum(after_, minCoverageBps);
}
```

That is the leader withdrawing their own capital. It works, and the drill proves
it on chain.

Nothing enforces it on the way in:

```solidity
// YieldVault.maxDeposit
function maxDeposit(address) public view override returns (uint256) {
    if (isCircuitBreakerActive) return 0;
    if (totalSupply() > 0 && totalAssets() == 0) return 0;
    return type(uint256).max;
}
```

No reference to `firstLossEscrow`, no coverage term. So deposits dilute coverage
without limit:

| | escrow | raw assets | coverage |
|---|---|---|---|
| at launch | 1,000 | 1,000 | 10000 bps |
| after growth | 1,000 | 100,000 | **100 bps** |

against a `minCoverageBps` of 500. Every one of those deposits succeeds, and
`adequatelyCovered` flips to false while the vault keeps taking money.

## Why this is not obviously a bug

An absolute buffer necessarily thins as a vault grows. Capping inflows on
coverage would mean a successful vault stops accepting deposits until its leader
posts more capital — which throttles exactly the vaults that are working, and
hands the leader a veto over growth they may not want to fund.

So the current behaviour is a defensible design. What is not defensible is the
gap between it and the words around it:

- "minimum coverage" describes a floor. This is a floor on one transition
- `adequatelyCovered` is surfaced to depositors through `vaultSummary`, and can
  read false at the moment someone deposits, with nothing in the deposit path
  mentioning it
- the launch gate checks `minSeedEscrow` and coverage **at launch**, so coverage
  is validated at the start and at the leader's exit, and never in between —
  which is the entire period a depositor is exposed

## Options, none of them free

1. **Cap deposits on coverage.** `maxDeposit` returns the amount that keeps
   coverage at or above the floor. Honest to the name; throttles growth; leaves
   a vault unable to accept deposits until the leader tops up.
2. **Rename it.** `minCoverageBpsForWithdrawal`, and have the UI show live
   coverage rather than a boolean. Cheapest, changes no behaviour, and makes the
   guarantee match the word.
3. **Warn but allow.** Emit an event, or surface a prominent state, when a
   deposit takes coverage below the floor. Keeps growth, removes the silence.
4. **Do nothing.** Defensible, if documented.

My own view is 2 plus 3: the mechanism is reasonable and the naming is what
misleads. Capping inflows sounds safest and would probably make leaders' vaults
unusable at exactly the wrong moment. But this is a product call with real
consequences for how the protocol grows, and it should be governance's and the
auditor's, not a script author's.

## What is drilled

`script/testnet-leader-bond-drill.sh`, part B. It asserts the behaviour as it
**is**, in both directions:

- a large deposit dilutes coverage, and **succeeds** — the drill records this
  rather than asserting a guarantee that does not exist
- if the deposit crosses the floor, `adequatelyCovered` must report `false`.
  Coverage below the floor while that boolean still read true would be a
  reporting bug on top of the unenforced floor, and that is asserted
- the leader's `executeWithdrawal` **is** refused with `WouldBreachMinimum` —
  the one direction the floor binds

Deliberately not asserted: that deposits are refused. Writing that assertion
would have made the drill fail against correct code and sent someone to "fix"
a design decision by accident.

## Related

- [[FINDINGS-ROLE-ESCALATION]] — the other case found this week where a
  protection was asserted in prose and enforced in one direction only

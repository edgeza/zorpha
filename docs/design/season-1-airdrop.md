# Season 1 airdrop: criteria and distribution

Status: design approved 6 September 2026. Not yet implemented.

## The finding that shapes this

The tranche is 80,000,000 ZOR, 8% of supply, claimed out of the first
MerkleDistributor on 6 September 2026 (tx `0x5164348672e7519d9f0841437450b6c568d360ac74eed9ceb9d068bcfa61287a`)
and now held by the governance Safe `0xC75E64Ccf3ce6E2F40939Ab58255681769BcF8C4`.

Before designing criteria it is worth knowing who exists to receive them.
Reconstructed from every ZOR `Transfer` event on chain 4663:

    0x44e4208f...    19,302,849 ZOR    90.3% of the external float
    0xc066a32e...     1,457,985
    0xfb8ab4b8...       602,766
                     ----------
    external float   ~21,400,000 ZOR   2.5% of supply

Thirty-one Transfer events exist in total. Three external wallets hold
essentially the whole public float, and one holds 90% of it. That wallet
matches the one recorded as draining the initial concentrated-band pool at an
average of $0.0000214.

Two consequences follow, and they determine everything below.

**There is no organic cohort to reward.** The tranche is roughly four times the
entire external float. Any criteria keyed on activity that has already happened
would hand the majority of an 8% tranche to the entity that drained the first
pool.

**The tranche cannot function as an incentive.** At the current $0.000014 per
ZOR, itself set by a pool holding $536, the whole 80,000,000 is worth about
$1,120. Nobody deposits capital to earn a share of that. Elaborate
time-weighted incentive design here would be theatre.

## What Season 1 is for

Not incentive. **Distribution.**

Three holders with one at 90% is the single most damaging fact about ZOR. It is
what a rug looks like from outside, it is the first thing any aggregator or
counterparty checks, and no quantity of verified contracts or honest
documentation survives it. It also means governance has one meaningful voter.

So Season 1 exists to put the token into a real number of independent hands
that did something genuine, and to prove the distribution machinery end to end
on a small slice before the bulk is committed.

This has one design consequence that matters more than any formula: **a cap
beats a weight.** Any pro rata scheme re-concentrates into whoever brings the
most capital, which with three wallets in existence means re-concentration by
construction.

## Size and shape

**Season 1 is 8,000,000 ZOR, 10% of the tranche, 0.8% of supply.** The
remaining 72,000,000 stays in the Safe for later seasons.

Small on purpose. A Merkle root is immutable once deployed; the first
distributor shipped with a testnet root and was unfixable, which is why it sat
funded and unclaimable until the tree was regenerated. Committing 8% of supply
against a cohort that does not exist yet is the same shape of mistake, and the
48 hour timelock does not protect against it.

**Allocation is a fixed amount per qualifying address, not a share of a pot.**
If three addresses qualify, three addresses receive their fixed allocation and
the rest rolls into Season 2. Nobody splits 8,000,000 three ways. If more
qualify than the slice covers, the window closes at the cap and the overflow
sets Season 2's starting point.

This makes undersubscription safe, which matters when the cohort could
plausibly be five people or five hundred.

## Criteria

Qualifying action is a deposit into a Zorpha vault. It is the protocol's actual
product and the one behaviour that also builds the value chain the token
depends on: vault TVL, then fees, then buyback.

| Tier | Requirement | Allocation |
|---|---|---|
| 1 | at least 25 USDG in a Zorpha vault, held at least 30 continuous days | 15,000 ZOR |
| 2 | at least 250 USDG in a Zorpha vault, held at least 60 continuous days | 40,000 ZOR |

Ten times the capital and twice the duration earns 2.7 times the allocation.
That compression is deliberate: this is a gate with a nod to commitment, not a
weight. Tier 2 is a hard cap. There is no tier above it, so no amount of
capital concentrates the tranche.

Duration is continuous, measured deposit to withdrawal, so a deposit made on
snapshot day earns nothing.

**Window: 90 days from publication of the criteria.** Long enough for a 60 day
tier to complete inside it.

### What recipients must be told

At today's price tier 1 is worth about $0.21 and tier 2 about $0.56. No choice
of numbers changes that: the full 80,000,000 split across 200 addresses would
still be $5.60 each.

The allocation is a claim on the token being worth something later, not a
payment, and the site must say so in those words. Presenting it as a reward
worth having would repeat exactly the class of overstatement removed from the
site on 6 September.

## Sybil

The attack is to split capital across wallets, each clearing tier 1. The
arithmetic is worth doing rather than assuming.

One hundred sybil wallets requires 2,500 USDG locked for 30 days and yields
1,500,000 ZOR, about $21. That is a poor return on the capital tied up, and it
delivers the protocol 2,500 USDG of TVL, which is over 500 times what the vault
holds today.

**At this scale the sybil attack and the desired outcome are the same event.**
Someone farming it is depositing real money for a real duration. What is lost
is only that the holder count is less genuine than it looks, which matters
because distribution is the goal, but does not justify elaborate machinery.

Two mitigations, both cheap:

The capital and duration gate already imposes real cost. That is most of the
defence.

**Funding graph clustering is unusually easy on this chain.** With 31 ZOR
transfers in total, tracing which wallets were funded from a common source is
trivial in a way it never is on a busy chain. The published criteria will state
that obvious clusters are excluded, which gives deterrence plus the genuine
ability to follow through.

## Governance

The roadmap currently says the tranche is held "until the criteria are
published and voted", and the Phase 3 gate reads "Season 1 criteria put to a
vote". There is no Governor contract. It is Phase 4 work.

**A token vote today would be worse than no vote.** The external float is
21,400,000 ZOR of which the suspected bot holds 19,302,849. A token weighted
vote would hand the decision on an 8% tranche to the wallet that drained the
first pool.

**Decision: Season 1 is approved by the governance Safe (2 of 2) under its 48
hour timelock, and the site is changed to say that** rather than implying token
holder voting. Token holder voting arrives with the Governor in Phase 4, and
the site should say that too.

This is the same discipline applied across the site on 6 September: describe
the mechanism that exists, not the one intended.

## Mechanics

1. **Publish criteria before the window opens.** This is the commitment, and
   the order matters: criteria first, then measurement.
2. **Window runs 90 days.**
3. **At close, snapshot tooling** scans vault deposit and withdrawal events
   across the window, computes continuous hold duration per address, applies
   the tiers, and applies the clustering exclusion. Output is a recipient list.
4. **The existing pipeline takes over.** `sidequest-protocol/scripts/generate-airdrop.ts`
   and the manifest and proofs generator already work; they produced the single
   leaf governance tree correctly. Feed it the recipient list.
5. **Deploy a second MerkleDistributor**, funded from the Safe with exactly the
   qualifying total, not the full 8,000,000 slice. The undistributed remainder
   never leaves the Safe, so there is nothing to sweep and no repeat of a
   distributor sitting funded and unclaimable.
6. **Set a generous `claimDeadline`.** It is immutable.

### Housekeeping folded in

`zorpha-web/data/airdrop/` still holds five per address JSON files from the
testnet drill, including one for the burned deploy key `0xb4a7c2de...`. They
are served only by a local only fallback, so production correctly returns 404,
but they are stale and should be deleted with this work.

The portal airdrop page copy changes from "the snapshot criteria have not been
published yet" to the criteria themselves.

## Out of scope

- The Governor contract. Phase 4.
- Seasons 2 and beyond. This design deliberately leaves 72,000,000 uncommitted.
- Pool liquidity depth. It is the binding constraint on the token being worth
  anything, and no airdrop design addresses it.
- The buyback router, still unset.

# Why the fees are what they are

**Status:** the numbers below are deployed. The reasoning was not written down
until now, which is the reason for this file.

## The problem this document solves

`FirstLossEscrow.sol` carries this comment:

> Hyperliquid requires a vault leader to hold 5% of TVL, which took…

and `VaultLauncher` sets `minCoverageBps = 500; // 5%, the level Hyperliquid
settled on`.

So the **risk** parameter was deliberately benchmarked against the closest
comparable product. The **fee** was not benchmarked anywhere, and sits at twice
that comparable's rate. To an auditor or a sophisticated depositor reading the
repo, that looks like an oversight rather than a decision; and until this file
existed, there was nothing to distinguish the two.

## What is deployed

Read off chain 46630 on 3 September 2026:

| vault | performance fee | management fee | high-water mark |
|---|---|---|---|
| Spot (`zqtAAPL`) | 20% | none | yes |
| Rotation (`zqROT`) | 20% | none | yes |
| Yield (`zqtUSDG`) | 10% | none | yes |

`VaultLauncher.leaderFeeShareBps = 8000`, `minCoverageBps = 500`,
`bondAmount = 10,000 ZOR`, `minSeedEscrow = 1,000 USDG`.

## The comparison set

| venue | performance | management | leader skin | HWM |
|---|---|---|---|---|
| Hyperliquid user vaults | 10% | none | 5% | yes |
| **Zorpha spot / rotation** | **20%** | none | 5% | yes |
| **Zorpha yield** | **10%** | none | 5% | yes |
| Morpho vaults (cap, not norm) | up to 50% | up to 5%/yr | n/a | n/a |

Hyperliquid is the structural twin: a leader runs a vault, posts 5% of TVL as
skin in the game, takes a fixed cut of profits above a high-water mark, and
charges nothing annually. Morpho's numbers are a *ceiling* set per curator, not
a market rate, and its vaults are curated credit rather than directional
strategies, useful for showing there is headroom above 10%, not for showing
what is normal.

## Where a dollar of profit actually goes

This is the part that was not obvious and that changes the argument.

**Leader-launched vaults** (those with a `FirstLossEscrow`, e.g. `zqLEAD`):

| | leader | protocol | depositor |
|---|---|---|---|
| Hyperliquid user vault | 10% | 0% | 90% |
| Zorpha spot / rotation | **16%** | 4% | 80% |

`splitFees` sends `leaderFeeShareBps` (80%) of the fee to the leader, so a
20% fee is 16 points to the leader and 4 to the protocol.

**Factory vaults** (`zqtAAPL`, `zqROT`, `zqtUSDG`) have no escrow , 
`firstLossEscrow` is the zero address on all three; so there is no leader and
the whole fee goes to `feeRecipient`, the treasury. `ProtocolTreasury` then
sends 50% of anything it receives to the buyback.

So the 20% is two different things depending on the vault, and only one of them
is protocol revenue:

- on a **leader** vault it is mostly a leader payment, with the protocol taking
  the smallest slice in the table
- on a **factory** vault it is entirely protocol revenue, half of which is
  bought back and burned

## The justification

**The 20% on spot and rotation is a leader-recruitment decision, not a revenue
decision.** A Zorpha leader earns 60% more than a Hyperliquid leader on
identical performance, 16 cents against 10; and the depositor funds the
difference. That is a coherent strategy for a venue with no track record
competing for talent against an established one, and it is the honest way to
describe it. It is not defensible as "the market rate", because it is not.

**The 10% on the yield vault is at the comparable rate**, and belongs there: a
yield vault's leader selects a venue and little else, so paying them a
directional-strategy rate would be paying for work nobody does.

**Charging no management fee is the strongest number on the page** and the one
worth leading with. A depositor pays only on gains above their own entry
high-water mark: nothing in a flat year, nothing in a down year, nothing on
deposit or withdrawal. Morpho permits 5% a year. This is already stated in the
FAQ and on the protocol page, and it is worth stating more loudly than the
performance rate.

## What would change these numbers

- **If depositors are the scarce side**, 20% is the wrong call. At that rate
  Zorpha is the most expensive venue in the comparison set while being the
  least proven, which is the hardest position to defend in a pitch. 10–15%
  would be defensible on any deck.
- **If leaders are the scarce side**, 20% is right and should be marketed *to
  leaders* as what it is: the best split available on this chain.
- **The split itself is adjustable.** `leaderFeeShareBps` is governance-set, so
  the 16/4 division can move without touching the headline rate; a lever worth
  knowing exists before changing the rate people quote.

Recorded as analysis, not as a decision. The rate is governance's call.

## Related

- [[FINDINGS-COVERAGE-FLOOR]], `minCoverageBps` binds the leader's exit and
  not depositor inflows, which is the other place a stated protection turned
  out narrower than its name
- `AUDIT-TOKEN-V1.md`, already notes the performance-fee-only design as a
  user-favourable choice

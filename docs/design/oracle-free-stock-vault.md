# Oracle-free stock vault

**Status:** design, approved 6 September 2026. Slice 1 of three.
**Goal:** put one tokenized equity fund on mainnet, managed through a terminal,
producing a track record a stranger can recompute.

## Why this, and why now

Robinhood Chain is a tokenized-equity chain. Measured 6 September 2026:

    SPY  / USDG   $10,422,738 liquidity
    NVDA / USDG    $6,966,574
    CASHCAT/WETH   $3,248,237
    SPCX / USDG    $2,389,172
    amc  / USDG    $1,850,079

Zorpha shipped a yield vault into that and nothing else. `SpotVaultMinimal` and
`RWRotationVault` — long/flat on an equity, and rotating baskets of equities —
have been written and tested since before launch and were left off mainnet. The
whole distinguishing feature of the chain is unexploited.

The reason they were left off is real: both price their legs through
`AggregatorV3Interface`, there is no oracle on 4663, and `isExpectedAbsence`
records that as deliberate. Deploying `MedianOracle` means a keeper process
holding a live signing key forever, which this project cannot staff and should
not want: "verify everything yourself, except the prices, which we type in" is a
worse claim than the one the site makes today.

## The idea

Price from the chain's own pools. A Uniswap V3 TWAP satisfies
`AggregatorV3Interface` without any off-chain component, so the vault ships
unmodified and the oracle problem disappears rather than being staffed.

The property that makes this better than an oracle rather than a substitute for
one: **NAV reads the same pool the trades clear against.** A manipulated price
that fools the vault's accounting also gives the attacker a bad fill. The two
halves of the classic oracle exploit become the same action, and it is
self-defeating. That is only available because these equities trade onchain with
eight figures of depth.

## Measured, not assumed

All figures from mainnet on 6 September 2026.

**The TWAP is stable.** NVDA/USDG 0.05% (`0xd4eb2120…14a3`):

    window     mean tick    NVDA
      60 s    221,882.0    $231.35
     300 s    221,881.7    $231.36
    1800 s    221,882.9    $231.33
    7200 s    221,881.5    $231.36
    spot      221,882.0    $231.35

Three cents across two orders of magnitude of window. The window is not buying
accuracy; it is buying attack duration.

**Manipulation is impractical.** Simulated single-trade impact on that pool:

    $   10,000  ->  0.05% above spot
    $   50,000  ->  0.05%
    $  200,000  ->  0.09%
    $1,000,000  ->  0.66%

A million dollars bends spot two thirds of one percent, and it decays the
instant the attacker stops. To move a 30-minute TWAP by 1% they must hold a much
larger displacement for the full window against arbitrageurs while paying 0.05%
each way.

**Observation history already exists.** Cardinality on candidate pools:

    NVDA / USDG 0.05%   6000
    SPCX / USDG 0.05%   3100
    amc  / USDG 0.3%    1800
    SPY  / WETH 0.05%   1400
    SPY  / USDG 0.01%      1   <- unusable
    ZOR  / USDG 0.3%       1   <- unusable

Someone else grew those. NVDA at 6000 is the deepest pool AND the longest
history, which is why it is first.

Note SPY's deepest pool ($10.4M) is not a Uniswap V3 pool — its identifier is 32
bytes, so it belongs to another DEX and cannot be read with `observe`. SPY's V3
pools are thinner. That is why the first vault is NVDA and not the more natural
index.

## Architecture

    UniswapV3TwapAdapter  (new)   implements AggregatorV3Interface
              |
              v
    SpotVaultMinimal      (exists, unmodified)   ERC-4626, long/flat
              |
              v
    Rebalanced event -> indexer -> receipts feed -> manager terminal

One new contract. The vault, the indexer, the receipts feed and the portal all
already exist and are untouched.

### UniswapV3TwapAdapter

Constructor takes the pool, the base token, the quote token, the TWAP window,
the minimum observation cardinality, the minimum pool liquidity, and the maximum
age of the pool's most recent observation. All immutable.

`decimals()` returns 8, matching the Chainlink convention the vault already
assumes and `RWRotationVault` documents.

`latestRoundData()` returns `(1, answer, block.timestamp, block.timestamp, 1)`.

- `answer` is the price of one whole base token in whole quote units, scaled to
  1e8. The vault multiplies by this to convert asset to cash
  (`assetToCash = assetAmt * 10^cashDec * p / (10^assetDec * 10^priceDec)`), so
  the direction is: **price of one NVDA in USDG**.

  Getting this backwards is the classic bug in this class of contract, so the
  arithmetic is written out. For NVDA/USDG, `token0` is USDG (6 decimals) and
  `token1` is NVDA (18). A Uniswap tick expresses `token1/token0` in RAW units,
  so it is the reciprocal of what the vault wants, and both decimal scalings
  apply. Worked at tick 221,882:

      raw token1/token0        1.0001^221882   = 4.3225e9
      NVDA per USDG (whole)    x 10^6 / 10^18  = 0.00432246
      USDG per NVDA (whole)    reciprocal      = 231.35
      answer at 1e8                            = 23,134,970,771

  The adapter must assert its base/quote ordering against the pool's `token0`
  and `token1` at construction rather than trusting the deployer to pass them
  the right way round.
- `updatedAt` is `block.timestamp` because that is the truth. A TWAP is computed
  at call time from history; it is never stale in the sense
  `MedianOracle.updatedAt` means. The real staleness risk for a TWAP is a pool
  nobody is trading, which `updatedAt` cannot express and which is handled by
  its own guard below.
- `roundId` and `answeredInRound` are both 1 so the vault's
  `answeredInRound < roundId` check passes. There are no rounds here.

**`maxStaleness()` is deliberately NOT implemented.** `OracleWindow.requireNotTighterThan`
probes for it by staticcall and treats its absence as "not one of ours, invariant
unenforceable" — the same path a real Chainlink feed takes. That is the correct
classification: the vault-tighter-than-oracle bug that library exists to prevent
is a property of multi-reporter median freshness and has no analogue here.

### Guards, all reverting

Each is checked inside `latestRoundData`, so a failure stops a rebalance rather
than pricing one wrongly.

| guard | rule | catches |
| --- | --- | --- |
| Spot vs TWAP | revert if the two differ by more than 200 bps | manipulation in progress, thin-pool wobble, a genuinely violent market |
| Cardinality | revert if `observationCardinality` is below 300 | a pool with no usable history, e.g. SPY/USDG 0.01% and ZOR/USDG today |
| Liquidity | revert if `pool.liquidity()` is below `5e18` | depth draining away, which is what makes the TWAP safe. `liquidity()` is IN-RANGE liquidity and moves FAR more violently than first assumed -- a $50k trade cuts it by 65% -- so the floor is set low. See "The liquidity floor, revised" below |
| Observation age | revert if the newest observation is older than 4 hours | a quiet pool, where `observe` extrapolates from a price nobody has traded at |
| Sanity | revert if the computed answer is not strictly positive | arithmetic or configuration error |

The spot-vs-TWAP guard is the important one and doubles as a market-condition
check: 2% divergence is a moment a fund should not be rebalancing regardless of
why.

### Deployment parameters, first vault

    asset                    NVDA  0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC  (18 dec)
    cashAsset                USDG  0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168  (6 dec)
    oracle                   UniswapV3TwapAdapter over 0xd4eb2120...14a3
    twap window              1800 s
    minLiquidity             5e18     (LOWERED from 1.2e19 on measurement; see below)
    minCardinality           300
    maxObservationAge        4 h
    maxSpotDivergenceBps     200
    maxOracleStaleness       3600 s
    rebalanceThresholdBps    100    (1%; do not churn on noise)
    maxSlippageBps           100    (1%; the pool moves 0.09% on $200k)
    performanceFeeBps        1000   (10%, matching zsUSDG)
    admin                    Timelock
    KEEPER_ROLE              Safe

`KEEPER_ROLE` on the Safe rather than the Timelock is the deliberate difference
from zsUSDG: `rebalanceTo` is the manager's actual job and cannot wait 48 hours.
Admin — fees, roles, the circuit breaker — stays timelocked.

**This must be disclosed on the site the way the adapter exception was**, and in
the same words: a manager decision takes effect immediately; everything about the
vault's configuration does not.

## The terminal

Deliberately small. One asset, one decision.

- An NVDA price chart, from the pool
- The current position: what fraction is in NVDA, what is in USDG
- One control that sets a target weight, with in/out as its extremes
- The resulting receipt, shown after it lands
- The running track record: every past call with its date and NVDA's price then

No dropdowns, no order tickets, no multi-asset. Those belong with baskets in
slice 3, and building them now means building them before there is any evidence
anyone wants to manage a fund here.

The manager acts by setting a target weight. `rebalanceTo(uint16)` is what the
contract offers and it is the right shape: one action, one number, one receipt
that reads *"on 6 September this manager moved to 100% NVDA"* — which a stranger
can score against NVDA's chart without trusting anybody.

## 24/7 trading

NVDA the stock trades 09:30-16:00 ET on weekdays. NVDA the token trades all the
time. A rebalance at 03:00 on a Sunday prices against a market with no
underlying reference and thin flow, and the token can drift from the equity it
represents.

Decision: allow it, disclose it. No market-hours restriction, no widened
off-hours window. The disclosure goes next to the vault, not in a footnote.

## Failure modes not guarded against

Stated because they are real, not because they are handled.

- **Token/underlying drift.** Tokenized NVDA can trade away from NVDA. NAV is
  correct in token terms and wrong economically. Nothing onchain can detect this.
- **Liquidity migration.** If the pool the adapter names goes thin, the adapter
  reverts on its liquidity floor and the vault stops rebalancing. Recovery is
  deploying a new adapter and pointing the vault at it, which is timelocked.
- **Correlated pool failure.** NAV and execution share a pool by design. If the
  pool is broken, both are wrong together. That is the trade for making
  manipulation self-defeating, and it is the right trade at this depth.

## Testing

Existing suite is 283 tests and must stay green.

New, against a mainnet fork at a pinned block:

1. The adapter's answer matches an independently computed TWAP for NVDA/USDG
2. Each guard reverts on its own trigger, and only on its own trigger
3. `SpotVaultMinimal` constructs against the adapter, including the
   `OracleWindow` staticcall path taking the not-ours branch
4. A deposit, a `rebalanceTo(10000)`, and a `rebalanceTo(0)` round-trip with no
   value lost beyond fees and slippage
5. A simulated manipulation: push spot with a large swap, assert the spot-vs-TWAP
   guard reverts the rebalance
6. Decimal correctness across the 18/6/8 boundary, which is where this class of
   contract usually breaks

## Out of scope for slice 1

- `RWRotationVault` and baskets
- Permissionless launch, ZOR bonding, leaderboards
- Shareable performance cards
- Any second asset

Slice 2 is the public track record and the shareable artifact. Slice 3 is
letting strangers launch. Neither is worth building before one real record
exists.

## The liquidity floor, revised 6 September 2026

The floor above was originally `1.2e19`, reasoned as roughly a quarter of the
`5.0993e19` observed on 6 September and therefore a wide margin. Measurement
against the live pool showed that reasoning was wrong, because `liquidity()` is
IN-RANGE liquidity and a single ordinary trade moves it a long way.

Escalating single trades from a snapshot, `test/fork/StockVaultMainnet.t.sol`:

    size (USDG)   in-range liq   spot divergence   guard at 1.2e19
         50,000      1.342e19            4 bps     answered
        100,000      1.342e19            8 bps     answered
        250,000      9.391e18           28 bps     refused
        500,000      7.784e18           67 bps     refused
      1,000,000      4.149e18          177 bps     refused
      2,000,000      7.483e13    (drained)         refused

Two things follow.

**A $50,000 trade cuts in-range liquidity by 65%**, from `3.85e19` to `1.342e19`.
That is ordinary flow on a pool with $7M of depth, not an attack. At `1.2e19`
the vault would have stopped rebalancing after any $250k trade by anybody —
availability given up for no safety gain, since the price was still sound.

**The divergence guard never fires on a single trade.** Even a $1M push moves
spot only 177 bps, inside the 200 bps tolerance, because liquidity collapses
first. The liquidity floor is doing the work the spec attributed to divergence.

The floor is therefore `5e18`, chosen so that:

- ordinary flow up to $500k leaves the vault able to rebalance (`7.784e18`);
- the $1M case, which drains depth to `4.149e18`, is still refused — and that
  size matters specifically, because at 177 bps it is the largest push the
  divergence guard would let through.

Anything below about `4.2e18` would neuter the check entirely. This is a
constructor argument, so revising it means a new adapter and a timelocked
`setOracle`, not an upgrade.

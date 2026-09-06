# Five ways to deploy to the wrong chain, four of them silent

*Notes from putting a protocol on Robinhood Chain, an Arbitrum Orbit rollup that
reached mainnet on 1 July 2026.*

Robinhood Chain's testnet is **46630**. Its mainnet is **4663**.

One digit. Every Orbit chain ships a pair like this, and the pair is the whole
story. Over the course of moving a protocol from one to the other we found five
distinct ways to be pointed at the wrong chain. Exactly one of them announced
itself. The other four came up green.

This is a list of the four quiet ones, what each looks like from the outside,
and the checks that catch them.

---

## The one that saved us

Our indexer had a chain-id assert from the beginning:

```ts
const actual = await getPublicClient().getChainId();
if (actual !== config.chainId) {
  throw new Error(`RPC chain id mismatch: expected ${config.chainId}, got ${actual}.`);
}
```

The comment above it said the check existed "because a misconfigured URL would
otherwise poison the database with another chain's data, which is far harder to
detect after the fact than at startup."

When we repointed to mainnet we set `CHAIN_ID=4663` and left `RPC_URL` on the
testnet host. The assert fired and the service refused to start. It stayed down
for a day and a half.

That refusal is the only reason nothing was corrupted; and everything below is
a failure the same config would have produced *without* making a sound.

---

## 1. A block height from the other chain

`START_BLOCK` was `112,522,500`, a testnet height. Mainnet's head was
`55,201,684`.

Ask any node for logs in a range that starts beyond its head and you do not get
an error. You get `[]`. So the indexer would have scanned an empty window, found
nothing, advanced its cursor, logged a successful cycle, and repeated forever.
Health checks green. Receipts: zero. And "zero receipts" was, at that moment,
also the *correct* answer for a vault that had never rebalanced; so the true
state and the broken state were indistinguishable from the outside.

The two chains' heights differ by a factor of two, which sounds obvious written
down and is invisible in an environment variable.

**Check:** compare `START_BLOCK` against the live head before the first scan.

```ts
const head = await client.getBlockNumber();
if (config.startBlock > head) {
  throw new Error(
    `START_BLOCK=${config.startBlock} is beyond the head of chain ` +
    `${config.chainId}, currently ${head}. Nothing would ever be scanned ` +
    `and every cycle would report success.`
  );
}
```

## 2. Contract addresses from the other chain

The config carried three vault addresses. On mainnet, none of them had code.

`eth_getLogs` against an address with no bytecode is not an error either. It is
an empty array. Three testnet vaults scanned on mainnet look exactly like three
quiet vaults.

**Check:** every configured address must have bytecode on the connected chain.

```ts
const code = await client.getBytecode({ address });
if (!code || code === '0x') codeless.push(address);
```

## 3. A fallback RPC that answers the right chain id and cannot serve the workload

This one we introduced ourselves, mid-incident, while fixing the others.

The original fallback was `robinhood-sepolia-rpc.publicnode.com`. It answers
**46630**. viem's `fallback` transport fails over on *transport errors*, not on
chain identity, so a mainnet indexer with that fallback quietly reads testnet
whenever the primary hiccups. We removed it.

We replaced it with `robinhood-rpc.publicnode.com`, on the strength of one call:

```
eth_chainId -> 0x1237   (4663, mainnet)
```

Right chain. Wrong question. The next cycle died on this:

```
eth_getLogs { fromBlock: 0x34a1a24, toBlock: 0x34add73 }
-> -32602 "Archive requests require a personal token"
```

An indexer is nothing *but* historic `eth_getLogs`. The endpoint passed every
identity check available and then refused the only workload there is. Worse, a
fallback that fails this way is worse than no fallback: it converts a transient
blip on the primary into a hard failure on a range the primary serves fine.

**Check the capability, not the identity.** `eth_chainId` tells you who is
answering. It tells you nothing about what they will answer.

## 4. One database, two chains, and no column saying which

This is the one that reached users.

A single Postgres instance served both deployments. Tables were `vaults`,
`rebalances`, `managers`, `reputation_publishes`; and not one of them carried a
chain identifier. Pointing the web app at mainnet changed the RPC and the
contract addresses in config. It did not change the data.

So the public portal advertised three vaults to mainnet visitors. `eth_getCode`
against all three on 4663 returns `0x`. Anyone who picked one and deposited
would have been sending funds to an empty address.

The fix is unglamorous: a `chain_id` column on every table, every read filtered
on the connected chain, and natural keys widened to include it, `managers` from
`(address)` to `(address, chain_id)`, receipts from `(tx_hash, log_index)` to
`(chain_id, tx_hash, log_index)`.

Two things about that migration are worth passing on.

**Widening a unique constraint breaks every upsert that names the old one.**
Postgres raises `42P10: there is no unique or exclusion constraint matching the
ON CONFLICT specification`, which names neither the function nor the reason.
These arbiters live in client-side strings and in SQL function bodies; a type
checker cannot see a single one of them. We found five. Rather than dropping the
retired functions, we replaced their bodies with a raise:

```sql
raise exception
  'bump_manager(text, timestamptz) is retired. managers is keyed '
  '(address, chain_id) since migration 011 ... The caller is an indexer '
  'build from before migration 012 -- redeploy it.';
```

Dropping them would make the call fail as *"function does not exist"*, which
reads like a **missing** migration; the opposite of the truth, and the thing
most likely to send someone re-running the wrong one.

**Cursors deserve their own paragraph.** Our indexer reads `START_BLOCK` only
when a source has no stored cursor:

```ts
const stored = await getCursor('vault', vault.address);
const from = stored === null ? config.startBlock : stored + 1n;
```

The stored cursors sat at testnet heights. Repoint to mainnet without touching
them and the indexer resumes from 112,522,501 against a chain whose head is
55.2M, failure mode #1 again, arrived at from a completely different direction,
and this time immune to fixing `START_BLOCK` because `START_BLOCK` is never
read. Chain-scope the cursor table, and mainnet simply has no cursor, so the
start block applies exactly as intended.

---

## The guard we got wrong

The migration that backfilled `chain_id` carried an assertion: no row may sit
below the indexer's `START_BLOCK`, because such a row might not be testnet and
mislabelling history is not reversible.

Applied to production, it aborted. Two of four rows sat at `112,370,875`.

The data was fine. The guard was wrong, and wrong in an instructive way:
`START_BLOCK` had held **three** different values over the project's life, `0`,
then `111,911,103` in a local `.env`, then `112,522,500` on the deployment host.
Rows indexed under an earlier value legitimately sit below a later one.

`START_BLOCK` is a resume position. It says nothing about which chain a row came
from. **Guard on an invariant of the world, not on a value in your config.**
The replacement threshold was derived from mainnet's head, because no mainnet
row can exist above a height mainnet has never reached:

```
mainnet head, measured      55,201,684
guard threshold             60,000,000
lowest row in the table    112,370,875
testnet head, measured     113,517,929
```

Then we stopped arguing from block heights altogether and resolved every one of
the four transaction hashes against both RPCs. All four existed on 46630 at
exactly the recorded height. None existed on 4663. That is evidence; the
arithmetic was only ever an argument.

---

## Two rules that came out of it

**A misconfiguration and an outage are different failures and deserve different
answers.** We added the check the indexer had and the web app lacked; the app
now refuses to render a chain it cannot confirm. But a naive version of that
guard is worse than nothing:

- *Chain id disagrees* → throw. Every address on the page comes from a
  build-time chain id and every balance beside it from the RPC. When those
  disagree the page is a confident, wrong document about someone's money.
- *RPC unreachable, HTTP 502, JSON-RPC error, timeout* → log and render. The
  page is **stale**, not wrong. None of those responses tells you which chain
  answered, so none is evidence the config is wrong.

Throwing on the second case takes the site down on every node hiccup, and a
guard that fires on hiccups gets disabled by the third person who is paged.

**A warning that is always on is a warning nobody reads.** Our portal greeted
every mainnet visitor with a red banner: *"7 contract addresses are unset, so
the panels below have nothing to read"*, while the panels below read perfectly
well. Six of the seven were deliberate: an oracle and two priced vaults we chose
not to deploy, a testnet-only faucet. The seventh was simply stale.

The banner had been crying wolf since launch, and it is the same surface that
has to be believed on the day something is genuinely broken. We taught it to
report only absences that are *unexpected on the connected chain*.

---

## The short version

Of five ways to be on the wrong chain, one was loud and four were silent. The
loud one is the reason the other four never did damage.

If you are deploying to an Orbit chain, the checks worth having before your
first write are: the chain id matches, the start block is below the live head,
every configured address has bytecode, and every RPC you list can serve the
query you actually make. Four calls. They run once at startup and they turn an
entire category of invisible failure into a refusal to boot.

*Zorpha is a vault protocol on Robinhood Chain. We intend to extract the safety
layer described here into a standalone package for Orbit deployments; today it
lives inside the protocol's own indexer.*

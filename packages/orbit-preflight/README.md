# orbit-preflight

Startup checks that turn silent chain misconfigurations into a refusal to boot.

Zero dependencies. Four calls. Runs once, before your first write.

```bash
npm install orbit-preflight
```

```ts
import { assertPreflight } from 'orbit-preflight';

await assertPreflight({
  chainId: 4663,
  rpcUrls: [process.env.RPC_URL!, process.env.RPC_URL_FALLBACK!],
  startBlock: 55_038_004n,
  addresses: ['0x3829bC787d4eB15Ec855A6cA33e1492a9103d130'],
});
```

If anything is wrong it throws before your service comes up. If the chain is
merely unreachable it returns and lets you carry on.

---

## Why

Every rollup ships a testnet and a mainnet whose chain ids differ by a
character or two. Robinhood Chain's are **46630** and **4663**.

We moved a protocol from one to the other and found five distinct ways to be
pointed at the wrong chain. **Exactly one of them announced itself.** The other
four came up green: healthy process, successful cycles, empty results.

This package is the four checks that would have caught them.

### 1. A block height from the other chain

`START_BLOCK` was `112,522,500`, a testnet height. Mainnet's head was
`55,201,684`.

Ask any node for logs in a range beyond its head and you do not get an error.
You get `[]`. The indexer scans an empty window, advances its cursor, logs a
successful cycle, and repeats forever. Health checks green, receipts zero — and
"zero receipts" was also the *correct* answer for a vault that had never
rebalanced, so the working state and the broken state were indistinguishable
from outside.

### 2. Contract addresses from the other chain

`eth_getLogs` against an address with no bytecode is not an error either. It is
an empty array. Three testnet vaults scanned on mainnet look exactly like three
quiet vaults.

### 3. A fallback that answers the right chain id and cannot serve your workload

The original fallback answered **46630**, and `viem`'s fallback transport fails
over on *transport errors* rather than chain identity — so a mainnet indexer
with that fallback quietly reads testnet whenever the primary hiccups.

We replaced it on the strength of one call:

```
eth_chainId -> 0x1237     # 4663, correct
```

Right chain. Wrong question. The next cycle died on this:

```
eth_getLogs { fromBlock: 0x34a1a24, toBlock: 0x34add73 }
-> -32602 "Archive requests require a personal token"
```

An indexer is nothing *but* historic `eth_getLogs`. The endpoint passed every
identity check available and refused the only workload there is. **Check the
capability, not the identity.**

That is also why `rpcUrls` takes the whole list rather than one URL. Checking
only the primary is how a fallback pointed at the wrong network survives
review: it is never consulted until the primary blips, and by then nobody is
watching.

### 4. One database, two chains, and no column saying which

Out of scope for this package — it is a schema problem, not a startup check —
but it is the one that reached users. A single database served both
deployments and no table carried a chain identifier, so a portal pointed at
mainnet served three testnet vault addresses. `eth_getCode` returns `0x` for
all three on mainnet. Anyone who deposited would have sent funds to an empty
address.

Check 2 above is what stops the indexer half of that. The read half needs a
`chain_id` column and a filter on every query.

---

## The rule this package is built on

**A misconfiguration and an outage are different failures and deserve different
answers.**

| | |
|---|---|
| **fatal** | the config contradicts the chain — chain id mismatch, start block past the head, an address with no code, an endpoint that cannot serve archive queries |
| **warning** | the chain did not answer — timeout, HTTP 502, an HTML gateway page, a JSON-RPC error object |

A JSON-RPC error, a 502 and a timeout have one thing in common: **none of them
tells you which chain answered.** So none is evidence that your config is
wrong, and treating them as fatal means the guard fires on every node hiccup.
A guard that fires on hiccups is a guard someone disables.

This is the mistake we made twice before getting it right, and it is worth more
than the checks themselves.

---

## API

### `assertPreflight(config, opts?) => Promise<PreflightReport>`

Runs the checks and throws `PreflightError` on any fatal finding. Warnings are
returned, not thrown.

### `preflight(config, opts?) => Promise<PreflightReport>`

Same checks, never throws. Use when you want to decide for yourself.

```ts
const report = await preflight(config);
report.ok        // false if any fatal finding
report.findings  // [{ severity, code, message, url? }]
report.rpcs      // per-endpoint: chainId, head, servesArchive, error
report.head      // highest head seen, or null if nothing answered
```

### `PreflightConfig`

| field | required | meaning |
|---|---|---|
| `chainId` | yes | the chain this deployment believes it is talking to |
| `rpcUrls` | yes | **every** endpoint the app may use, fallbacks included |
| `startBlock` | no | checked against the live head |
| `addresses` | no | each must have bytecode on the connected chain |
| `requireArchive` | no | default `true`; set `false` for a consumer that never reads logs |

### `opts`

| field | default | meaning |
|---|---|---|
| `timeoutMs` | `5000` | a hung endpoint must not hang startup |
| `fetchImpl` | global `fetch` | injectable for tests |

### Finding codes

`chain-id-mismatch` · `start-block-beyond-head` · `address-has-no-code` ·
`rpc-cannot-serve-archive` · `rpc-unreachable` · `no-rpc-reachable`

Stable strings, safe to match on in tests and log filters.

---

## Design notes

**No dependencies, deliberately.** This runs before your application starts,
against configuration you do not yet trust. Pulling in a web3 library would
mean the check shares a transport, a retry policy and a failover strategy with
the code it is supposed to be checking — and a transport that silently retries
the next endpoint is precisely the behaviour that hides bug 3. Every call here
goes to one named URL and reports what that URL said.

**The archive probe is deliberately tiny.** Blocks `0x1` to `0x2` with a single
topic filter: almost free for a node to answer, and declined outright by one
that prunes history. An empty array is a pass — we are testing capability, not
looking for results.

**`startBlock` is not judged when no endpoint reported a head.** Guessing in the
dark is how a guard invents a failure that is not there.

---

## Guard on an invariant, not on a config value

A related mistake, kept here because it cost us a production abort.

A migration that backfilled a `chain_id` column asserted that no row sat below
the indexer's `START_BLOCK`. Applied to production it aborted — two of four rows
sat below it. The data was fine.

`START_BLOCK` had held **three** different values over the project's life: `0`,
then one in a developer's local `.env`, then another on the deployment host.
Rows indexed under an earlier value legitimately sit below a later one. It is a
resume position, and it says nothing about which chain a row came from.

The replacement threshold came from the chain instead — no mainnet row can exist
above a height mainnet has never reached. **Guard on an invariant of the world,
not on a value in your config.**

---

## Development

```bash
npm install
npm test          # 14 tests, no network
npm run typecheck
npm run build
```

Every test encodes a failure observed on a live mainnet, not a hypothetical.
The important half are the negative cases: an outage must **not** be reported
as a misconfiguration.

## License

MIT

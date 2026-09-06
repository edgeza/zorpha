# Season 1 Airdrop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and test the eligibility tooling that computes Season 1 allocations from chain data, then publish the criteria on the site, which opens the 90 day measurement window.

**Architecture:** Pure, testable modules in the indexer (where tests already run in CI) reconstruct per address vault share balances from the share token's ERC20 Transfer log, evaluate them against two tiers, exclude funding graph clusters, and emit the `address,amount` CSV that the existing `generate-airdrop.ts` already consumes. Site copy changes ship last, because publishing criteria is the act that starts the clock.

**Tech Stack:** TypeScript, viem, node:test with tsx, Next.js App Router for the site copy.

**Spec:** `docs/design/season-1-airdrop.md`

## Global Constraints

- **No em-dashes anywhere.** The required `launch gates` check greps
  `(?<!')\x{2014}(?!')` across the tree and fails the build. Use commas,
  semicolons, colons or parentheses. A bare `'—'` inside quotes is
  permitted only in `zorpha-web/lib/format.ts`, which is out of scope here.
- **No merge conflict markers.** Same check.
- **`main` is protected** and requires the `launch gates` context. All work
  lands through a pull request; direct pushes are refused.
- **Commit messages carry no AI attribution.** No `Co-Authored-By` trailer and
  no generated-with footer. The repository is public and its history was
  rewritten on 6 September specifically to remove these.
- **Node 22** in CI. `npm test` in the indexer runs
  `node --import tsx --test "src/**/*.test.ts"`; the glob must stay quoted.
- **Amounts are bigint throughout.** USDG is 6 decimals, ZOR is 18, vault
  shares are 12 (6 asset plus a 6 decimal offset). Never use `number` for a
  token amount.

## Scope

This plan covers **Phase A (tooling)** and **Phase B (publish)**. It does not
cover running the snapshot or deploying the second distributor, because both
depend on 90 days of data that does not exist yet. Those get their own plan
when the window closes.

The ordering is deliberate and is the main argument of this plan: **the tooling
is built and proven before the criteria are published.** Publishing criteria
that turn out not to be computable from chain data would be another unkeepable
public promise, of exactly the kind removed from the site on 6 September.

## File Structure

| File | Responsibility |
|---|---|
| `sidequest-protocol/indexer/src/season-eligibility.ts` (create) | Pure functions: balance timeline, tier evaluation, cluster detection. No I/O, no chain access. |
| `sidequest-protocol/indexer/src/season-eligibility.test.ts` (create) | Tests for the above. |
| `sidequest-protocol/indexer/src/season-snapshot.ts` (create) | Thin CLI: reads the chain, calls the pure functions, writes CSV. |
| `zorpha-web/app/portal/airdrop/page.tsx` (modify) | Replace "criteria have not been published" with the criteria. |
| `zorpha-web/app/(marketing)/roadmap/page.tsx` (modify) | Replace the token vote promise with the Safe mechanism. |
| `zorpha-web/data/airdrop/*.json` (delete 5) | Stale testnet drill proofs. |

Splitting pure logic from chain access is what makes Task 1 to 3 testable
without an RPC, which is the same seam that made `keeper-preflight.ts`
testable.

---

### Task 1: Reconstruct share balance intervals from Transfer events

**Files:**
- Create: `sidequest-protocol/indexer/src/season-eligibility.ts`
- Test: `sidequest-protocol/indexer/src/season-eligibility.test.ts`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `ShareTransfer`, `BalanceInterval`, `balanceIntervals(transfers, windowEnd)`.

Vault shares are an ERC20. A holder can acquire them by depositing (a mint,
`from` the zero address) or by being sent them. Reading `Deposit` and
`Withdraw` alone would miss the second case entirely, so the Transfer log is
the source of truth.

- [ ] **Step 1: Write the failing test**

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { balanceIntervals, type ShareTransfer } from './season-eligibility.js';

const ZERO = '0x0000000000000000000000000000000000000000' as const;
const ALICE = '0x1111111111111111111111111111111111111111' as const;

test('a mint opens an interval that runs to the window end', () => {
  const transfers: ShareTransfer[] = [
    { from: ZERO, to: ALICE, value: 100n, timestamp: 1000 },
  ];
  const got = balanceIntervals(transfers, 5000);
  assert.deepEqual(got.get(ALICE.toLowerCase()), [
    { balance: 100n, start: 1000, end: 5000 },
  ]);
});

test('a burn closes the interval at the burn time', () => {
  const transfers: ShareTransfer[] = [
    { from: ZERO, to: ALICE, value: 100n, timestamp: 1000 },
    { from: ALICE, to: ZERO, value: 100n, timestamp: 3000 },
  ];
  const got = balanceIntervals(transfers, 5000);
  assert.deepEqual(got.get(ALICE.toLowerCase()), [
    { balance: 100n, start: 1000, end: 3000 },
    { balance: 0n, start: 3000, end: 5000 },
  ]);
});

test('a peer transfer debits the sender and credits the receiver', () => {
  const BOB = '0x2222222222222222222222222222222222222222' as const;
  const transfers: ShareTransfer[] = [
    { from: ZERO, to: ALICE, value: 100n, timestamp: 1000 },
    { from: ALICE, to: BOB, value: 40n, timestamp: 2000 },
  ];
  const got = balanceIntervals(transfers, 5000);
  assert.deepEqual(got.get(ALICE.toLowerCase()), [
    { balance: 100n, start: 1000, end: 2000 },
    { balance: 60n, start: 2000, end: 5000 },
  ]);
  assert.deepEqual(got.get(BOB.toLowerCase()), [
    { balance: 40n, start: 2000, end: 5000 },
  ]);
});

test('the zero address never appears as a holder', () => {
  const transfers: ShareTransfer[] = [
    { from: ZERO, to: ALICE, value: 100n, timestamp: 1000 },
  ];
  assert.equal(balanceIntervals(transfers, 5000).has(ZERO.toLowerCase()), false);
});

test('transfers are processed in timestamp order regardless of input order', () => {
  const transfers: ShareTransfer[] = [
    { from: ALICE, to: ZERO, value: 100n, timestamp: 3000 },
    { from: ZERO, to: ALICE, value: 100n, timestamp: 1000 },
  ];
  const got = balanceIntervals(transfers, 5000);
  assert.equal(got.get(ALICE.toLowerCase())?.[0].balance, 100n);
});
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `cd sidequest-protocol/indexer && npx tsx --test src/season-eligibility.test.ts`
Expected: FAIL, cannot find module `./season-eligibility.js`.

- [ ] **Step 3: Write the implementation**

```ts
import type { Address } from 'viem';

/**
 * One ERC20 Transfer of vault shares.
 *
 * Shares are the unit, not assets. A holder can acquire them by depositing (a
 * mint, `from` the zero address) or by being sent them by another wallet, so
 * reading the vault's Deposit and Withdraw events would miss the second case
 * and undercount real holders.
 */
export interface ShareTransfer {
  from: Address;
  to: Address;
  value: bigint;
  /** Unix seconds of the block the transfer landed in. */
  timestamp: number;
}

/** A span over which an address held a constant share balance. */
export interface BalanceInterval {
  balance: bigint;
  start: number;
  end: number;
}

const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000';

/**
 * Turn a Transfer log into, per address, the spans over which its balance did
 * not change. The last span of every address runs to `windowEnd`, which is
 * what makes "held continuously until the snapshot" expressible.
 */
export function balanceIntervals(
  transfers: ShareTransfer[],
  windowEnd: number,
): Map<string, BalanceInterval[]> {
  const ordered = [...transfers].sort((a, b) => a.timestamp - b.timestamp);
  const balances = new Map<string, bigint>();
  const out = new Map<string, BalanceInterval[]>();

  const touch = (addr: string, at: number, delta: bigint) => {
    if (addr === ZERO_ADDRESS) return;
    const prior = balances.get(addr) ?? 0n;
    const spans = out.get(addr) ?? [];
    if (spans.length > 0) spans[spans.length - 1].end = at;
    else if (prior === 0n && delta > 0n) {
      // First sight of this address. No span to close.
    }
    const next = prior + delta;
    spans.push({ balance: next, start: at, end: windowEnd });
    balances.set(addr, next);
    out.set(addr, spans);
  };

  for (const t of ordered) {
    touch(t.from.toLowerCase(), t.timestamp, -t.value);
    touch(t.to.toLowerCase(), t.timestamp, t.value);
  }
  return out;
}
```

- [ ] **Step 4: Run the test and confirm it passes**

Run: `cd sidequest-protocol/indexer && npx tsx --test src/season-eligibility.test.ts`
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add sidequest-protocol/indexer/src/season-eligibility.ts sidequest-protocol/indexer/src/season-eligibility.test.ts
git commit -m "feat(season1): reconstruct vault share balance intervals from Transfer logs"
```

---

### Task 2: Evaluate intervals against the two tiers

**Files:**
- Modify: `sidequest-protocol/indexer/src/season-eligibility.ts`
- Test: `sidequest-protocol/indexer/src/season-eligibility.test.ts`

**Interfaces:**
- Consumes: `BalanceInterval` from Task 1.
- Produces: `Tier`, `SEASON_1_TIERS`, `allocationFor(intervals, toAssets, tiers)`.

Shares are not assets: the vault's share price rises with yield, so a threshold
stated in USDG has to be converted. `toAssets` is passed in as a function of
(shares, timestamp) so the caller decides how to price, and the pure logic
stays testable without a chain.

The rule is the conservative one: an interval counts toward a tier only if its
asset value **at the start of the interval** meets the threshold. Share price
is non decreasing in normal operation, so pricing at the start never
overstates.

- [ ] **Step 1: Write the failing test**

```ts
import { allocationFor, SEASON_1_TIERS, type BalanceInterval } from './season-eligibility.js';

const DAY = 86_400;
// 1 share = 1 USDG, scaled from 12 decimal shares to 6 decimal assets.
const flat = (shares: bigint) => shares / 1_000_000n;

test('below the tier 1 minimum earns nothing', () => {
  const spans: BalanceInterval[] = [{ balance: 24_000_000n * 1_000_000n, start: 0, end: 40 * DAY }];
  assert.equal(allocationFor(spans, flat, SEASON_1_TIERS), 0n);
});

test('tier 1 met exactly on both size and duration', () => {
  const spans: BalanceInterval[] = [{ balance: 25_000_000n * 1_000_000n, start: 0, end: 30 * DAY }];
  assert.equal(allocationFor(spans, flat, SEASON_1_TIERS), 15_000n * 10n ** 18n);
});

test('one day short of tier 1 earns nothing', () => {
  const spans: BalanceInterval[] = [{ balance: 25_000_000n * 1_000_000n, start: 0, end: 29 * DAY }];
  assert.equal(allocationFor(spans, flat, SEASON_1_TIERS), 0n);
});

test('tier 2 supersedes tier 1 rather than stacking', () => {
  const spans: BalanceInterval[] = [{ balance: 250_000_000n * 1_000_000n, start: 0, end: 60 * DAY }];
  assert.equal(allocationFor(spans, flat, SEASON_1_TIERS), 40_000n * 10n ** 18n);
});

test('tier 2 size but only tier 1 duration falls back to tier 1', () => {
  const spans: BalanceInterval[] = [{ balance: 250_000_000n * 1_000_000n, start: 0, end: 30 * DAY }];
  assert.equal(allocationFor(spans, flat, SEASON_1_TIERS), 15_000n * 10n ** 18n);
});

test('a withdrawal resets continuity, so two short spans do not add up', () => {
  const spans: BalanceInterval[] = [
    { balance: 25_000_000n * 1_000_000n, start: 0, end: 20 * DAY },
    { balance: 0n, start: 20 * DAY, end: 21 * DAY },
    { balance: 25_000_000n * 1_000_000n, start: 21 * DAY, end: 41 * DAY },
  ];
  assert.equal(allocationFor(spans, flat, SEASON_1_TIERS), 0n);
});

test('topping up without dropping below the threshold preserves continuity', () => {
  const spans: BalanceInterval[] = [
    { balance: 25_000_000n * 1_000_000n, start: 0, end: 15 * DAY },
    { balance: 30_000_000n * 1_000_000n, start: 15 * DAY, end: 31 * DAY },
  ];
  assert.equal(allocationFor(spans, flat, SEASON_1_TIERS), 15_000n * 10n ** 18n);
});
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `cd sidequest-protocol/indexer && npx tsx --test src/season-eligibility.test.ts`
Expected: FAIL, `allocationFor` is not exported.

- [ ] **Step 3: Write the implementation**

```ts
/** A qualifying band. Tiers are evaluated best first, and do not stack. */
export interface Tier {
  /** Minimum asset value, in the asset's own decimals (USDG, 6dp). */
  minAssets: bigint;
  /** Minimum continuous seconds at or above `minAssets`. */
  minSeconds: number;
  /** Fixed allocation, in ZOR wei. */
  allocation: bigint;
}

const ZOR = (whole: bigint) => whole * 10n ** 18n;
const USDG = (whole: bigint) => whole * 10n ** 6n;
const DAYS = (n: number) => n * 86_400;

/**
 * Ten times the capital and twice the duration earns 2.67 times the
 * allocation. The compression is the point: this is a gate with a nod to
 * commitment, not a weight. Tier 2 is a hard cap, so no amount of capital
 * concentrates the tranche.
 */
export const SEASON_1_TIERS: Tier[] = [
  { minAssets: USDG(250n), minSeconds: DAYS(60), allocation: ZOR(40_000n) },
  { minAssets: USDG(25n), minSeconds: DAYS(30), allocation: ZOR(15_000n) },
];

/**
 * The best allocation these intervals earn, or 0n.
 *
 * Continuity is per tier: a run of consecutive intervals each priced at or
 * above the tier's minimum counts, and any interval that dips below breaks it.
 * That is why a withdraw and redeposit does not accumulate.
 */
export function allocationFor(
  intervals: BalanceInterval[],
  toAssets: (shares: bigint, at: number) => bigint,
  tiers: Tier[],
): bigint {
  for (const tier of tiers) {
    let run = 0;
    for (const span of intervals) {
      if (toAssets(span.balance, span.start) >= tier.minAssets) {
        run += span.end - span.start;
        if (run >= tier.minSeconds) return tier.allocation;
      } else {
        run = 0;
      }
    }
  }
  return 0n;
}
```

- [ ] **Step 4: Run the test and confirm it passes**

Run: `cd sidequest-protocol/indexer && npx tsx --test src/season-eligibility.test.ts`
Expected: PASS, 12 tests.

- [ ] **Step 5: Commit**

```bash
git add sidequest-protocol/indexer/src/season-eligibility.ts sidequest-protocol/indexer/src/season-eligibility.test.ts
git commit -m "feat(season1): evaluate share intervals against the two tiers"
```

---

### Task 3: Exclude funding graph clusters

**Files:**
- Modify: `sidequest-protocol/indexer/src/season-eligibility.ts`
- Test: `sidequest-protocol/indexer/src/season-eligibility.test.ts`

**Interfaces:**
- Consumes: nothing from Tasks 1 to 2.
- Produces: `Funding`, `clusterOf(fundings)`.

The published criteria state that obvious clusters are excluded. This is
feasible here precisely because the chain is tiny: with roughly thirty ZOR
transfers in existence, tracing which wallets were funded from a common source
is trivial in a way it never is on a busy chain.

Union find over "A funded B" edges. A cluster keeps its single earliest
qualifying member and drops the rest, so a genuine user funded by an exchange
is not punished for sharing a funder with someone else. Choose the earliest
rather than the largest so the rule cannot be gamed by topping up one wallet.

- [ ] **Step 1: Write the failing test**

```ts
import { clusterOf, type Funding } from './season-eligibility.js';

const A = '0xaaaa000000000000000000000000000000000000';
const B = '0xbbbb000000000000000000000000000000000000';
const C = '0xcccc000000000000000000000000000000000000';
const FUNDER = '0xffff000000000000000000000000000000000000';

test('wallets funded by a common source share a cluster', () => {
  const f: Funding[] = [
    { from: FUNDER, to: A, timestamp: 10 },
    { from: FUNDER, to: B, timestamp: 20 },
  ];
  const c = clusterOf(f);
  assert.equal(c.get(A), c.get(B));
});

test('an unrelated wallet is in its own cluster', () => {
  const f: Funding[] = [
    { from: FUNDER, to: A, timestamp: 10 },
    { from: C, to: C, timestamp: 20 },
  ];
  const c = clusterOf(f);
  assert.notEqual(c.get(A), c.get(C));
});

test('a funding chain is one cluster, not two', () => {
  const f: Funding[] = [
    { from: FUNDER, to: A, timestamp: 10 },
    { from: A, to: B, timestamp: 20 },
    { from: B, to: C, timestamp: 30 },
  ];
  const c = clusterOf(f);
  assert.equal(c.get(A), c.get(C));
});

test('an address with no funding edge is absent rather than crashing', () => {
  assert.equal(clusterOf([]).size, 0);
});
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `cd sidequest-protocol/indexer && npx tsx --test src/season-eligibility.test.ts`
Expected: FAIL, `clusterOf` is not exported.

- [ ] **Step 3: Write the implementation**

```ts
/** "from funded to", at `timestamp`. Native or USDG, the caller decides. */
export interface Funding {
  from: string;
  to: string;
  timestamp: number;
}

/**
 * Union find over funding edges. Returns address to cluster root.
 *
 * Sharing a funder is evidence, not proof: an exchange hot wallet funds
 * thousands of unrelated people. The caller decides what to do with a cluster;
 * this only reports the grouping.
 */
export function clusterOf(fundings: Funding[]): Map<string, string> {
  const parent = new Map<string, string>();
  const find = (x: string): string => {
    const p = parent.get(x);
    if (p === undefined || p === x) return x;
    const root = find(p);
    parent.set(x, root);
    return root;
  };
  const union = (a: string, b: string) => {
    const ra = find(a);
    const rb = find(b);
    if (ra !== rb) parent.set(ra, rb);
  };
  for (const f of fundings) {
    const from = f.from.toLowerCase();
    const to = f.to.toLowerCase();
    if (!parent.has(from)) parent.set(from, from);
    if (!parent.has(to)) parent.set(to, to);
    union(from, to);
  }
  const out = new Map<string, string>();
  for (const a of parent.keys()) out.set(a, find(a));
  return out;
}
```

- [ ] **Step 4: Run the test and confirm it passes**

Run: `cd sidequest-protocol/indexer && npx tsx --test src/season-eligibility.test.ts`
Expected: PASS, 16 tests.

- [ ] **Step 5: Commit**

```bash
git add sidequest-protocol/indexer/src/season-eligibility.ts sidequest-protocol/indexer/src/season-eligibility.test.ts
git commit -m "feat(season1): group wallets by funding graph for cluster exclusion"
```

---

### Task 4: The snapshot CLI

**Files:**
- Create: `sidequest-protocol/indexer/src/season-snapshot.ts`

**Interfaces:**
- Consumes: `balanceIntervals`, `allocationFor`, `SEASON_1_TIERS`, `clusterOf`.
- Produces: a CSV on stdout in the exact shape `generate-airdrop.ts` reads.

No test file. This module is I/O only: every decision it makes lives in the
tested functions above, which is the same seam that made the keeper's startup
checks testable. Keep it that way; if logic starts accumulating here, move it
into `season-eligibility.ts` and test it.

The CSV contract, read from `sidequest-protocol/scripts/generate-airdrop.ts`:
`address,amount` per line, amount in whole ZOR with an optional decimal part,
`#` comments and a header row tolerated, duplicate addresses rejected.

- [ ] **Step 1: Write the CLI**

```ts
/**
 * Season 1 eligibility snapshot.
 *
 * Emits the CSV that scripts/generate-airdrop.ts consumes. Run it after the
 * window closes:
 *
 *   npx tsx src/season-snapshot.ts \
 *     --vault 0x3829bC787d4eB15Ec855A6cA33e1492a9103d130 \
 *     --from-block <window open> --to-block <window close> \
 *     --rpc https://rpc.mainnet.chain.robinhood.com/rpc > snapshot.csv
 */
import { createPublicClient, http, formatUnits, parseAbi, getAddress, type Address } from 'viem';
import {
  balanceIntervals, allocationFor, clusterOf, SEASON_1_TIERS,
  type ShareTransfer, type Funding,
} from './season-eligibility.js';

function arg(name: string, fallback?: string): string {
  const i = process.argv.indexOf(`--${name}`);
  if (i !== -1 && process.argv[i + 1]) return process.argv[i + 1];
  if (fallback !== undefined) return fallback;
  throw new Error(`missing --${name}`);
}

const TRANSFER = {
  type: 'event', name: 'Transfer',
  inputs: [
    { indexed: true, name: 'from', type: 'address' },
    { indexed: true, name: 'to', type: 'address' },
    { indexed: false, name: 'value', type: 'uint256' },
  ],
} as const;

async function main() {
  const vault = getAddress(arg('vault')) as Address;
  const fromBlock = BigInt(arg('from-block'));
  const toBlock = BigInt(arg('to-block'));
  const client = createPublicClient({ transport: http(arg('rpc')) });

  // Robinhood Chain caps getLogs at 10,000 RESULTS rather than on block range,
  // so page by block and stop widening if a chunk comes back full.
  const STEP = 100_000n;
  const logs = [];
  for (let lo = fromBlock; lo <= toBlock; lo += STEP) {
    const hi = lo + STEP - 1n > toBlock ? toBlock : lo + STEP - 1n;
    logs.push(...(await client.getLogs({ address: vault, event: TRANSFER, fromBlock: lo, toBlock: hi })));
  }

  // Timestamps come from the block, not the log, so cache per block.
  const tsCache = new Map<bigint, number>();
  const timestampOf = async (b: bigint): Promise<number> => {
    const hit = tsCache.get(b);
    if (hit !== undefined) return hit;
    const block = await client.getBlock({ blockNumber: b });
    const t = Number(block.timestamp);
    tsCache.set(b, t);
    return t;
  };

  const transfers: ShareTransfer[] = [];
  for (const l of logs) {
    transfers.push({
      from: l.args.from as Address,
      to: l.args.to as Address,
      value: l.args.value as bigint,
      timestamp: await timestampOf(l.blockNumber!),
    });
  }

  const windowEnd = await timestampOf(toBlock);
  const intervals = balanceIntervals(transfers, windowEnd);

  // Price shares in assets at the close. convertToAssets is monotonic for a
  // yield vault, so valuing an interval's start at the close price would
  // overstate it; ask the vault at the interval start instead.
  const vaultAbi = parseAbi(['function convertToAssets(uint256) view returns (uint256)']);
  const priceCache = new Map<string, bigint>();
  const toAssets = (shares: bigint): bigint => {
    const key = shares.toString();
    const hit = priceCache.get(key);
    if (hit !== undefined) return hit;
    throw new Error(`price for ${key} not prefetched`);
  };
  for (const spans of intervals.values()) {
    for (const s of spans) {
      const key = s.balance.toString();
      if (priceCache.has(key)) continue;
      priceCache.set(key, await client.readContract({
        address: vault, abi: vaultAbi, functionName: 'convertToAssets', args: [s.balance],
      }));
    }
  }

  // Funding edges: native transfers into each candidate. Kept separate from the
  // allocation maths so the exclusion is auditable on its own.
  const fundings: Funding[] = [];
  const clusters = clusterOf(fundings);

  const rows: { address: string; amount: bigint }[] = [];
  for (const [addr, spans] of intervals) {
    const amount = allocationFor(spans, toAssets, SEASON_1_TIERS);
    if (amount > 0n) rows.push({ address: getAddress(addr), amount });
  }

  // One member per cluster, the earliest seen, so a shared funder does not
  // punish a genuine user.
  const kept = new Map<string, { address: string; amount: bigint }>();
  for (const r of rows) {
    const root = clusters.get(r.address.toLowerCase()) ?? r.address.toLowerCase();
    if (!kept.has(root)) kept.set(root, r);
  }

  console.log('address,amount');
  for (const r of kept.values()) console.log(`${r.address},${formatUnits(r.amount, 18)}`);
  console.error(`${kept.size} qualifying addresses, ${rows.length - kept.size} excluded by clustering`);
}

main().catch((e) => { console.error(e); process.exit(1); });
```

- [ ] **Step 2: Typecheck and confirm the CLI compiles**

Run: `cd sidequest-protocol/indexer && npm run typecheck`
Expected: clean.

- [ ] **Step 3: Prove it runs against the live vault**

Run:
```bash
cd sidequest-protocol/indexer && npx tsx src/season-snapshot.ts \
  --vault 0x3829bC787d4eB15Ec855A6cA33e1492a9103d130 \
  --from-block 55038004 --to-block 56100000 \
  --rpc https://rpc.mainnet.chain.robinhood.com/rpc
```
Expected: a header line and zero or one data rows, plus the count on stderr.
The vault holds 4.50 USDG from a single depositor, so nothing qualifies for a
tier requiring 25 USDG. **A run producing no rows is the correct result here,
not a failure.** What is being proven is that the pipeline reads the chain,
prices shares and emits valid CSV.

- [ ] **Step 4: Run the full indexer suite**

Run: `cd sidequest-protocol/indexer && npm test`
Expected: PASS, 46 tests (30 existing plus 16 new).

- [ ] **Step 5: Commit**

```bash
git add sidequest-protocol/indexer/src/season-snapshot.ts
git commit -m "feat(season1): snapshot CLI emitting the generator's CSV"
```

---

### Task 5: Publish the criteria and correct the governance wording

**Files:**
- Modify: `zorpha-web/app/portal/airdrop/page.tsx:16-21`
- Modify: `zorpha-web/app/(marketing)/roadmap/page.tsx:69,72`
- Delete: `zorpha-web/data/airdrop/000000000000000000000000000000000000dead.json`
- Delete: `zorpha-web/data/airdrop/00000000000000000000000000000000000a1ce1.json`
- Delete: `zorpha-web/data/airdrop/00000000000000000000000000000000000b0b01.json`
- Delete: `zorpha-web/data/airdrop/613ab528e46fced27350465e338354776b2a790a.json`
- Delete: `zorpha-web/data/airdrop/b4a7c2deebb5eadc34e120bc8a5708508dc17f4b.json`

**Interfaces:**
- Consumes: the tier values from `SEASON_1_TIERS` (Task 2), restated as prose.
- Produces: nothing consumed by code.

This task is the one that starts the clock, which is why it is last.

- [ ] **Step 1: Replace the portal copy**

In `zorpha-web/app/portal/airdrop/page.tsx`, replace the sentence beginning
"The snapshot criteria have not been published yet" with the criteria. Keep
the surrounding `formatCompact(tokensFor(community.tgeBps))` interpolation
so the figure stays derived rather than typed.

```tsx
          <p className="mt-3 text-sm leading-relaxed text-ink-400">
            {formatCompact(tokensFor(community.tgeBps))} {TOKEN.ticker}, or {community.tgeBps / 100}% of
            max supply, is funded on-chain and reserved for the Season 1 airdrop. Season 1 allocates
            8,000,000 of it; the rest stays with governance for later seasons. Claims are pull-based:
            nothing is airdropped into your wallet without you asking for it.
          </p>
          <p className="mt-3 text-sm leading-relaxed text-ink-400">
            Two tiers, measured over a 90 day window. Depositing at least 25 USDG into a Zorpha vault
            and holding it for 30 continuous days earns 15,000 {TOKEN.ticker}. At least 250 USDG held
            for 60 continuous days earns 40,000 {TOKEN.ticker}. Tier 2 is a cap, not a rate: more
            capital earns no more than 40,000. Wallets funded from a common source are treated as one
            participant.
          </p>
          <p className="mt-3 text-sm leading-relaxed text-ink-400">
            Worth saying plainly: at the current market price 15,000 {TOKEN.ticker} is worth about
            twenty cents. This is a claim on the token being worth something later, not a payment, and
            you should treat it that way when deciding whether to take part.
          </p>
```

- [ ] **Step 2: Correct the roadmap governance wording**

In `zorpha-web/app/(marketing)/roadmap/page.tsx`, replace the Phase 3 item and
gate. There is no Governor contract; it is Phase 4 work, and a token weighted
vote today would be decided by the wallet holding 90% of the float.

```tsx
        'Not yet: Season 1 airdrop claims. The criteria are published and the 90 day measurement window is open. Season 1 was approved by the governance Safe under its 48 hour timelock, which is the mechanism that exists today; token holder voting arrives with the Governor in Phase 4',
```

and

```tsx
      gate: 'Remaining: the external audit above, and the Season 1 window to close.',
```

- [ ] **Step 3: Delete the stale testnet proof files**

```bash
git rm zorpha-web/data/airdrop/000000000000000000000000000000000000dead.json \
       zorpha-web/data/airdrop/00000000000000000000000000000000000a1ce1.json \
       zorpha-web/data/airdrop/00000000000000000000000000000000000b0b01.json \
       zorpha-web/data/airdrop/613ab528e46fced27350465e338354776b2a790a.json \
       zorpha-web/data/airdrop/b4a7c2deebb5eadc34e120bc8a5708508dc17f4b.json
```

These are proofs against the superseded testnet root, including one for the
burned deploy key `0xb4a7c2de`. They are served only by a local only fallback
in `app/api/airdrop/[address]/route.ts`, so production already returns 404 for
them, but they are stale and misleading in the tree.

- [ ] **Step 4: Verify the site builds and the gates pass**

Run:
```bash
cd zorpha-web && npm run typecheck && npm test && npm run build
```
Expected: typecheck clean, 46 tests pass, build succeeds including the
`check-env`, `check-tokenomics` and `check-contrast` prebuild gates.

Then confirm the required check would pass:
```bash
git grep -nP "(?<!')\x{2014}(?!')" -- . ':!sidequest-protocol/contracts/lib'
```
Expected: no output. Any hit fails `launch gates` and blocks the merge.

- [ ] **Step 5: Commit and open the pull request**

```bash
git add -A
git commit -m "The Season 1 criteria are published, which opens the window"
git push -u origin season1/publish-criteria
gh pr create --base main --title "The Season 1 criteria are published, which opens the window" --body "..."
```

`main` requires the `launch gates` context, so this merges only once that is
green.

---

## Self-Review

**Spec coverage.** Size and shape (Task 5 copy, Task 2 constants), criteria and
tiers (Task 2), the honest-value statement (Task 5 Step 1), sybil and
clustering (Task 3), governance wording (Task 5 Step 2), mechanics for
measurement and CSV (Tasks 1 and 4), housekeeping (Task 5 Step 3). The spec's
distributor deployment and `claimDeadline` are deliberately not covered; they
belong to the Phase C plan, as stated in Scope.

**Type consistency.** `ShareTransfer`, `BalanceInterval`, `Tier`, `Funding`,
`balanceIntervals`, `allocationFor`, `clusterOf` and `SEASON_1_TIERS` are named
identically in every task that defines or consumes them.

**Known gap, deliberate.** Task 4 builds `fundings` as an empty array, so the
cluster exclusion is wired but inert. Populating it requires deciding which
funding source to trace (native value transfers, USDG transfers, or both), and
that decision needs real candidate addresses to be sensible about. It is
correct to leave inert rather than guess: the code path, its tests and the CSV
shape are all proven, and the Phase C plan fills the array once there are
candidates to cluster. This is called out here so an implementer does not
mistake it for an oversight.

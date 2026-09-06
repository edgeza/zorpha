# Chain ID Backfill (Step 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every historical row a chain identifier — including the indexer's cursors — so the portal stops mixing two networks' data and a repointed indexer actually scans.

**Architecture:** One migration adds `chain_id` to `rebalances`, `managers` and `reputation_publishes`, backfills every existing row to 46630, and widens the natural keys that are currently chain-blind. A second migration does the same for `indexer_cursor`, without which a repointed indexer resumes from a testnet block height and silently scans nothing. The migration guards its own central assumption — that all existing data is testnet — and aborts rather than mislabelling history. The TypeScript row types are updated in the same phase so the app compiles against the new schema.

**Tech Stack:** PostgreSQL (Supabase), TypeScript (`zorpha-web/lib/supabase.ts`). Migrations are plain `.sql` files applied by hand in the Supabase SQL editor — there is no runner in `package.json`.

**Spec:** `docs/design/chain-aware-portal-design.md`

## Global Constraints

- Testnet chain id is **46630**. Mainnet is **4663**. These differ by one digit and are easy to transpose — read them carefully every time.
- The indexer is **stopped** and must stay stopped for this whole plan. Nothing writes to these tables while the migration runs.
- Every existing row is testnet, and **block height is what proves it** -- not `START_BLOCK`. Mainnet 4663's head was `55,201,684` on 2026-09-05; the lowest row in `rebalances` is `112,370,875`. Mainnet has never produced a block that high, so no row can be a mainnet row. The guard threshold is `60,000,000`.
- **Do NOT use `START_BLOCK` as a guard threshold.** It has held three different values (`0`, `111911103` on the local `.env`, `112522500` on Railway) and rows indexed under an earlier one sit legitimately below a later one. The first version of migration 011 asserted `block_number >= 112522500` and aborted on real data for exactly this reason.
- Migrations live in `zorpha-web/migrations/`. The latest is `010`. This plan adds `011`.
- Repo line endings are **LF**. Do not use Python text-mode writes on Windows — they emit CRLF.
- **The schema is split across TWO migration directories.** `zorpha-web/migrations/` is not the whole story: `sidequest-protocol/supabase/migrations/` holds `001_initial.sql` and `002_indexer_state_and_counters.sql`, which declare the `reputation_publishes` unique constraint, the `indexer_cursor` table and the `bump_manager` / `advance_cursor` / `record_cursor_error` functions. Search both before concluding an object is undeclared. Still verify against the live database, since the two directories may themselves have drifted.
- Do not delete testnet history. It is real history for 46630 and becomes correct once tagged.
- **Every constraint this plan widens is an `ON CONFLICT` arbiter for a live write path, and widening it makes that write fail with `42P10: no unique or exclusion constraint matching ON CONFLICT`.** Five call sites, none of which this plan updates:
  | Broken by | Call site | Arbiter today |
  |---|---|---|
  | 011 (Task 1) | `indexer/src/supabase.ts:164` | `tx_hash,log_index` |
  | 011 (Task 1) | `bump_manager()`, `002_indexer_state_and_counters.sql:44` | `(address)` |
  | 011 (Task 1) | `indexer/src/supabase.ts:204` | `contract_address,manager_address,nonce` |
  | 012 (Task 3) | `advance_cursor()`, `002_indexer_state_and_counters.sql:97` | `(source_kind, source_address)` |
  | 012 (Task 3) | `record_cursor_error()`, `002_indexer_state_and_counters.sql:118` | `(source_kind, source_address)` |
  These are runtime strings and SQL function bodies — `tsc` cannot see any of them, so Task 2's compile step will not catch one. Nothing breaks while the indexer stays stopped, which is why this plan is safe to land. **The indexer must not be restarted until a later plan fixes all five.** Keeping a three-argument `advance_cursor` overload does not help: the widened primary key breaks the `on conflict` inside the function body regardless of the overload's arity.

---

### Task 1: The migration

**Files:**
- Create: `zorpha-web/migrations/011-chain-id.sql`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: a `chain_id integer not null` column on `public.rebalances`, `public.managers`, `public.reputation_publishes` and `public.indexer_cursor`; `managers` primary key `(address, chain_id)`; `rebalances` unique `(chain_id, tx_hash, log_index)`; `indexer_cursor` keyed `(chain_id, source_kind, source_address)`.

- [ ] **Step 1: Write the migration**

Create `zorpha-web/migrations/011-chain-id.sql`:

```sql
-- 011 — give every row a chain, so the portal stops mixing two networks.
--
-- One Supabase project serves both Robinhood Chain deployments and no table
-- said which one a row belonged to. Repointing the web app at mainnet changed
-- the RPC and the contract addresses but not the data, and the portal served
-- three testnet vaults to mainnet visitors.
--
-- Chain ids differ by ONE DIGIT: testnet is 46630, mainnet is 4663.
--
-- WHY 46630 IS THE RIGHT BACKFILL VALUE
--
-- Every row to date is testnet. The indexer has only ever run against 46630,
-- and its START_BLOCK is 112522500. The guard below asserts that rather than
-- trusting it: if any rebalance predates the indexer's start block, the
-- blanket backfill would be mislabelling history that cannot be recovered
-- afterwards, so the migration aborts instead.
--
-- Note the direction. Testnet block heights (~112M) are HIGHER than mainnet's
-- head (~55M), so "below mainnet head" would flag every legitimate row. The
-- assertion is that rows are at or above the indexer's start block.

begin;

-- ── Guard ──────────────────────────────────────────────────────────────────
do $$
declare
  stray bigint;
  lowest bigint;
begin
  select count(*), min(block_number) into stray, lowest
  from public.rebalances
  where block_number < 112522500;

  if stray > 0 then
    raise exception
      'ABORT: % rebalance row(s) below the indexer start block (lowest %). '
      'These may not be testnet rows, and backfilling them to 46630 would '
      'mislabel history irreversibly. Investigate before re-running.',
      stray, lowest;
  end if;
end $$;

-- ── Columns ────────────────────────────────────────────────────────────────
-- Default 46630 so the not-null add succeeds against existing rows without a
-- separate update pass. The default is DROPPED at the end: after this
-- migration every writer must state its chain explicitly, and a silent
-- default is exactly how a mainnet row would get labelled testnet.
alter table public.rebalances
  add column if not exists chain_id integer not null default 46630;

alter table public.managers
  add column if not exists chain_id integer not null default 46630;

alter table public.reputation_publishes
  add column if not exists chain_id integer not null default 46630;

-- ── Natural keys ───────────────────────────────────────────────────────────
-- rebalances: "one row per log, so a re-indexed block cannot duplicate the
-- feed" (005-baseline.sql:68). That key is chain-blind. A cross-chain tx hash
-- collision is not a practical worry, but the constraint states a semantic
-- that is now wrong: uniqueness is per chain.
alter table public.rebalances
  drop constraint if exists rebalances_tx_hash_log_index_key;

alter table public.rebalances
  add constraint rebalances_chain_tx_log_key unique (chain_id, tx_hash, log_index);

-- managers: the same address can act on both chains, and total_rebalances must
-- not merge them. No foreign key references this table -- 005-baseline.sql
-- declares none -- so widening the key has no dependents.
alter table public.managers
  drop constraint if exists managers_pkey;

alter table public.managers
  add constraint managers_pkey primary key (address, chain_id);

-- reputation_publishes: the indexer upserts on
-- (contract_address, manager_address, nonce). That constraint is NOT declared
-- in any migration but must exist in the live database, or the upsert at
-- indexer/src/supabase.ts:204 would fail. Recreate it chain-scoped, tolerating
-- either the absence or presence of the undeclared original.
alter table public.reputation_publishes
  drop constraint if exists reputation_publishes_contract_address_manager_address_nonce_key;

alter table public.reputation_publishes
  drop constraint if exists reputation_publishes_chain_contract_manager_nonce_key;

alter table public.reputation_publishes
  add constraint reputation_publishes_chain_contract_manager_nonce_key
  unique (chain_id, contract_address, manager_address, nonce);

-- ── Indexes ────────────────────────────────────────────────────────────────
-- Every portal read will filter on chain_id, so it leads each index. The
-- originals stay: they serve queries that also filter by vault or manager.
create index if not exists rebalances_chain_recent_idx
  on public.rebalances (chain_id, block_timestamp desc);

create index if not exists rebalances_chain_vault_idx
  on public.rebalances (chain_id, vault_address, block_number desc);

create index if not exists reputation_chain_manager_idx
  on public.reputation_publishes (chain_id, manager_address, created_at desc);

-- ── Drop the defaults ──────────────────────────────────────────────────────
-- The default existed only to backfill. Leaving it would mean a writer that
-- forgets chain_id silently produces a testnet row, which is the original bug
-- wearing a different hat.
alter table public.rebalances            alter column chain_id drop default;
alter table public.managers              alter column chain_id drop default;
alter table public.reputation_publishes  alter column chain_id drop default;

commit;
```

- [ ] **Step 2: Verify the guard fires on bad data**

The guard is the only thing standing between a wrong assumption and irreversibly mislabelled history, so prove it works before trusting it.

In the Supabase SQL editor, run this **on its own** — it deliberately fails and rolls back, touching nothing:

```sql
begin;
insert into public.rebalances
  (vault_address, vault_type, manager, block_number, tx_hash, log_index,
   block_timestamp, nonce)
values
  ('0x0000000000000000000000000000000000000001', 'yield',
   '0x0000000000000000000000000000000000000002', 1,
   '0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef', 0,
   now(), 0);

do $$
declare stray bigint; lowest bigint;
begin
  select count(*), min(block_number) into stray, lowest
  from public.rebalances where block_number <= 60000000;
  if stray > 0 then
    raise exception 'ABORT: % row(s) at or below 60000000 (lowest %)', stray, lowest;
  end if;
end $$;
rollback;
```

Expected: `ERROR: ABORT: 1 row(s) at or below 60000000 (lowest 1)`. Exactly **1** -- the fake row. If the count is higher, a real row is below mainnet's head and you must stop and investigate rather than lower the threshold.

The `rollback` runs regardless, so the fake row never persists. Confirm with:

```sql
select count(*) from public.rebalances
where tx_hash = '0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef';
```

Expected: `0`.

- [ ] **Step 3: Record the pre-migration row counts**

Needed to prove the migration changed no data. Run and write the numbers down:

```sql
select 'rebalances' as t, count(*) from public.rebalances
union all select 'managers', count(*) from public.managers
union all select 'reputation_publishes', count(*) from public.reputation_publishes;
```

- [ ] **Step 4: Apply the migration**

Paste the whole of `011-chain-id.sql` into the Supabase SQL editor and run it.

Expected: success, no `ABORT`. If it aborts, **stop** — some row predates the indexer's start block and the assumption behind this plan is wrong. Report that rather than lowering the threshold.

- [ ] **Step 5: Verify**

```sql
-- every row tagged testnet, counts unchanged from Step 3
select 'rebalances' as t, count(*) total, count(*) filter (where chain_id = 46630) tagged
from public.rebalances
union all
select 'managers', count(*), count(*) filter (where chain_id = 46630) from public.managers
union all
select 'reputation_publishes', count(*), count(*) filter (where chain_id = 46630)
from public.reputation_publishes;
```

Expected: `total = tagged` on all three rows, and `total` matching Step 3 exactly.

```sql
-- defaults are gone
select table_name, column_name, column_default
from information_schema.columns
where column_name = 'chain_id' and table_schema = 'public';
```

Expected: three rows, `column_default` null on each.

```sql
-- the new keys exist
select conrelid::regclass as tbl, conname, pg_get_constraintdef(oid)
from pg_constraint
where conrelid in ('public.rebalances'::regclass,
                   'public.managers'::regclass,
                   'public.reputation_publishes'::regclass)
  and contype in ('p', 'u')
order by 1, 2;
```

Expected: `managers_pkey PRIMARY KEY (address, chain_id)`;
`rebalances_chain_tx_log_key UNIQUE (chain_id, tx_hash, log_index)`;
`reputation_publishes_chain_contract_manager_nonce_key UNIQUE (chain_id, contract_address, manager_address, nonce)`.
No constraint on `(tx_hash, log_index)` alone should remain.

- [ ] **Step 6: Commit**

```bash
git add zorpha-web/migrations/011-chain-id.sql
git commit -m "Give every row a chain, so the portal stops mixing two networks"
```

---

### Task 2: TypeScript row types

The app must not compile against a schema it does not describe. Without this, a query that omits `chain_id` type-checks fine and silently reads both chains.

**Files:**
- Modify: `zorpha-web/lib/supabase.ts` — `RebalanceRow` (line 58), `ManagerRow` (line 79), `ReputationRow` (line 88)

**Interfaces:**
- Consumes: the `chain_id` column from Task 1.
- Produces: `chain_id: number` as a **required** field on `RebalanceRow`, `ManagerRow` and `ReputationRow`. Step 2's query filters (a later plan) rely on it being non-optional.

- [ ] **Step 1: Add the field to all three types**

In `zorpha-web/lib/supabase.ts`, add to `RebalanceRow`, immediately after `id`:

```ts
  /**
   * Which Robinhood Chain this happened on. 46630 testnet, 4663 mainnet.
   *
   * Required, not optional: an optional field would let a query that forgets
   * to filter type-check cleanly, which is the bug this column exists to stop.
   * Rows written before migration 011 are all testnet and were backfilled.
   */
  chain_id: number;
```

Add the same field (the one-line form is fine on the other two) to `ManagerRow` after `address`, and to `ReputationRow` after `id`:

```ts
  /** 46630 testnet, 4663 mainnet. See RebalanceRow.chain_id. */
  chain_id: number;
```

- [ ] **Step 2: Verify it breaks what it should**

Run: `cd zorpha-web && npx tsc --noEmit`

Expected: **errors** in any file that constructs one of these rows without `chain_id`. That is the point — those call sites are exactly what a later plan must fix. Record the list; it is the input to the query-filter plan.

If there are **no** errors, nothing constructs these types literally, so the field is carried through from Supabase reads only. Note that in the report.

- [ ] **Step 3: Resolve the breakage**

For each error, add `chain_id` sourced from the connected chain — **do not** hardcode 46630 in application code. Import from the existing chain config:

```ts
import { activeChain } from '@/lib/chains';
// ...
chain_id: activeChain.id,
```

If an error is in the indexer rather than the web app, leave it: the indexer is a separate package with its own copy of these types, it is stopped, and repointing it is a later plan. Note it in the report.

- [ ] **Step 4: Verify**

Run: `npx tsc --noEmit`
Expected: no output.

Run: `npm run build`
Expected: `Compiled successfully`.

- [ ] **Step 5: Commit**

```bash
git add zorpha-web/lib/supabase.ts
git commit -m "Make chain_id required, so a query that forgets it cannot compile"
```

---

### Task 3: Chain-scope the indexer cursors

Without this, a repointed indexer scans nothing and reports success. `START_BLOCK` is read **only when no cursor exists** (`indexer/src/index.ts:107`):

```ts
const stored = await getCursor('vault', vault.address);
const from = stored === null ? config.startBlock : stored + 1n;
```

Stored cursors sit at testnet heights (~112,522,500). Point the indexer at mainnet, whose head is ~55.1M, and `from` becomes 112,522,501 — beyond the head, so every scan is empty and every cycle looks healthy. That is a worse failure than the honest crash the chain-id mismatch produces today.

**Read `sidequest-protocol/supabase/migrations/002_indexer_state_and_counters.sql:68-130` first** — it declares `indexer_cursor` (primary key `(source_kind, source_address)`), `advance_cursor(text, text, bigint)` and `record_cursor_error(text, text, text)` in full. The discovery step below is therefore a confirmation that the live database still matches the file, not an exploration of an unknown shape. Both cursor functions carry `on conflict (source_kind, source_address)` in their bodies and both must be rewritten when the key widens — see the ON CONFLICT table in Global Constraints.

**Files:**
- Create: `zorpha-web/migrations/012-cursor-chain-scope.sql`

**Interfaces:**
- Consumes: the `chain_id` column pattern from Task 1.
- Produces: `chain_id integer not null` on `public.indexer_cursor`, keyed `(chain_id, source_kind, source_address)`, and an `advance_cursor` that takes `p_chain_id`.

- [ ] **Step 1: Read what actually exists**

In the Supabase SQL editor:

```sql
-- columns
select column_name, data_type, is_nullable, column_default
from information_schema.columns
where table_schema = 'public' and table_name = 'indexer_cursor'
order by ordinal_position;

-- keys
select conname, contype, pg_get_constraintdef(oid)
from pg_constraint where conrelid = 'public.indexer_cursor'::regclass;

-- the function the indexer calls
select pg_get_functiondef(oid)
from pg_proc where proname = 'advance_cursor';

-- what is actually stored
select source_kind, source_address, last_block from public.indexer_cursor order by 1, 2;
```

Record all four outputs in the report. **Every later step in this task depends on them**, and the SQL below assumes the shape implied by `indexer/src/supabase.ts:269-302` — `source_kind`, `source_address`, `last_block`, keyed on the first two. If reality differs, adapt the statements and say so in the report rather than forcing the assumed shape.

- [ ] **Step 2: Write the migration**

Create `zorpha-web/migrations/012-cursor-chain-scope.sql`:

```sql
-- 012 — chain-scope the indexer cursors.
--
-- START_BLOCK is read only when no cursor exists (indexer/src/index.ts:107).
-- The stored cursors are testnet heights (~112.5M). Repointing the indexer to
-- mainnet, head ~55.1M, would make it resume from 112,522,501: past the head,
-- so every scan returns nothing and every cycle reports success. Silent, and
-- therefore worse than the chain-id mismatch that currently halts it loudly.
--
-- Tagging rather than deleting: the testnet cursors are correct FOR TESTNET,
-- and deleting them would force a full re-scan of 46630 if the indexer is ever
-- pointed back. After this, mainnet simply has no cursor, so START_BLOCK
-- applies exactly as intended.
--
-- indexer_cursor is not defined in this repo -- supabase.ts:282 names a
-- 002_indexer_state_and_counters.sql that does not exist here. Confirm the
-- shape against the live database before running (Task 3, Step 1).

begin;

alter table public.indexer_cursor
  add column if not exists chain_id integer not null default 46630;

-- Widen the key so a cursor is per (chain, source), not per source.
alter table public.indexer_cursor
  drop constraint if exists indexer_cursor_pkey;

alter table public.indexer_cursor
  add constraint indexer_cursor_pkey
  primary key (chain_id, source_kind, source_address);

alter table public.indexer_cursor alter column chain_id drop default;

commit;
```

- [ ] **Step 3: Update `advance_cursor`**

The function is called as `advance_cursor(p_kind, p_address, p_block)` (`indexer/src/supabase.ts:296`). It must take the chain too, or it will upsert against the old key and fail once the primary key includes `chain_id`.

Using the definition captured in Step 1 as the base, write the replacement in the same migration file, **before the `commit`**. If Step 1 showed a body that differs from the shape below, preserve its actual logic and add only the chain scoping:

```sql
create or replace function public.advance_cursor(
  p_chain_id integer,
  p_kind text,
  p_address text,
  p_block bigint
) returns void
language sql
as $
  insert into public.indexer_cursor (chain_id, source_kind, source_address, last_block)
  values (p_chain_id, p_kind, p_address, p_block)
  on conflict (chain_id, source_kind, source_address)
  do update set last_block = excluded.last_block;
$;
```

Leave the three-argument version in place. Dropping it while the deployed indexer still calls it would break the running service; the indexer is updated in the repoint plan, and the old overload is removed there.

- [ ] **Step 4: Apply and verify**

Run the migration, then:

```sql
-- every existing cursor tagged testnet, none tagged mainnet
select chain_id, count(*) from public.indexer_cursor group by 1 order by 1;

-- the new key
select conname, pg_get_constraintdef(oid) from pg_constraint
where conrelid = 'public.indexer_cursor'::regclass and contype = 'p';

-- both overloads present
select oid::regprocedure from pg_proc where proname = 'advance_cursor';
```

Expected: one group, `46630`, count matching Step 1's row count. Primary key `(chain_id, source_kind, source_address)`. Two `advance_cursor` signatures.

**There must be no row with `chain_id = 4663`.** If one exists, something wrote a mainnet cursor while the indexer was meant to be stopped — stop and report it.

- [ ] **Step 5: Commit**

```bash
git add zorpha-web/migrations/012-cursor-chain-scope.sql
git commit -m "Chain-scope the cursors, or a repointed indexer scans nothing"
```

## Phase exit criteria

- Migration `011` applied; all three tables report `total = tagged` at 46630 with counts unchanged from the pre-migration snapshot
- `chain_id` has no default on any of the three tables
- `managers_pkey` is `(address, chain_id)`; `rebalances` unique is `(chain_id, tx_hash, log_index)`
- `indexer_cursor` is keyed `(chain_id, source_kind, source_address)`, every row reads 46630, and no row reads 4663
- `advance_cursor` has a four-argument overload taking `p_chain_id`, with the three-argument version still present for the running service
- `npx tsc --noEmit` and `npm run build` clean
- The indexer is still stopped

**Do not repoint the indexer as part of this plan.** Flipping `RPC_URL` to mainnet without also fixing `START_BLOCK` (currently `112522500`, above mainnet's head of ~55.1M) makes it scan from a block that does not exist — it would index nothing while reporting success. That is step 5 and gets its own plan.

Steps 2–5 of the spec — query filters, the web-app chain guard, vault enumeration, and the indexer repoint — are separate plans.

-- Zorpha — indexer state, atomic counters, and dispute tracking.
--
-- Closes four gaps that 001 left, each of which breaks something user-visible:
--
--   1. `managers.total_rebalances` was never incremented. The indexer called an
--      RPC named `bump_manager` that did not exist, silently fell back to a
--      plain upsert, and that fallback did not touch the counter. The portal
--      leaderboard ranks by this column, so every manager sat at zero forever.
--
--   2. There was no indexer cursor. Resume position was derived from
--      max(block_number) in `rebalances`, so a vault with no rebalances yet
--      re-scanned its entire history on every poll cycle — a full-range
--      getLogs every 12 seconds, which any RPC provider will rate-limit.
--
--   3. Reputation disputes had nowhere to land. The registry emits
--      StatsChallenged / StatsUpheld / StatsOverturned, but nothing recorded
--      them, so `challenged` stayed false and the portal showed a disputed
--      commitment as unchallenged — the same class of failure as audit finding
--      V-03, on the indexer side of the seam.
--
--   4. `rebalances.manager` was the vault's configured manager, not the address
--      that actually submitted. For a protocol whose proposition is verifiable
--      attribution, that distinction has to be visible rather than collapsed.

-- ─── 1. Atomic manager counter ──────────────────────────────────────────────
--
-- SECURITY INVOKER (the default), not DEFINER: this must run as the caller so
-- RLS still applies. The indexer calls it with the service role, which bypasses
-- RLS anyway; there is no reason to hand a privilege escalation to anon.
--
-- `set search_path = ''` and fully-qualified names, so the function cannot be
-- hijacked by a search_path manipulation.
create or replace function public.bump_manager(
  p_address text,
  p_last_seen timestamptz
)
returns void
language sql
security invoker
set search_path = ''
as $$
  insert into public.managers as m (address, first_seen_at, total_rebalances, last_active_at)
  values (p_address, p_last_seen, 1, p_last_seen)
  on conflict (address) do update
    set total_rebalances = m.total_rebalances + 1,
        -- Never move first_seen_at forward, and never move last_active_at
        -- backward: blocks can arrive out of order across a reorg, or when a
        -- backfill runs alongside the live tail.
        first_seen_at    = least(m.first_seen_at, excluded.first_seen_at),
        last_active_at   = greatest(
                             coalesce(m.last_active_at, excluded.last_active_at),
                             excluded.last_active_at
                           );
$$;

comment on function public.bump_manager(text, timestamptz) is
  'Atomically upsert a manager and increment their receipt count. Called once '
  'per successfully inserted rebalance, so the counter matches the number of '
  'rows in `rebalances` for that manager.';

-- anon must not be able to inflate a manager's receipt count.
revoke execute on function public.bump_manager(text, timestamptz) from anon;
revoke execute on function public.bump_manager(text, timestamptz) from authenticated;

-- ─── 2. Indexer cursor ──────────────────────────────────────────────────────
--
-- One row per (source_kind, source_address). `last_block` is the highest block
-- fully scanned — the next scan starts at last_block + 1.
create table if not exists public.indexer_cursor (
  source_kind    text        not null check (source_kind in ('vault', 'registry')),
  source_address text        not null,
  last_block     bigint      not null default 0 check (last_block >= 0),
  last_run_at    timestamptz not null default now(),
  -- Surfaced so a stuck indexer is diagnosable from the dashboard rather than
  -- only from Railway logs.
  last_error     text,
  error_count    integer     not null default 0 check (error_count >= 0),
  primary key (source_kind, source_address)
);

comment on table public.indexer_cursor is
  'Resume position per indexed source. Without this the indexer re-scans from '
  'the deploy block on every poll cycle.';

create or replace function public.advance_cursor(
  p_kind    text,
  p_address text,
  p_block   bigint
)
returns void
language sql
security invoker
set search_path = ''
as $$
  insert into public.indexer_cursor as c (source_kind, source_address, last_block, last_run_at, last_error, error_count)
  values (p_kind, p_address, p_block, now(), null, 0)
  on conflict (source_kind, source_address) do update
    -- Monotonic. A crashed run that resumes from an older block must not drag
    -- the cursor backwards and re-emit work.
    set last_block  = greatest(c.last_block, excluded.last_block),
        last_run_at = now(),
        last_error  = null,
        error_count = 0;
$$;

create or replace function public.record_cursor_error(
  p_kind    text,
  p_address text,
  p_error   text
)
returns void
language sql
security invoker
set search_path = ''
as $$
  insert into public.indexer_cursor as c (source_kind, source_address, last_block, last_run_at, last_error, error_count)
  values (p_kind, p_address, 0, now(), p_error, 1)
  on conflict (source_kind, source_address) do update
    set last_run_at = now(),
        last_error  = excluded.last_error,
        error_count = c.error_count + 1;
$$;

revoke execute on function public.advance_cursor(text, text, bigint) from anon, authenticated;
revoke execute on function public.record_cursor_error(text, text, text) from anon, authenticated;

-- ─── 3. Dispute tracking on reputation publishes ───────────────────────────
alter table public.reputation_publishes
  add column if not exists challenger        text,
  add column if not exists counter_commitment text,
  add column if not exists challenged_at     timestamptz,
  add column if not exists resolved_at       timestamptz,
  add column if not exists arbiter           text;

comment on column public.reputation_publishes.upheld is
  'NULL until a governance arbiter resolves an open dispute. A challenged '
  'commitment is disputed-and-unresolved, not "overturned" — see audit finding '
  'V-06, where a matching self-challenge could mint a false "upheld".';

-- Index for the dispute-status filter the manager page uses.
create index if not exists reputation_publishes_challenged_idx
  on public.reputation_publishes (manager_address, challenged)
  where challenged = true;

-- ─── 4. Honest attribution on rebalances ────────────────────────────────────
--
-- `manager` stays the vault's configured manager, which is what the vault
-- actually enforces through KEEPER_ROLE. `submitter` is the EOA that landed the
-- transaction — permissionless, so frequently not the manager at all. Keeping
-- both means the record does not quietly imply the submitter authored the trade.
alter table public.rebalances
  add column if not exists submitter text;

comment on column public.rebalances.submitter is
  'tx.from for the transaction carrying this receipt. Submission is '
  'permissionless, so this is often a keeper rather than the manager who signed.';

comment on column public.rebalances.manager is
  'The vault''s configured manager, as enforced by KEEPER_ROLE. Not derived '
  'from the transaction sender.';

-- ─── 5. RLS ─────────────────────────────────────────────────────────────────
alter table public.indexer_cursor enable row level security;

-- Read-only, so the portal can show indexer lag and a stuck-indexer state.
-- Writes remain service_role only: no insert/update/delete policy exists.
drop policy if exists "read indexer cursor" on public.indexer_cursor;
create policy "read indexer cursor"
  on public.indexer_cursor
  for select
  to anon, authenticated
  using (true);

-- 001 enabled RLS on keeper_heartbeat but created no policy, which makes it
-- unreadable rather than deliberately private. State the intent explicitly.
drop policy if exists "read keeper heartbeat" on public.keeper_heartbeat;
create policy "read keeper heartbeat"
  on public.keeper_heartbeat
  for select
  to anon, authenticated
  using (true);

-- ─── 6. Indexes the portal's actual queries need ────────────────────────────
--
-- The receipts feed orders by block_timestamp desc across ALL vaults, which 001
-- had no index for — only per-vault and per-manager composites.
create index if not exists rebalances_recent_idx
  on public.rebalances (block_timestamp desc);

-- The leaderboard orders by total_rebalances desc.
create index if not exists managers_rank_idx
  on public.managers (total_rebalances desc);

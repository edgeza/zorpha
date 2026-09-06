-- 012, chain-scope the vault list and the indexer cursors.
--
-- 011 gave `rebalances`, `managers` and `reputation_publishes` a chain. It did
-- not give one to the two tables that decide WHAT gets indexed and FROM WHERE,
-- and those are the two that make a repointed indexer fail silently:
--
--   vaults          -- `getKnownVaults()` selects every row, so an indexer on
--                      4663 would try to scan the three testnet vaults that
--                      008 registered. They have no code on mainnet, so
--                      getLogs returns nothing, forever, and every cycle
--                      reports success. 010 hid them with `listed = false`,
--                      but getKnownVaults does not read `listed` either.
--
--   indexer_cursor  -- keyed (source_kind, source_address) with no chain. The
--                      stored cursors sit at testnet heights (~112.5M).
--                      START_BLOCK is read ONLY when no cursor exists
--                      (indexer/src/index.ts:107), so a repointed indexer
--                      would resume at 112,522,501 against a chain whose head
--                      is 55.2M -- past the end, nothing to scan, no error.
--
-- This migration also rewrites the three functions whose ON CONFLICT arbiters
-- 011 invalidated. They are broken RIGHT NOW: `managers_pkey` is already
-- (address, chain_id), so the `on conflict (address)` inside bump_manager
-- raises 42P10 on the next call. The indexer has been stopped since 011
-- landed, which is the only reason that has not surfaced yet.
--
-- Chain ids differ by ONE DIGIT: testnet is 46630, mainnet is 4663.

begin;

-- ─── 1. vaults ──────────────────────────────────────────────────────────────

alter table public.vaults
  add column if not exists chain_id integer not null default 46630;

-- The one vault that exists on mainnet. Verified on chain rather than taken
-- from the launch script:
--
--   eth_getCode  0x3829bC787d4eB15Ec855A6cA33e1492a9103d130  -> 10,985 bytes
--   name()       "Zorpha Steakhouse USDG"
--   symbol()     "zsUSDG"
--   asset()      0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168 (USDG, 6dp)
--   first log    block 55,038,004
--
-- Every other row is testnet and keeps the default.
update public.vaults
   set chain_id = 4663
 where lower(address) = lower('0x3829bC787d4eB15Ec855A6cA33e1492a9103d130');

-- ── Guard ──────────────────────────────────────────────────────────────────
-- Exactly one mainnet vault is expected. More means a row was added since this
-- file was written and is about to be tagged testnet by the column default;
-- fewer means 010 never ran and the mainnet vault is absent, so the indexer
-- would come up with an empty list and index nothing while reporting success.
-- Both are wrong in a way that is invisible afterwards.
do $guard$
declare
  mainnet_count bigint;
begin
  select count(*) into mainnet_count
  from public.vaults where chain_id = 4663;

  if mainnet_count <> 1 then
    raise exception
      'ABORT: expected exactly 1 mainnet vault, found %. Either 010 was never '
      'applied (0), or a vault was added since 012 was written (>1) and would '
      'be mislabelled testnet by the column default. Reconcile the vault list '
      'against chain 4663 before re-running.',
      mainnet_count;
  end if;
end
$guard$;

-- The same address can be deployed to both chains, and CREATE2 makes that
-- likely rather than theoretical. Nothing references vaults.address -- neither
-- 005-baseline.sql nor 001_initial.sql declares a foreign key to it -- so
-- widening the key has no dependents.
alter table public.vaults drop constraint if exists vaults_pkey;

alter table public.vaults
  add constraint vaults_pkey primary key (chain_id, address);

alter table public.vaults alter column chain_id drop default;

create index if not exists vaults_chain_listed_idx
  on public.vaults (chain_id, listed);

-- ─── 2. indexer_cursor ──────────────────────────────────────────────────────
--
-- Tagging rather than deleting: the testnet cursors are correct FOR TESTNET,
-- and deleting them would force a full re-scan of 46630 if the indexer is ever
-- pointed back. After this, mainnet simply has no cursor, so START_BLOCK
-- applies exactly as intended.
alter table public.indexer_cursor
  add column if not exists chain_id integer not null default 46630;

alter table public.indexer_cursor drop constraint if exists indexer_cursor_pkey;

alter table public.indexer_cursor
  add constraint indexer_cursor_pkey
  primary key (chain_id, source_kind, source_address);

alter table public.indexer_cursor alter column chain_id drop default;

-- ─── 3. The functions 011 invalidated ───────────────────────────────────────
--
-- Each takes the chain as its FIRST argument, so a call that forgets it is an
-- arity error at the call site rather than a row written to the wrong chain.
-- `set search_path = ''` and fully-qualified names are preserved from 002.

create or replace function public.bump_manager(
  p_chain_id  integer,
  p_address   text,
  p_last_seen timestamptz
)
returns void
language sql
security invoker
set search_path = ''
as $fn$
  insert into public.managers as m
    (chain_id, address, first_seen_at, total_rebalances, last_active_at)
  values (p_chain_id, p_address, p_last_seen, 1, p_last_seen)
  on conflict (address, chain_id) do update
    set total_rebalances = m.total_rebalances + 1,
        -- Never move first_seen_at forward, and never move last_active_at
        -- backward: blocks can arrive out of order across a reorg, or when a
        -- backfill runs alongside the live tail.
        first_seen_at    = least(m.first_seen_at, excluded.first_seen_at),
        last_active_at   = greatest(
                             coalesce(m.last_active_at, excluded.last_active_at),
                             excluded.last_active_at
                           );
$fn$;

create or replace function public.advance_cursor(
  p_chain_id integer,
  p_kind     text,
  p_address  text,
  p_block    bigint
)
returns void
language sql
security invoker
set search_path = ''
as $fn$
  insert into public.indexer_cursor as c
    (chain_id, source_kind, source_address, last_block, last_run_at, last_error, error_count)
  values (p_chain_id, p_kind, p_address, p_block, now(), null, 0)
  on conflict (chain_id, source_kind, source_address) do update
    -- Monotonic. A crashed run that resumes from an older block must not drag
    -- the cursor backwards and re-emit work.
    set last_block  = greatest(c.last_block, excluded.last_block),
        last_run_at = now(),
        last_error  = null,
        error_count = 0;
$fn$;

create or replace function public.record_cursor_error(
  p_chain_id integer,
  p_kind     text,
  p_address  text,
  p_error    text
)
returns void
language sql
security invoker
set search_path = ''
as $fn$
  insert into public.indexer_cursor as c
    (chain_id, source_kind, source_address, last_block, last_run_at, last_error, error_count)
  values (p_chain_id, p_kind, p_address, 0, now(), p_error, 1)
  on conflict (chain_id, source_kind, source_address) do update
    set last_run_at = now(),
        last_error  = excluded.last_error,
        error_count = c.error_count + 1;
$fn$;

revoke execute on function public.bump_manager(integer, text, timestamptz)
  from anon, authenticated;
revoke execute on function public.advance_cursor(integer, text, text, bigint)
  from anon, authenticated;
revoke execute on function public.record_cursor_error(integer, text, text, text)
  from anon, authenticated;

-- ─── 4. Make the retired signatures fail by name ────────────────────────────
--
-- The chain-blind overloads cannot work: their ON CONFLICT arbiters no longer
-- exist, so Postgres raises
--
--   42P10: there is no unique or exclusion constraint matching the ON CONFLICT
--
-- which names neither the function nor the reason. A stale build on Railway
-- calling one of these would emit that once per receipt, with no hint that the
-- fix is to redeploy. Replacing the bodies with a raise turns an
-- unattributable error into an instruction.
--
-- They are NOT dropped. Dropping them makes the call fail as "function does
-- not exist", which reads like a MISSING migration -- the opposite of the
-- truth, and the thing most likely to send someone re-running 002.

create or replace function public.bump_manager(p_address text, p_last_seen timestamptz)
returns void language plpgsql as $retired$
begin
  raise exception
    'bump_manager(text, timestamptz) is retired. managers is keyed '
    '(address, chain_id) since migration 011, so this signature cannot state a '
    'chain and its ON CONFLICT arbiter no longer exists. The caller is an '
    'indexer build from before migration 012 -- redeploy it. Use '
    'bump_manager(p_chain_id, p_address, p_last_seen).';
end
$retired$;

create or replace function public.advance_cursor(p_kind text, p_address text, p_block bigint)
returns void language plpgsql as $retired$
begin
  raise exception
    'advance_cursor(text, text, bigint) is retired. indexer_cursor is keyed '
    '(chain_id, source_kind, source_address) since migration 012. Writing '
    'through this signature would resume the wrong chain from the wrong '
    'height. Redeploy the indexer and use '
    'advance_cursor(p_chain_id, p_kind, p_address, p_block).';
end
$retired$;

create or replace function public.record_cursor_error(p_kind text, p_address text, p_error text)
returns void language plpgsql as $retired$
begin
  raise exception
    'record_cursor_error(text, text, text) is retired. See migration 012. Use '
    'record_cursor_error(p_chain_id, p_kind, p_address, p_error).';
end
$retired$;

commit;

-- AFTER RUNNING THIS
--
--   select chain_id, count(*) from public.vaults group by 1 order by 1;
--     -> 4663: 1, and 46630: however many testnet vaults exist.
--
--   select chain_id, count(*) from public.indexer_cursor group by 1 order by 1;
--     -> 46630 only. A row at 4663 means something wrote a mainnet cursor
--        while the indexer was meant to be stopped -- stop and investigate.
--
--   select oid::regprocedure from pg_proc
--    where proname in ('advance_cursor', 'record_cursor_error', 'bump_manager')
--    order by 1;
--     -> two signatures each.

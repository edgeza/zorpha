-- ============================================================================
-- Zorpha portal database: complete state. RUN THIS ONE.
-- ============================================================================
--
-- Idempotent. Safe to run on an empty project, on the current database, or
-- twice. Every statement is create-if-not-exists, add-column-if-not-exists, or
-- an upsert.
--
-- WHY THIS FILE EXISTS
--
-- The repo contained 003-reseed-vaults.sql and 004-vault-visibility.sql and
-- nothing before them. I numbered those as if 001 and 002 existed. They never
-- did -- the schema was created outside the repo, so there was no record of it
-- anywhere, and "run migration 004" was not a followable instruction.
--
-- This supersedes both. 003 is folded in (the same three vaults, the same
-- values) and 004 is folded in (the `listed` flag and its trigger). Running
-- this after having run 003 changes nothing about those three rows.
--
-- Column names and types are derived from lib/supabase.ts, which is what the
-- app actually reads. Vault addresses, names, symbols and assets were read off
-- chain 46630 on 3 September 2026, not copied from notes.
--
-- ============================================================================

-- ── 1. Tables ───────────────────────────────────────────────────────────────

create table if not exists public.vaults (
  address          text primary key,
  vault_type       text not null check (vault_type in ('spot', 'rotation', 'yield')),
  name             text not null,
  symbol           text not null,
  asset            text not null,
  cash             text,
  base_asset       text,
  oracle           text,
  strategy         text not null default '',
  manager_address  text not null,
  deployed_at      timestamptz not null default now()
);

create table if not exists public.managers (
  address           text primary key,
  label             text,
  avatar_url        text,
  first_seen_at     timestamptz not null default now(),
  total_rebalances  integer not null default 0,
  last_active_at    timestamptz
);

create table if not exists public.rebalances (
  id               uuid primary key default gen_random_uuid(),
  vault_address    text not null,
  vault_type       text not null check (vault_type in ('spot', 'rotation', 'yield')),
  manager          text not null,
  block_number     bigint not null,
  tx_hash          text not null,
  log_index        integer not null,
  block_timestamp  timestamptz not null,
  target_bps       integer,
  target_weights   integer[],
  asset_leg        text,
  cash_leg         text,
  nav_per_share    text,
  nonce            bigint not null,
  commitment       text,
  -- One row per log, so a re-indexed block cannot duplicate the feed.
  unique (tx_hash, log_index)
);

create table if not exists public.reputation_publishes (
  id                  uuid primary key default gen_random_uuid(),
  manager_address     text not null,
  contract_address    text not null,
  commitment          text not null,
  window_start        timestamptz not null,
  window_end          timestamptz not null,
  nonce               bigint not null,
  challenge_deadline  timestamptz not null,
  challenged          boolean not null default false,
  upheld              boolean,
  tx_hash             text not null,
  created_at          timestamptz not null default now()
);

-- ── 2. Vault visibility (was 004) ───────────────────────────────────────────
--
-- listVaults() used to select every row, so anything in this table was a
-- product. The drills deploy real contracts with real names, and the portal
-- duly advertised "Zorpha Leader Test Vault" and "Zorpha Loss Drill Vault" to
-- users, with mandates and manager addresses, beside the real three.
--
-- 003 fixed that with a DELETE. A DELETE is a fact about one moment: the next
-- drill run put them straight back. A flag is a policy.

alter table public.vaults
  add column if not exists listed boolean not null default true;

comment on column public.vaults.listed is
  'False hides the vault from the portal index. Drill and test vaults are '
  'marked false automatically by vaults_autohide_test. Unlisted vaults stay '
  'reachable by direct address, with a warning.';

-- Default TRUE on purpose: a real new vault should appear without anyone
-- remembering a flag. What must not happen by accident is a TEST vault
-- appearing, and those are recognisable by name.
create or replace function public.vaults_autohide_test()
returns trigger
language plpgsql
as $$
begin
  if new.name   ilike '%drill%'  or new.name   ilike '%test%'
  or new.name   ilike '%stale%'
  or new.symbol ilike '%DRILL%'  or new.symbol ilike '%LEAD%'
  or new.symbol ilike '%STALE%'  or new.symbol ilike '%BOND%' then
    new.listed := false;
  end if;
  return new;
end;
$$;

-- A trigger, not a check constraint. A constraint would REJECT the insert, and
-- the indexer would then retry forever or drop the event -- over what is only
-- a presentation decision. The vault exists on chain either way; this just
-- keeps it off the storefront.
drop trigger if exists vaults_autohide_test_trg on public.vaults;
create trigger vaults_autohide_test_trg
  before insert or update of name, symbol on public.vaults
  for each row execute function public.vaults_autohide_test();

-- Apply it to what is already there.
update public.vaults
   set listed = false
 where (name   ilike '%drill%' or name   ilike '%test%' or name ilike '%stale%'
     or symbol ilike '%DRILL%' or symbol ilike '%LEAD%'
     or symbol ilike '%STALE%' or symbol ilike '%BOND%')
   and listed is true;

-- ── 3. Indexes ──────────────────────────────────────────────────────────────

create index if not exists vaults_listed_idx        on public.vaults (listed) where listed;
create index if not exists rebalances_vault_idx     on public.rebalances (vault_address, block_number desc);
create index if not exists rebalances_manager_idx   on public.rebalances (manager, block_timestamp desc);
create index if not exists rebalances_recent_idx    on public.rebalances (block_timestamp desc);
create index if not exists reputation_manager_idx   on public.reputation_publishes (manager_address, created_at desc);

-- ── 4. The three live vaults (was 003) ──────────────────────────────────────
--
-- Read off chain 46630, not transcribed. `asset` for the rotation vault is
-- tokens[0], which is what ERC-4626 exposes and what a depositor pays in --
-- the tUSDG base it is MEASURED in is base_asset. Conflating those two is the
-- bug that made the old rotation vault pay out 2 for every 10 deposited.

insert into public.vaults
  (address, vault_type, name, symbol, asset, cash, base_asset, oracle, strategy, manager_address)
values
  ('0x11ea3629bb9ed5d1df8b5759ab6350bdbf3112b7', 'spot',
   'Zorpha tAAPL Long/Flat Vault', 'zqtAAPL',
   '0x3474995420f30A4CC461FE09E4e1B62cC3018ACF',
   '0x1C23B5181692C9A44C6652D7b35E58C1Cc70D735', NULL,
   '0x4264Be480B72cf6fa6B82aF3218ACa806f43C0Fc',
   'Long or flat a single equity, on a signed oracle-checked rebalance.',
   '0x65a35Fd2AFDC37696f1e02eF99E15a4d52d83485'),

  ('0x15257073a761021d37852453d4bde2fba8fcc9e6', 'rotation',
   'Zorpha Rotation Vault (tUSDG base)', 'zqROT',
   '0x3474995420f30A4CC461FE09E4e1B62cC3018ACF',
   NULL, '0x1C23B5181692C9A44C6652D7b35E58C1Cc70D735',
   '0x4264Be480B72cf6fa6B82aF3218ACa806f43C0Fc',
   'Rotates between approved real-world assets on a signed mandate.',
   '0x65a35Fd2AFDC37696f1e02eF99E15a4d52d83485'),

  ('0x521a90ba9a5afcda27db1bbb9cb93c3a2135b2d5', 'yield',
   'Zorpha tUSDG Yield Vault', 'zqtUSDG',
   '0x1C23B5181692C9A44C6652D7b35E58C1Cc70D735',
   NULL, NULL, NULL,
   'Allocates to an approved ERC-4626 venue.',
   '0x65a35Fd2AFDC37696f1e02eF99E15a4d52d83485')

on conflict (address) do update set
  vault_type      = excluded.vault_type,
  name            = excluded.name,
  symbol          = excluded.symbol,
  asset           = excluded.asset,
  cash            = excluded.cash,
  base_asset      = excluded.base_asset,
  oracle          = excluded.oracle,
  strategy        = excluded.strategy,
  manager_address = excluded.manager_address;

-- These three are real products, so make sure nothing above hid them.
update public.vaults
   set listed = true
 where lower(address) in (
   '0x11ea3629bb9ed5d1df8b5759ab6350bdbf3112b7',
   '0x15257073a761021d37852453d4bde2fba8fcc9e6',
   '0x521a90ba9a5afcda27db1bbb9cb93c3a2135b2d5'
 );

-- ── 5. Row-level security ───────────────────────────────────────────────────
--
-- The portal reads with the anon key from the browser, so every table needs a
-- public read policy or the app sees nothing. Writes stay closed: only the
-- indexer's service-role key, which bypasses RLS, may insert.
--
-- Without this the tables are readable by anyone with the anon key ONLY if RLS
-- is off, which is the wrong way round -- RLS off means writable too on some
-- configurations. Explicit beats default.

alter table public.vaults               enable row level security;
alter table public.managers             enable row level security;
alter table public.rebalances           enable row level security;
alter table public.reputation_publishes enable row level security;

do $$
begin
  if not exists (select 1 from pg_policies where tablename = 'vaults' and policyname = 'vaults_public_read') then
    create policy vaults_public_read on public.vaults for select using (true);
  end if;
  if not exists (select 1 from pg_policies where tablename = 'managers' and policyname = 'managers_public_read') then
    create policy managers_public_read on public.managers for select using (true);
  end if;
  if not exists (select 1 from pg_policies where tablename = 'rebalances' and policyname = 'rebalances_public_read') then
    create policy rebalances_public_read on public.rebalances for select using (true);
  end if;
  if not exists (select 1 from pg_policies where tablename = 'reputation_publishes' and policyname = 'reputation_public_read') then
    create policy reputation_public_read on public.reputation_publishes for select using (true);
  end if;
end $$;

-- ── 6. What you should see ──────────────────────────────────────────────────
-- Expect exactly three rows with listed = true, and any drill vaults false.

select symbol, name, vault_type, listed
  from public.vaults
 order by listed desc, deployed_at asc;

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
-- and `assertChainId()` (indexer/src/chain.ts:154) refuses to start when the
-- RPC's chain id disagrees with CHAIN_ID, so it cannot have written another
-- chain's rows. Only indexer/src/supabase.ts:164 writes this table -- nothing
-- else inserts rebalances -- so there is no second author to account for.
--
-- The guard below asserts that rather than trusting it, using block height as
-- the discriminator. The gap is enormous rather than marginal:
--
--   mainnet 4663 head,  measured 2026-09-05    55,201,684
--   lowest row in this table                  112,370,875
--   testnet 46630 head, measured 2026-09-05   113,517,929
--
-- Mainnet has never produced a block above 55.2M, so a row at 112M cannot have
-- happened there. The threshold is 60,000,000: clear of mainnet's head with
-- about two weeks of margin for it to advance before this file is applied, and
-- still 52M below the lowest real row.
--
-- AN EARLIER VERSION OF THIS GUARD USED START_BLOCK AND WAS WRONG. It asserted
-- `block_number >= 112522500` and aborted on real data. Railway's START_BLOCK
-- is 112,522,500 but the local indexer/.env is 111,911,103, and rows indexed by
-- the local config sit legitimately between the two. START_BLOCK is a
-- configuration value that has already changed three times (0 -> 111911103 ->
-- 112522500); it says nothing about which chain a row came from. Mainnet's head
-- does. The abort was the guard working, not the data being wrong.

begin;

-- ── Guard ──────────────────────────────────────────────────────────────────
do $$
declare
  stray bigint;
  lowest bigint;
begin
  select count(*), min(block_number) into stray, lowest
  from public.rebalances
  where block_number <= 60000000;

  if stray > 0 then
    raise exception
      'ABORT: % rebalance row(s) at or below block 60,000,000 (lowest %). '
      'Mainnet 4663 head was 55,201,684 on 2026-09-05, so a row that low may '
      'be a MAINNET row, and backfilling it to 46630 would mislabel history '
      'irreversibly. Investigate before re-running.',
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

-- Drop the new name too, so re-running this file is a no-op rather than an
-- error: Postgres has no `add constraint if not exists`.
alter table public.rebalances
  drop constraint if exists rebalances_chain_tx_log_key;

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

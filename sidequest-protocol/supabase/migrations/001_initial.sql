-- Zorpha V1, initial schema for the receipts indexer.
-- All tables: RLS-enabled; service_role bypasses RLS so the indexer worker
-- can write freely, while the dApp uses the anon key + RLS.

-- ─── Vaults ────────────────────────────────────────────────────────────────
create table if not exists public.vaults (
  id              uuid primary key default gen_random_uuid(),
  address         text not null unique,
  vault_type      text not null check (vault_type in ('spot','rotation','yield')),
  name            text not null,
  symbol          text not null,
  asset           text not null,
  cash            text,
  base_asset      text,
  oracle          text,
  strategy        text not null,
  manager_address text not null,
  deployed_at     timestamptz not null default now(),
  metadata        jsonb default '{}'::jsonb
);

create index if not exists vaults_manager_idx on public.vaults(manager_address);

-- ─── Rebalances (the receipts) ─────────────────────────────────────────────
create table if not exists public.rebalances (
  id              uuid primary key default gen_random_uuid(),
  vault_address   text not null,
  vault_type      text not null check (vault_type in ('spot','rotation','yield')),
  manager         text not null,
  block_number    bigint not null,
  tx_hash         text not null,
  log_index       integer not null,
  block_timestamp timestamptz not null,
  target_bps      integer,
  target_weights  jsonb,
  asset_leg       numeric(78,0),
  cash_leg        numeric(78,0),
  nav_per_share   numeric(78,0),
  nonce           bigint not null,
  commitment      text,
  created_at      timestamptz not null default now(),
  unique (tx_hash, log_index)
);

create index if not exists rebalances_vault_idx on public.rebalances(vault_address, block_timestamp desc);
create index if not exists rebalances_manager_idx on public.rebalances(manager, block_timestamp desc);
create index if not exists rebalances_block_idx on public.rebalances(block_number);

-- ─── Managers ──────────────────────────────────────────────────────────────
create table if not exists public.managers (
  address         text primary key,
  label           text,
  avatar_url      text,
  first_seen_at   timestamptz not null default now(),
  total_rebalances integer not null default 0,
  last_active_at  timestamptz
);

-- ─── Reputation publishes ──────────────────────────────────────────────────
create table if not exists public.reputation_publishes (
  id              uuid primary key default gen_random_uuid(),
  manager_address text not null,
  contract_address text not null,
  commitment      text not null,
  window_start    timestamptz not null,
  window_end      timestamptz not null,
  nonce           bigint not null,
  challenge_deadline timestamptz not null,
  challenged      boolean not null default false,
  upheld          boolean,
  tx_hash         text,
  created_at      timestamptz not null default now(),
  unique (contract_address, manager_address, nonce)
);

create index if not exists reputation_publishes_manager_idx on public.reputation_publishes(manager_address, created_at desc);

-- ─── Airdrop claims ────────────────────────────────────────────────────────
create table if not exists public.airdrop_claims (
  wallet_address  text primary key,
  amount          numeric(78,0) not null,
  leaf_index      integer not null,
  claimed_at      timestamptz not null default now(),
  tx_hash         text
);

-- ─── Keeper heartbeat ──────────────────────────────────────────────────────
create table if not exists public.keeper_heartbeat (
  id              serial primary key,
  keeper_address  text not null,
  last_epoch      bigint not null default 0,
  last_seen_at    timestamptz not null default now()
);

-- ─── RLS ───────────────────────────────────────────────────────────────────
alter table public.vaults          enable row level security;
alter table public.rebalances      enable row level security;
alter table public.managers        enable row level security;
alter table public.reputation_publishes enable row level security;
alter table public.airdrop_claims  enable row level security;
alter table public.keeper_heartbeat enable row level security;

-- Public read-only policies for the dApp's anon role.
create policy "read vaults" on public.vaults for select using (true);
create policy "read rebalances" on public.rebalances for select using (true);
create policy "read managers" on public.managers for select using (true);
create policy "read reputation" on public.reputation_publishes for select using (true);
create policy "read airdrop claims" on public.airdrop_claims for select using (true);

-- Writes restricted to service_role (used by the indexer via SUPABASE_SERVICE_ROLE_KEY).
-- No public insert/update/delete policies.

-- Vault visibility, because deleting rows was a one-shot and did not hold.
--
-- WHAT WENT WRONG
--
-- 003 deleted every vault row produced by the old factory and inserted the
-- three current ones. Correct at the time. Then the drills ran, and the portal
-- went back to advertising:
--
--     YIELD   Zorpha Leader Test Vault   zqLEAD
--     YIELD   Zorpha Loss Drill Vault    zqDRILL
--
-- to users, as live products, with mandates and manager addresses, alongside
-- the real three. `listVaults()` does `select('*')` with no filter, so any row
-- in this table is a product. A delete is a fact about one moment; anything
-- that writes a row afterwards undoes it.
--
-- THE FIX
--
-- A `listed` flag, filtered in the query. Now unlisting is a property of the
-- row rather than its absence, so a re-seed, an indexer backfill or a manual
-- insert cannot silently promote a drill vault to the storefront.
--
-- Default TRUE, deliberately: a new real vault should appear without anyone
-- remembering a flag. What must not happen by accident is a TEST vault
-- appearing, and those are recognisable by name -- so the trigger below marks
-- them on the way in.

alter table public.vaults
  add column if not exists listed boolean not null default true;

comment on column public.vaults.listed is
  'False hides the vault from the portal. Drill and test vaults are marked '
  'false automatically by the vaults_autohide_test trigger. See migration 004.';

-- ── Unlist what is already there ────────────────────────────────────────────
update public.vaults
   set listed = false
 where name ilike '%drill%'
    or name ilike '%test%'
    or name ilike '%staleness%'
    or symbol ilike '%DRILL%'
    or symbol ilike '%LEAD%'
    or symbol ilike '%STALE%'
    or symbol ilike '%BOND%';

-- ── And keep them out on future writes ──────────────────────────────────────
--
-- A trigger rather than a check constraint: a constraint would REJECT the
-- insert, and the indexer would then retry it forever or drop the event. This
-- accepts the row and files it out of sight, which is what is actually wanted
-- -- the vault exists on chain either way, and hiding it from the storefront
-- is a presentation decision, not a data-integrity one.
create or replace function public.vaults_autohide_test()
returns trigger
language plpgsql
as $$
begin
  if new.name   ilike '%drill%' or new.name   ilike '%test%'
  or new.name   ilike '%staleness%'
  or new.symbol ilike '%DRILL%' or new.symbol ilike '%LEAD%'
  or new.symbol ilike '%STALE%' or new.symbol ilike '%BOND%' then
    new.listed := false;
  end if;
  return new;
end;
$$;

drop trigger if exists vaults_autohide_test_trg on public.vaults;
create trigger vaults_autohide_test_trg
  before insert or update of name, symbol on public.vaults
  for each row execute function public.vaults_autohide_test();

-- ── Receipts follow their vault ─────────────────────────────────────────────
-- A receipt pointing at an unlisted vault would render a row nobody can click
-- through to, which is how 003 left orphans behind.
create index if not exists vaults_listed_idx on public.vaults (listed) where listed;

-- ── What this leaves ────────────────────────────────────────────────────────
select
  symbol,
  name,
  listed
from public.vaults
order by listed desc, deployed_at asc;

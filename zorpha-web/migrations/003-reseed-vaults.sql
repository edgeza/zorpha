-- SUPERSEDED BY 005-baseline.sql. DO NOT RUN THIS FILE.
--
-- Kept for history. It is folded into 005 verbatim, and 005 is
-- idempotent, so running 005 after this one changes nothing.
--
-- This file was numbered as though 001 and 002 existed. They did not --
-- the schema was created outside the repo, so there was no definition of
-- it anywhere and "run migration 004" was not a followable instruction.
-- 005 is the whole schema plus this content, in one runnable file.

-- Re-seed the vaults table after the vault-layer redeploy.
--
-- WHY EVERY OLD ROW GOES
--
-- VaultFactory compiles the vault bytecode into itself, so every vault the
-- previous factory produced carries pre-fix code: the rotation units bug that
-- returned 2 of 10 deposited, the fee-claim backing bug, the equalisation
-- overcharge, and the emergency exit that forfeited the cash leg. They are
-- immutable, so none of that can be repaired in place.
--
-- They still work well enough to take a deposit, which is exactly why they must
-- not stay listed. All of them hold nothing (totalSupply 0) except
-- 0x76033fdf, which holds 10 tAAPL from a drill that died mid-run.
--
-- The two leader vaults (zqLEAD, zqDRILL) came out of the same old factory and
-- go for the same reason.

begin;

delete from public.vaults where lower(address) in (
  lower('0x95fb9f67b0f54d38e5ce6dfbf8aaeb6d03873708'),
  lower('0x6cb2a47bf911b7eed21a7b16d90c89986daa44e8'),
  lower('0x9d03c7dc64dce712c1e004c3106892677bd844a8'),
  lower('0xdf4e5f500f9f66314dd90bd92eea214945446c8e'),
  lower('0x76033fdf9b098ce60cf73b08e20b058e043eae99'),
  lower('0xFC419db436392FCeBAA537257557E80636Cc08Ff'),
  lower('0xE213A1f5f4Ef37eB74D0D680b60ADa68CA2c9ba3')
);

-- And the receipts that pointed at them, so the feed does not show trades
-- on vaults nobody can reach from the portal.
delete from public.rebalances where lower(vault_address) not in (
  lower('0x11ea3629bb9ed5d1df8b5759ab6350bdbf3112b7'),
  lower('0x15257073a761021d37852453d4bde2fba8fcc9e6'),
  lower('0x521a90ba9a5afcda27db1bbb9cb93c3a2135b2d5')
);

-- The three replacements, from the new factory.
insert into public.vaults
  (address, vault_type, name, symbol, asset, cash, base_asset, oracle, strategy, manager_address)
values
  ('0x11ea3629bb9ed5d1df8b5759ab6350bdbf3112b7', 'spot', 'Zorpha tAAPL Long/Flat Vault', 'zqtAAPL', '0x3474995420f30A4CC461FE09E4e1B62cC3018ACF',
   '0x1C23B5181692C9A44C6652D7b35E58C1Cc70D735', NULL, '0x4264Be480B72cf6fa6B82aF3218ACa806f43C0Fc', 'Long or flat a single equity, on a signed oracle-checked rebalance.', '0x65a35Fd2AFDC37696f1e02eF99E15a4d52d83485')
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

insert into public.vaults
  (address, vault_type, name, symbol, asset, cash, base_asset, oracle, strategy, manager_address)
values
  ('0x15257073a761021d37852453d4bde2fba8fcc9e6', 'rotation', 'Zorpha Rotation Vault (tUSDG base)', 'zqROT', '0x3474995420f30A4CC461FE09E4e1B62cC3018ACF',
   NULL, '0x1C23B5181692C9A44C6652D7b35E58C1Cc70D735', '0x4264Be480B72cf6fa6B82aF3218ACa806f43C0Fc', 'Rotates between approved real-world assets on a signed mandate.', '0x65a35Fd2AFDC37696f1e02eF99E15a4d52d83485')
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

insert into public.vaults
  (address, vault_type, name, symbol, asset, cash, base_asset, oracle, strategy, manager_address)
values
  ('0x521a90ba9a5afcda27db1bbb9cb93c3a2135b2d5', 'yield', 'Zorpha tUSDG Yield Vault', 'zqtUSDG', '0x1C23B5181692C9A44C6652D7b35E58C1Cc70D735',
   NULL, NULL, NULL, 'Allocates to an approved ERC-4626 venue.', '0x65a35Fd2AFDC37696f1e02eF99E15a4d52d83485')
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

insert into public.vaults
  (address, vault_type, name, symbol, asset, cash, base_asset, oracle, strategy, manager_address)
values
  ('0xFC419db436392FCeBAA537257557E80636Cc08Ff', 'yield', 'Zorpha Leader Test Vault', 'zqLEAD', '0x1C23B5181692C9A44C6652D7b35E58C1Cc70D735',
   NULL, NULL, NULL, 'Allocates to an approved ERC-4626 venue. Leader-launched, with first-loss capital posted behind depositors.', '0x613ab528E46fCeD27350465E338354776B2a790a')
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

insert into public.vaults
  (address, vault_type, name, symbol, asset, cash, base_asset, oracle, strategy, manager_address)
values
  ('0xE213A1f5f4Ef37eB74D0D680b60ADa68CA2c9ba3', 'yield', 'Zorpha Loss Drill Vault', 'zqDRILL', '0x1C23B5181692C9A44C6652D7b35E58C1Cc70D735',
   NULL, NULL, NULL, 'Allocates to an approved ERC-4626 venue. Leader-launched, with first-loss capital posted behind depositors.', '0x613ab528E46fCeD27350465E338354776B2a790a')
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


commit;

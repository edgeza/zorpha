-- 010, list the mainnet vault, retire the testnet ones the portal was serving.
--
-- WHAT WENT WRONG
--
-- `vaults` has no chain column. Columns are address, vault_type, name, symbol,
-- asset, cash, base_asset, oracle, strategy, manager_address, listed,
-- deployed_at -- nothing says which network a row belongs to. One Supabase
-- instance serves both deployments, so pointing the web app at mainnet changed
-- the RPC and the contract addresses in config but did NOT change the vault
-- list: `listVaults()` kept returning the three testnet rows migration 008
-- registered.
--
-- The result was live on www.zorpha.xyz/portal/vaults: three vaults advertised
-- to mainnet visitors, none of which has any code at its address on chain 4663.
-- Someone who picked one and deposited would have been sending funds at an
-- empty address. Verified with `cast code` against 4663 -- all three return 0x.
--
-- THIS IS A STOPGAP, NOT THE FIX
--
-- Because the table still cannot distinguish networks, this migration is
-- correct only while production points at mainnet. Run the app against testnet
-- 46630 after this and it will show the mainnet vault, which is the same bug
-- mirrored. The real fix is a chain_id column with listVaults() filtering on
-- it, and 008's own header names the other half of the problem:
-- `upsertVault` exists but is never called, so nothing registers a vault
-- automatically or reconciles the list against the chain the site targets.
--
-- Mainnet is what is public and can mislead a stranger; testnet is internal.
-- So this optimises for mainnet correctness deliberately, and says so.

begin;

-- The three testnet vaults migration 008 listed. No code at these addresses on
-- chain 4663. Hidden rather than deleted: their receipts are real history on
-- 46630 and the feed should not develop gaps.
update public.vaults set listed = false
where lower(address) in (
  lower('0xaA7A513F2B4C35d727b16fc7233CC8C9faCE886F'),  -- Zorpha tAAPL Long/Flat
  lower('0xB003d9fd5BFf783A3d62801f45BE7afF62ef0A61'),  -- Zorpha Rotation (tUSDG base)
  lower('0x5c2dD1F051d96C8025123827A02f9875Ab311D1e')   -- Zorpha tUSDG Yield
);

-- The vault that actually exists on mainnet, launched 2026-09-05 10:09:05 UTC
-- (block 55038004) through VaultLauncher. Values read from the contract, not
-- from the launch script:
--
--   name()   "Zorpha Steakhouse USDG"
--   symbol() "zsUSDG"
--   asset()  0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168 (USDG, 6dp)
--
-- oracle is NULL because a yield vault prices from its ERC-4626 target rather
-- than a feed -- that is why this vault could launch on a deployment with no
-- MedianOracle. cash and base_asset are NULL for the same reason they are on
-- the testnet yield vault: neither concept applies.
--
-- manager_address is the governance Safe, which is this vault's leader: it
-- posted the 10,000 ZOR bond and the 90 USDG first-loss escrow, so it is the
-- address whose capital is at risk before any depositor's.
insert into public.vaults
  (address, vault_type, name, symbol, asset, cash, base_asset, oracle, strategy, manager_address, listed)
values
  ('0x3829bC787d4eB15Ec855A6cA33e1492a9103d130', 'yield',
   'Zorpha Steakhouse USDG', 'zsUSDG',
   '0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168',   -- USDG, 6dp
   NULL, NULL, NULL,
   'Routes USDG into Steakhouse USDG and reports its position honestly. A first-loss escrow funded by the vault leader absorbs losses before any depositor does.',
   '0xC75E64Ccf3ce6E2F40939Ab58255681769BcF8C4', true)

on conflict (address) do update set
  vault_type      = excluded.vault_type,
  name            = excluded.name,
  symbol          = excluded.symbol,
  asset           = excluded.asset,
  cash            = excluded.cash,
  base_asset      = excluded.base_asset,
  oracle          = excluded.oracle,
  strategy        = excluded.strategy,
  manager_address = excluded.manager_address,
  listed          = true;

commit;

-- AFTER RUNNING THIS
--
-- /portal/vaults should list exactly one vault, zsUSDG, and its address should
-- resolve on robinhoodchain.blockscout.com. If any 0xaA7A…, 0xB003… or
-- 0x5c2d… address still appears, the update did not match -- check the address
-- casing, since the filter lowercases both sides for exactly that reason.
--
-- NEXT_PUBLIC_ENABLE_VAULT_DEPOSITS stays false until the chain-aware fix
-- lands. The flag is currently the only thing preventing a deposit attempt
-- against a row this table cannot prove belongs to the connected network.

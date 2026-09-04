-- 008 — register the 5 September 2026 vaults, retire everything before them.
--
-- The indexer takes its vault list from THIS TABLE, not from VAULT_ADDRESSES:
-- that variable is read only by the DRY_RUN path, and `upsertVault` exists but
-- is never called, so nothing registers a vault automatically. Setting the
-- Railway variable after a redeploy does nothing at all, which is why the
-- previous generation kept being served while the live vaults stayed invisible.
-- The indexer now warns each cycle when the two disagree; this file is the
-- other half.
--
-- WHY THE PREVIOUS GENERATION GOES
--
-- Every vault before this one carries at least one of:
--
--   - a rotation basket led by the EQUITY rather than the base asset, so
--     asset() was tAAPL: depositors could only enter holding the stock, were
--     redeemed in the stock, and the vault could never take a first-loss
--     escrow, because absorb() would have to sell the buffer through a venue
--     mid-redemption. Manager-loses-first is the product; that vault could not
--     offer it.
--   - an executor whose authorizedSigner was the DEPLOY KEY. Not a role, so
--     the handover that renounced ten roles left it untouched.
--
-- Both are fixed in the deployment below and asserted at deploy time. Neither
-- is repairable in place: the factory compiles vault bytecode into itself, and
-- authorizedSigner belongs to an executor that is already handed over.
--
-- Hidden rather than deleted. Their receipts are real history and the feed
-- should not develop gaps; `listed = false` takes them out of the portal index
-- while leaving the record intact.

begin;

-- Everything from before today.
update public.vaults set listed = false
where lower(address) not in (
  lower('0xaA7A513F2B4C35d727b16fc7233CC8C9faCE886F'),
  lower('0xB003d9fd5BFf783A3d62801f45BE7afF62ef0A61'),
  lower('0x5c2dD1F051d96C8025123827A02f9875Ab311D1e')
);

insert into public.vaults
  (address, vault_type, name, symbol, asset, cash, base_asset, oracle, strategy, manager_address, listed)
values
  -- Long or flat a single equity. asset() is the equity here BY DESIGN: a spot
  -- vault is a position in one thing, and the cash leg is where it sits when
  -- flat. That is not the rotation bug.
  ('0xaA7A513F2B4C35d727b16fc7233CC8C9faCE886F', 'spot',
   'Zorpha tAAPL Long/Flat Vault', 'zqtAAPL',
   '0x42CCF90C8eA6674b25e5D9cc7578aC666C0f3bAa',   -- tAAPL, 18dp
   '0x558b01784570740577A207A2Fc9D5063B371697e',   -- tUSDG, 6dp
   NULL,
   '0xd6b033fe4907925545304997f0712Ff32cFEfBf2',
   'Long or flat a single equity, on a signed oracle-checked rebalance.',
   '0x613ab528E46fCeD27350465E338354776B2a790a', true),

  -- Cash-denominated basket: tokens[0] IS the base asset, so asset() is tUSDG
  -- and depositors pay in and are redeemed in dollars. Launches flat at
  -- 10000/0/0 -- the weights are a target the keeper moves toward, so the vault
  -- takes no market view its governance did not choose.
  ('0xB003d9fd5BFf783A3d62801f45BE7afF62ef0A61', 'rotation',
   'Zorpha Rotation Vault (tUSDG base)', 'zqROT',
   '0x558b01784570740577A207A2Fc9D5063B371697e',   -- asset() == base
   NULL,
   '0x558b01784570740577A207A2Fc9D5063B371697e',
   '0xd6b033fe4907925545304997f0712Ff32cFEfBf2',
   'Rotates between cash and approved real-world assets on a signed mandate.',
   '0x613ab528E46fCeD27350465E338354776B2a790a', true),

  ('0x5c2dD1F051d96C8025123827A02f9875Ab311D1e', 'yield',
   'Zorpha tUSDG Yield Vault', 'zqtUSDG',
   '0x558b01784570740577A207A2Fc9D5063B371697e',
   NULL, NULL, NULL,
   'Routes deposits into a curated ERC-4626 venue and reports its position honestly.',
   '0x613ab528E46fCeD27350465E338354776B2a790a', true)

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

-- manager_address is governance, which is also the executor's authorizedSigner
-- on this deployment -- the address whose EIP-712 signature actually authorises
-- a rebalance. Attribution therefore names whoever really signs, rather than
-- the keeper that submits: submission is permissionless, and crediting the
-- sender would misstate authorship on a protocol whose product is a track
-- record. A leader-launched vault carries its own leader instead.

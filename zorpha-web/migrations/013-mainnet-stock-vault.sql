-- 013, register the oracle-free NVDA long/flat vault on mainnet 4663.
--
-- WHY A ROW IS REQUIRED AND NOT MERELY TIDY
--
-- The indexer reads its vault list from THIS TABLE, not from VAULT_ADDRESSES.
-- indexer/src/index.ts warns and skips for any address in the env var that has
-- no row here, and logs "no vaults registered yet, nothing to index" when the
-- table is empty. So a vault absent from this table emits Rebalanced events
-- that nothing copies into `rebalances`, and /portal/receipts shows an empty
-- track record for a manager who has been trading.
--
-- That is not a cosmetic gap. The protocol's whole claim is "a track record you
-- can verify", and this row is what makes the claim true for this vault. It is
-- also why /portal/vaults currently lists zsUSDG and not zqNVDA: that page
-- reads from here, not from the chain and not from an environment variable.
--
-- Deployed 6 September 2026 on chain 4663:
--
--     UniswapV3TwapAdapter         0xaBefb351777d8E68FCafa4D2F8A5848F326298cA  block 56247943
--     SpotVaultMinimal (zqNVDA)    0xB129495f0ad616EdD2f28b3B49470FC1f0FAD413  block 56247975
--     RobinhoodChainRouterAdapter  0x8E50FC336f87b454cc44a89dA3a7267412B045dc  block 56248007
--
-- Values below were read back from the contracts rather than copied from the
-- deploy script: name() "Zorpha NVDA Long/Flat", symbol() "zqNVDA",
-- asset() NVDA, cashAsset() USDG, oracle() the adapter above.
--
-- oracle IS populated here, unlike the yield vault's NULL. A yield vault prices
-- from its ERC-4626 target and needs no feed, which is how zsUSDG launched on a
-- deployment that had no oracle at all. This one prices through a
-- UniswapV3TwapAdapter, and recording WHICH adapter matters: the answer is only
-- meaningful together with the pool it was read from.
--
-- manager_address is the governance Safe. It holds KEEPER_ROLE on this vault,
-- so it is the address that will appear as the signer on every receipt. Note
-- that is a different reason from zsUSDG, where the Safe is named because it
-- posted the bond and the first-loss escrow.

begin;

-- deployed_at is set EXPLICITLY rather than left to its now() default. The
-- default is when this migration RAN, not when the contract was created, and
-- the portal renders it as "Deployed <date>". Running this on 7 September put
-- "Deployed Sep 7, 2026" on a vault that has existed since the 6th, which is a
-- small false statement of exactly the kind the rest of this work was spent
-- removing. Value below is the timestamp of block 56247975, read from the
-- chain: 1788724969.
insert into public.vaults
  (chain_id, address, vault_type, name, symbol, asset, cash, base_asset, oracle,
   strategy, manager_address, listed, deployed_at)
values
  (4663,
   '0xB129495f0ad616EdD2f28b3B49470FC1f0FAD413',
   'spot',
   'Zorpha NVDA Long/Flat',
   'zqNVDA',
   '0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC',   -- NVDA, 18dp
   '0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168',   -- USDG, 6dp
   NULL,                                            -- base_asset is a rotation concept
   '0xaBefb351777d8E68FCafa4D2F8A5848F326298cA',   -- UniswapV3TwapAdapter
   'Long or flat on tokenized NVDA. The manager sets one number: how much of the vault sits in NVDA and how much in USDG. Priced by a 30-minute time-weighted average of the same Uniswap pool the trades clear against, so a price that fools the accounting also gives the attacker a bad fill.',
   '0xC75E64Ccf3ce6E2F40939Ab58255681769BcF8C4',   -- governance Safe, holds KEEPER_ROLE
   true,
   '2026-09-06T20:02:49Z')                          -- block 56247975

-- The primary key has been (chain_id, address) since migration 012, because the
-- same address can exist on both chains and CREATE2 makes that likely rather
-- than theoretical. Naming only `address` here would fail to match and insert a
-- duplicate row.
on conflict (chain_id, address) do update set
  vault_type      = excluded.vault_type,
  name            = excluded.name,
  symbol          = excluded.symbol,
  asset           = excluded.asset,
  cash            = excluded.cash,
  base_asset      = excluded.base_asset,
  oracle          = excluded.oracle,
  strategy        = excluded.strategy,
  manager_address = excluded.manager_address,
  listed          = true,
  deployed_at     = excluded.deployed_at;

-- ─── The cursor, and the casing trap ────────────────────────────────────────
--
-- A vault with no cursor row starts its scan at the GLOBAL START_BLOCK:
--
--     const from = stored === null ? config.startBlock : stored + 1n;
--
-- There is one START_BLOCK for the whole indexer, not one per vault, and it is
-- set for zsUSDG which launched at block 55038004. Without the row below, this
-- vault would rescan roughly 1.2 million blocks it cannot possibly have events
-- in, on an RPC that already times out on wide log queries. Seeding the cursor
-- at the block before deployment makes the first scan start where the contract
-- actually begins.
--
-- THE CASING MUST MATCH EXACTLY. getCursor does:
--
--     .eq('source_address', address)
--
-- a literal string comparison with no lower() on either side, and `address`
-- comes from the `vaults` row above. So the two addresses have to agree
-- character for character. Get it wrong and getCursor returns null, the scan
-- silently restarts from START_BLOCK, and nothing anywhere reports a problem:
-- the indexer looks healthy, just slow, which is the worst shape a fault can
-- take. Both are the EIP-55 checksummed form, matching migration 010.
--
-- 56247974 rather than 56247975, because the scan resumes at `stored + 1`.

insert into public.indexer_cursor
  (chain_id, source_kind, source_address, last_block, last_run_at, last_error, error_count)
values
  (4663, 'vault', '0xB129495f0ad616EdD2f28b3B49470FC1f0FAD413', 56247974, now(), null, 0)
on conflict (chain_id, source_kind, source_address) do nothing;

commit;

-- SAFE TO RE-RUN, and it was re-run once on purpose: the first pass left
-- deployed_at on its now() default and the portal duly said "Deployed Sep 7"
-- for a contract created on the 6th. The vault row updates on conflict, so a
-- second pass corrects it; the cursor does not, so a second pass cannot drag
-- the indexer backwards.
--
-- AFTER RUNNING THIS
--
-- /portal/vaults should list two vaults on mainnet, zsUSDG and zqNVDA, with
-- zqNVDA showing "Deployed Sep 6, 2026", and the indexer's next cycle should
-- report vaultsTracked 2 rather than 1.
--
-- /portal/receipts will still say "No rebalance has been signed yet", and that
-- is correct rather than a fault: rebalanceCount() on the vault reads 0. The
-- first receipt appears when the Safe signs the first rebalanceTo, and the copy
-- on that empty state already says so.
--
-- The `on conflict ... do nothing` on the cursor is deliberate. Re-running this
-- migration must never drag a cursor BACKWARDS to 56247974 after the indexer
-- has advanced it, which would re-scan and re-insert; the unique (tx_hash,
-- log_index) on `rebalances` would reject the duplicates, but the work and the
-- error noise are pointless. The vault row above does update on conflict,
-- because correcting a name or a strategy string is exactly what a re-run is
-- for.

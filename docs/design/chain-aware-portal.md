# Chain-aware portal: design

Date: 5 September 2026
Status: approved design, not yet planned or implemented
Scope: `zorpha-web` query layer, Supabase schema, `sidequest-protocol/indexer`

## Problem

One Supabase project serves both Robinhood Chain deployments, and **no table
records which chain a row belongs to**. Tables are `vaults`, `rebalances`,
`managers`, `reputation_publishes`; none carries a chain identifier.

Pointing the web app at mainnet therefore changed the RPC and the contract
addresses in config, but not the data. This shipped:

> `www.zorpha.xyz/portal/vaults` advertised three vaults, `0xaA7A513F…`,
> `0xB003d9fd…`, `0x5c2dD1F0…`, to mainnet visitors. `cast code` against
> chain 4663 returns `0x` for all three. They are testnet contracts. Anyone who
> picked one and deposited would have been sending funds at an empty address.

Migration `010` unlists those three and registers the real vault, but that is a
stopgap that is only correct while production points at mainnet. It says so in
its own header.

The codebase already diagnosed both halves of this before today:

- `indexer/src/chain.ts:154`, `assertChainId()` refuses to index when the RPC's
  chain id disagrees with `CHAIN_ID`, because *"a misconfigured URL would
  otherwise poison the database with another chain's data, which is far harder
  to detect after the fact than at startup."* **The web app has no equivalent.**
- `indexer/src/index.ts:277`, *"upsertVault exists and is never called, so
  there is no code path that registers a vault. Registration is a hand-written
  SQL insert, and that is exactly the step that gets forgotten after a
  redeploy."*

The guard is why nothing is currently corrupted: `CHAIN_ID` was set to `4663`
while `RPC_URL` still pointed at testnet, so the indexer has been refusing to
start rather than writing mainnet-shaped rows into a testnet-shaped table.

## Design

The two halves need different solutions, because they differ in whether the
chain is derivable.

### 1. A receipt's chain cannot be derived; so store it

A `rebalances` row is a historical fact: a `tx_hash` at a `block_number` with a
`nav_per_share`. Nothing in it says which network it happened on, and nothing
ever will. The same is true of `managers` (whose `total_rebalances` currently
aggregates across both chains) and `reputation_publishes`.

Add `chain_id integer not null` to `rebalances`, `managers`,
`reputation_publishes` and `indexer_cursor`, and backfill every existing row
to **46630**. Every row
written to date is testnet: the indexer has only ever run against testnet, and
`START_BLOCK` (`112522500`) is a testnet height, above mainnet's current head
of ~55.1M; so no mainnet row can exist.

`managers` needs its primary key widened from `address` to
`(address, chain_id)`: the same manager address can act on both chains and its
`total_rebalances` must not merge them.

`rebalances` carries `unique (tx_hash, log_index)`; the natural key for "one
row per log, so a re-indexed block cannot duplicate the feed". That key is
chain-blind. A cross-chain transaction-hash collision is not a practical
concern, but the constraint states a semantic that is now wrong: uniqueness is
per chain. Widen it to `(chain_id, tx_hash, log_index)` so the schema says what
it means.

`indexer_cursor` matters more than it looks. `START_BLOCK` is read **only
when no cursor exists** (`indexer/src/index.ts:107`):

    const stored = await getCursor('vault', vault.address);
    const from = stored === null ? config.startBlock : stored + 1n;

The stored cursors sit at testnet heights (~112M). Repoint to mainnet without
touching them and the indexer resumes from 112,522,501 against a chain whose
head is ~55.1M: it scans nothing, inserts nothing, and reports success. Fixing
the environment variables alone does not work, and the failure is silent , 
strictly worse than the honest crash the chain-id mismatch currently produces.

Every read in `lib/queries.ts` filters on the connected chain. Every indexer
write sets it from `config.chainId`, which `assertChainId()` has already proven
matches the RPC.

### 2. A vault's chain CAN be derived; so stop storing it

Either the contract exists on the connected chain or it does not. The chain is
the authority, and the database has repeatedly been wrong about it.

`listVaults()` enumerates from `VaultLauncher` on the connected chain:

```
launchCount() -> uint256
launches(uint256) -> (address vault, address escrow, address adapter,
                      address leader, address asset, uint256 bond,
                      uint64 createdAt, bool bondReleased, bool bondSlashed)
```

The `vaults` table stops being a source of truth about existence and becomes
presentation metadata only, `strategy` prose, `name` overrides, and the
`listed` flag for hiding drill vaults, joined by address. A vault with no row
still renders, with its on-chain name and no prose. **Registration stops being
a step anyone can forget**, which is the failure `index.ts:277` describes.

Two things this does not cover, stated rather than discovered later:

- Vaults deployed outside `VaultLauncher` (directly through `VaultFactory`)
  will not enumerate. On mainnet today that set is empty, `launchCount()` is
  1 and it is the zsUSDG vault; and the launcher is the only supported path.
- `launches(uint256)` returns a **nine-field** struct. Decoding it with a
  shorter signature silently shifts every field: during the launch it was
  decoded with five and reported the escrow address as the vault. The
  implementation must use the full signature and a test must assert the
  mapping.

### 3. The web app needs the guard the indexer already has

Add the `assertChainId()` equivalent to `zorpha-web`: on server-rendered portal
routes, compare `NEXT_PUBLIC_CHAIN_ID` against the chain id the configured RPC
actually answers with, and fail loudly on mismatch rather than rendering.

The indexer refuses to write another chain's data. The web app should refuse to
render it. Today it is the asymmetry between those two that reached users.

### 4. The indexer's mainnet configuration is testnet-shaped

Repointing it is part of this work, not a prerequisite. Current values and what
each must become:

| Setting | Now | Required for 4663 |
|---|---|---|
| `RPC_URL` | testnet RPC (answers 46630) | mainnet RPC |
| `CHAIN_ID` | `4663` | `4663` (already correct; this mismatch is what halted it) |
| `START_BLOCK` | `112522500` | the block `Zorpha` was deployed at; the current value is above mainnet's head, so the indexer would scan nothing and look healthy |
| `EXPLORER_URL` | testnet explorer | `https://robinhoodchain.blockscout.com` |
| `VAULT_ADDRESSES` | three addresses matching neither the table nor the chain | removed, after §2 nothing reads it outside dry-run |

Flipping `RPC_URL` alone is worse than the current halt: the guard would pass
and the indexer would scan from a block above the head, indexing nothing while
reporting success.

## Migration order

Ordered so the database is never in a state where a read cannot tell chains
apart:

1. Add `chain_id` to the three data tables, defaulting to `46630`, and backfill.
   Safe while the indexer is stopped and nothing writes.
2. Widen the `managers` primary key to `(address, chain_id)`.
3. Ship the query-layer filters and the web-app chain guard.
4. Ship the vault enumeration, retiring `vaults` to presentation-only.
5. Repoint the indexer with all five settings changed together, and only then
   restart it.

Steps 1–4 are safe with the indexer stopped. Step 5 is the only one that
resumes writes, and by then every reader filters.

## Verification

- After step 1: every existing row reads `chain_id = 46630`, count unchanged.
- After step 3: with `NEXT_PUBLIC_CHAIN_ID=4663`, `/portal/receipts` and
  `/portal/leaderboard` render empty rather than showing testnet history; with
  `46630` they render the existing history unchanged.
- After step 4: `/portal/vaults` lists exactly the vaults `launchCount()`
  reports for the connected chain; one on mainnet (zsUSDG,
  `0x3829bC787d4eB15Ec855A6cA33e1492a9103d130`), and a test asserts
  `launches(0)` maps to the vault address and not the escrow.
- After step 5: the indexer starts, `assertChainId()` passes, and the first
  indexed block is at or after the token's deployment block.
- The route crawl from the visual-foundation plan continues to pass.

## Risks

- **The backfill assumes every existing row is testnet.** Justified by
  `START_BLOCK` being a testnet height and the indexer never having run against
  mainnet, but it is an assumption about history that cannot be re-derived
  later. It should be asserted before the backfill: any row whose
  `block_number` exceeds mainnet's head at migration time would contradict it.
- **On-chain enumeration puts an RPC read on a server-rendered page.** The
  route already sets `revalidate = 60`, so it is cached, but an RPC outage
  becomes an empty vault list rather than a stale one. The empty state must
  distinguish "no vaults" from "could not reach the chain".
- **Widening the `managers` primary key rewrites the table.** No foreign keys
  reference it, `005-baseline.sql` declares none anywhere in the schema; so
  this is a rewrite without dependents, which is the cheap case. The plan should
  still re-check before altering, since the schema may have drifted from the
  migrations.

## Out of scope

- Deposits stay disabled (`NEXT_PUBLIC_ENABLE_VAULT_DEPOSITS=false`) until all
  five steps land. The flag is currently the only thing preventing a deposit
  against a row whose chain the table cannot prove.
- Testnet history is retained, not deleted. It is real history for 46630 and
  becomes correct once tagged.
- The keeper service is testnet-only and unaffected.

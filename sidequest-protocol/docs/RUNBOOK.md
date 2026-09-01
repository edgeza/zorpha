# Zorpha V1 — Operator Runbook

This is the canonical runbook for the people running Zorpha V1. It mirrors
the ZENTORY `docs/RUNBOOK.md` shape.

## 1. Architecture quick reference

```
          ┌────────────────────────────────────────┐
          │   Governance (Safe → Timelock → Exec)  │
          └────────┬───────────────────────────────┘
                   │ role admin
                   ▼
   ┌────────────────────────────────────────────┐
   │ VaultFactory · ReputationRegistry · Exec   │
   └────────┬───────────────────────────────┬───┘
            │                               │
            ▼                               ▼
   ┌────────────────┐               ┌────────────────┐
   │ 3 Vaults       │               │ StrategyExec   │
   │  Spot · Rot ·  │ ◀─KEEPER_ROLE─ │ (EIP-712)      │
   │  Yield         │               └────────────────┘
   └────────────────┘
            │ events (Rebalanced)
            ▼
   ┌────────────────────────────────────────────┐
   │ Supabase indexer (Railway cron)            │
   └────────┬───────────────────────────────┬───┘
            │ rebalances table              │ manager stats
            ▼                               ▼
   ┌────────────────────────────────────────────┐
   │ Next.js dApp (Vercel)                      │
   └────────────────────────────────────────────┘
```

## 2. Daily operations

### 2.1 Check indexer health

The indexer writes to `public.keeper_heartbeat` on every successful poll
(this includes "no events found" polls). To check freshness:

```sql
select keeper_address, last_seen_at
from public.keeper_heartbeat
order by last_seen_at desc
limit 10;
```

`last_seen_at` should be within `poll_interval_ms + 30s` of `now()`.

If it's stale, check:

1. Railway cron logs for the worker (`[indexer] FATAL: ...` lines).
2. RH testnet RPC availability (`curl $RH_TESTNET_RPC_URL -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"eth_chainId","id":1}'`).
3. Supabase service-role key (rotate if leaked).

### 2.2 Verify a rebalance made it

Every rebalance emits `Rebalanced(targetBps, assetLeg, cashLeg, navPerShare, nonce, commitment)`.
To verify a specific manager's rebalance was indexed:

```sql
select block_number, tx_hash, target_bps, nav_per_share, block_timestamp
from public.rebalances
where manager = '0x...'
order by block_timestamp desc
limit 10;
```

If it's not there:

1. Check the tx_hash on the RH explorer — was it actually mined?
2. Check the indexer's `getLastIndexedBlock(vault_address)` for the vault — it
   might be lagging.
3. Check the indexer's `chainId` assertion — if it's serving the wrong
   chain, the worker bails out and exits non-zero.

### 2.3 Verify a reputation publish

```sql
select commitment, window_start, window_end, challenged, upheld, tx_hash
from public.reputation_publishes
where manager_address = '0x...'
order by created_at desc
limit 10;
```

## 3. Common incidents

### 3.1 Stale oracle across all vaults

**Symptom**: `rebalanceTo` reverts with `StaleOracle`. No new rebalances are
indexed for >1h.

**Action**:
1. Check the configured oracle address on each vault. Is the upstream feed
   stale or paused?
3. As a stop-gap, the risk-council can call `setCircuitBreaker(true)` on the
   affected vault to pause deposits but still allow redemptions (the standard
   ERC-4626 path will revert on `cashToAsset`; users can use `redeemEmergency`
   to bypass the oracle).
4. Once the oracle recovers, unset the breaker.

### 3.2 Vault NAV goes to zero

**Symptom**: `totalAssets()` returns 0. `maxDeposit()` returns 0 (deposits
blocked). Existing holders cannot `redeem` because `_withdraw` reverts on
the oracle path.

**Action**:
1. Use `redeemEmergency` to drain the vault by underlying balance
   (oracle-bypassing). This will issue haircuts — the `haircutAssets` field
   on the `EmergencyRedeem` event makes them auditable.
2. Root-cause the oracle or adapter failure.
3. Once recovered, evaluate fees and consider a `writeDownAccruedFees` if
   performance fees are blocking deposits.

### 3.3 Compromised authorizedSigner

**Symptom**: Unexpected rebalances appearing on a vault whose manager key
should be controlled by the team.

**Action**:
1. Pause `StrategyExecutor` immediately: `setPaused(true)` from the
   guardian role.
2. Use `setAuthorizedSigner(newSafeKey)` to rotate. The old key can no
   longer sign valid rebalances.
3. Unpause. Audit the receipts feed for the window of compromise.
4. If the compromise is material, migrate the vault to a fresh address
   through `VaultFactory.deploySpotVault(...)` and migrate depositors.

### 3.4 MerkleDistributor misuse

**Symptom**: A user claims an allocation they shouldn't have (e.g., the
Merkle root is wrong).

**Action**:
1. The Merkle root is `immutable`. There is no admin fix for a wrong root
   in V1.
2. The fix is to deploy a new `MerkleDistributor` with the correct root
   and direct users to claim there.
3. The wrong-root distributor becomes a sink — call `sweep(to)` after
   `claimDeadline` to recover the tokens.

## 4. Role rotation

All admin roles are held by the Governance Safe. Rotation is just a Safe
transaction. Two-step handover is enforced by `Ownable2Step` everywhere.

To rotate the Safe itself (the most sensitive operation):

1. Deploy a new Safe at the new address.
2. Transfer every admin role from the old Safe to the new Safe. For each
   contract: a single Safe transaction calling the appropriate setter
   (`transferOwnership(newSafe)` for `Ownable2Step`, `grantRole(...)` for
   `AccessControl`, etc.).
3. The old Safe has no remaining power.
4. Revoke the old Safe's role from `StrategyExecutor.DEFAULT_ADMIN_ROLE`
   to fully lock it out.

## 5. Deployment

See `contracts/script/deploy-and-verify.sh`. The script is idempotent at the
script level (re-running re-deploys everything), but the CREATE2 salts are
hardcoded — to redeploy to the same addresses, pass the same env vars. To
deploy to new addresses, change the salts.

## 6. Monitoring checklist

- [ ] Indexer heartbeat < 30s old
- [ ] Supabase `rebalances` row count growing on each manager rebalance
- [ ] RH testnet RPC responding (chainid 46630)
- [ ] Vault `rebalanceCount()` matches `select count(*) from rebalances where vault_address = ...`
- [ ] `ReputationRegistry.latest(manager)` matches `latest` row in `reputation_publishes`
- [ ] `ZOR.totalSupply() <= ZOR.CAP()`

## 7. Upgrade plan

V1 contracts are **not** upgradeable. Bug fixes ship as new contract
addresses; the dApp reads addresses from `.env.local` so re-pointing is a
config change, not a migration.

For V2, see [V2-DEFERRED.md](V2-DEFERRED.md) for the upgrade checklist.
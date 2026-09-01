# Zorpha Protocol Documentation Index

This folder holds the protocol-level docs. Each is intentionally short and aimed at one audience:

| File | Audience | What it covers |
|---|---|---|
| [SECURITY.md](SECURITY.md) | engineers + auditors | threat model, access-control matrix, invariants, known limitations, audit checklist |
| [RUNBOOK.md](RUNBOOK.md)    | operators + on-call | deploy steps, monitoring, role rotation, common incidents |
| [V2-DEFERRED.md](V2-DEFERRED.md) | anyone | every Phase-2+ item that was cut from V1 and the trigger that should re-open it |

Additional in-repo references:

- `contracts/src/vaults/SpotVaultMinimal.sol` — NatSpec is the source of truth for behavior; this file just summarises the trade-offs.
- `contracts/script/DeployPipelineV1.s.sol` — every deployed contract, in deployment order.
- `supabase/migrations/001_initial.sql` — table schema and RLS policies.
- `indexer/src/index.ts` — the indexer's behavior on every poll.
- `zorpha-web/lib/contracts.ts` — address registry + ABIs.

## Architecture in one paragraph

Zorpha is **curated active-asset management on Robinhood Chain**. A `VaultFactory` deploys three vaults (`SpotVaultMinimal` for long/flat, `RWRotationVault` for multi-token rotation, `YieldVault` for USDC yield slots). Each vault holds a single `KEEPER_ROLE` granted to `StrategyExecutor`, which validates an EIP-712 signed `Rebalance` command from the manager's `authorizedSigner` before calling the vault's `rebalanceTo`. Every successful rebalance emits a `Rebalanced(targetBps, assetLeg, cashLeg, navPerShare, nonce, commitment)` event. The Supabase indexer tails each vault's events and copies them into the `rebalances` table — the public receipts feed the dApp reads from. Managers publish stats claims to `ReputationRegistry` by submitting a keccak256 commitment of their off-chain-computed Sharpe / drawdown / alpha; anyone can challenge within a 7-day window. The dApp renders the receipts feed, the per-vault history, the per-manager profile, and a downloadable share-card PNG for every receipt.

## Where to start

- If you are auditing: [SECURITY.md](SECURITY.md).
- If you are operating: [RUNBOOK.md](RUNBOOK.md).
- If you are shipping the next version: [V2-DEFERRED.md](V2-DEFERRED.md).
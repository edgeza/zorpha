# Zorpha V1, Security Model

This document is the canonical reference for what is and is not safe in V1.
It mirrors the ZENTORY `docs/SECURITY.md` shape but is rewritten for the
Robinhood Chain + SpotVault-only scope.

## 1. Threat model

Zorpha V1 is a **testnet-only** deployment with a single EOA manager. The
threat model assumes:

- The deployer EOA is honest at deploy time but **not** a long-term admin
  authority. All admin actions go through the Timelock → Safe queue.
- The `StrategyExecutor.authorizedSigner` key is held by the manager. If
  compromised, the manager can rebalance each vault up to the `dailyLimit`
  times per day. Worst case: a vault loses ~24h of expected exposure.
- No external audit has been performed. Self-verification only (Foundry,
  Slither, invariants). Mainnet is **out of scope** for V1.
- An internal audit of the whole protocol is complete: see
  [AUDIT-TOKEN-V1.md](AUDIT-TOKEN-V1.md). 24 findings, all fixed and covered by
  regression tests. Suite green at 158/158 including 13 stateful invariants
  across two handlers.
- Slither reports 0 high and 0 medium as of 2026-09-01. Every suppression is
  written down in [SLITHER-TRIAGE.md](SLITHER-TRIAGE.md), read that before
  quoting this line. The earlier claim here was unverified: Slither had never
  actually run, and the deploy script was reporting its crash as a finding.
- Still outstanding: a THIRD-PARTY audit. That is a gate before mainnet, not
  something to arrange afterwards.

Out-of-scope for V1 (defense deferred to V2):

- Vault economic exploits via cross-contract composability (mitigated in V1
  by isolating each vault to its own adapter wiring).
- Long-tail governance attacks. NOTE: $ZOR IS an ERC20Votes token and
  carries real checkpointed voting weight (timestamp-keyed, ERC-6372). No
  Governor is deployed, so there is no on-chain venue for a proposal yet, but
  the weight exists and is queryable. An earlier revision of this document
  incorrectly stated V1 had no voting token, see finding M-02.
- Oracle manipulation beyond the staleness + bounds checks (V1 trusts the
  single configured oracle address per vault; production must use a quorum
  feed like `MedianOracle` or a verified Chainlink feed).

## 2. Access control matrix

| Contract | Role | Holder (V1) | Powers |
|---|---|---|---|
| `VaultFactory` | `DEFAULT_ADMIN_ROLE` | Governance (Safe) | Grant/revoke `DEPLOYER_ROLE` |
| `VaultFactory` | `DEPLOYER_ROLE`   | Governance (Safe) | Deploy new vaults |
| `SpotVaultMinimal` | `DEFAULT_ADMIN_ROLE` | Governance (Safe) | setSwapAdapter, setFeeRecipient, claimFees, writeDownAccruedFees |
| `SpotVaultMinimal` | `KEEPER_ROLE`       | `StrategyExecutor` | rebalanceTo |
| `SpotVaultMinimal` | `RISK_COUNCIL_ROLE`  | Governance (Safe) | setCircuitBreaker, setEmergencyRedeemCooldown |
| `RWRotationVault`  | `DEFAULT_ADMIN_ROLE` | Governance (Safe) | (none in V1, config is immutable) |
| `RWRotationVault`  | `KEEPER_ROLE`        | `StrategyExecutor` | rebalanceTo |
| `RWRotationVault`  | `RISK_COUNCIL_ROLE`  | Governance (Safe) | setCircuitBreaker |
| `YieldVault`       | `DEFAULT_ADMIN_ROLE` | Governance (Safe) | (none in V1) |
| `YieldVault`       | `KEEPER_ROLE`        | `StrategyExecutor` | rebalanceTo |
| `YieldVault`       | `RISK_COUNCIL_ROLE`  | Governance (Safe) | setCircuitBreaker |
| `YieldVault`       | `ADAPTER_SETTER_ROLE`| Timelock          | setAdapter |
| `StrategyExecutor`  | `DEFAULT_ADMIN_ROLE` | Governance (Safe) | setAuthorizedSigner, setDailyLimit, transferAdmin |
| `StrategyExecutor`  | `KEEPER_ROLE`        | Anyone with a valid signed command (the caller that submits) | executeRebalance |
| `StrategyExecutor`  | `GUARDIAN_ROLE`      | Governance (Safe) | setPaused |
| `ReputationRegistry`| `DEFAULT_ADMIN_ROLE` | Governance (Safe) | (none in V1) |
| `ProtocolTreasury`  | `Ownable` (Ownable2Step) | **Timelock** | rescue |
| `ZorphaBuyback`  | `Ownable` (Ownable2Step) | **Timelock** | setRouter, setThreshold, withdrawUsdc, rescueToken |
| `InsuranceFund`     | `Ownable` (Ownable2Step) | **Timelock** | payout |
| `MerkleDistributor` | `DEFAULT_ADMIN_ROLE`     | Governance (Safe) | (none in V1) |
| `MerkleDistributor` | `SWEEPER_ROLE`           | **Timelock** | sweep after claimDeadline |
| `Timelock`          | `PROPOSER_ROLE`          | Governance (Safe) | queue |
| `Timelock`          | `EXECUTOR_ROLE`          | Governance (Safe) | execute |

Two-step handover (Ownable2Step) is used everywhere an owner field exists. A
mistyped transfer requires the new owner to call `acceptOwnership()` before
the old owner loses the role.

## 3. Invariants

The following invariants are checked by the Foundry invariant suite and the
unit-test suite. Any regression is a P0.

- `totalAssets()` is monotonically non-decreasing between performance-fee
  accruals. (Fees are gated on NAV > HWM and capped so they cannot push
  totalAssets to zero.)
- `maxDeposit()` returns 0 while `isCircuitBreakerActive` is true.
- `maxDeposit()` returns 0 when `totalSupply() > 0 && totalAssets() == 0`.
- `Rebalanced` event count on each vault equals its `rebalanceCount()`
  storage.
- `nonces[vault]` in `StrategyExecutor` is strictly monotonic.
- `ReputationRegistry.nonces[manager]` is strictly monotonic.
- `MerkleDistributor.claimedBitMap` bits are write-once.
- `ZOR.totalSupply()` is `<= ZOR.CAP()`.

## 4. Per-contract hardening notes

### `SpotVaultMinimal`

- `_oraclePrice` reverts on non-positive answers, incomplete rounds, and
  stale updates (older than `maxOracleStaleness`).
- Rebalance dust-deadband: any diff under `rebalanceThresholdBps` is a no-op.
- `redeemEmergency` uses per-address cooldowns to MEV-guard a stale-oracle
  event, refuses to run while the circuit breaker is active, and proportionally
  decrements `performanceFeeAccrued` for the redeemed shares (audit H-1 in
  ZENTORY's review carried forward).
- Withdrawals execute `cashAsset → asset` swap when the underlying balance
  is short, bounded by `maxSlippageBps`.

### `RWRotationVault`

- All basket tokens + oracles are immutable. No live swap execution in V1.
- The receipt is the manager's chosen target weights, V1 does not enforce
  them. (V2 adds the swap leg.)

### `YieldVault`

- The adapter is contract-settable (gated behind Timelock).
- The `setAdapter` action re-approves the new adapter for the full ERC-20
  allowance; the old adapter's allowance is NOT zeroed, production must
  zero the old approval before swapping.

### `StrategyExecutor`

- EIP-712 signature scheme with a per-chain domain separator (cached, rebuilt
  on fork). Replay across chains is blocked at the chainid level.
- Per-vault monotonic nonce. Replay blocked at the nonce level.
- Signal expiry capped at `block.timestamp + 7 days`. An unbounded expiry
  would let a once-signed signal sit in storage forever, replayable on a
  future nonce collision (ZENTORY H-3 fix carried forward).
- Low-s enforced (EIP-2). Blocks signature malleability.
- `dailyLimit[vault]` cap (default 0 = unlimited, governance-tunable).
  Sliding 24-hour window.
- `paused` flag (guardian-settable) blocks all execution.

### `ReputationRegistry`

- Stores keccak256 commitments only; offchain-computed stats.
- Per-manager monotonic nonce.
- 7-day challenge window after which a commitment is settled.
- Challenge takes a candidate commitment and either upholds (matches) or
  overturns (mismatches) the manager's claim. No onchain numerical stats
  to manipulate.

### `ProtocolTreasury`

- `sweep(token)` is permissionless by design, anything that lands here is
  force-split 50/50 between buyback and operations.
- `rescue(token, to, amount)` is owner-only, escape hatch for genuinely
  misrouted assets before they're swept.

### `ZorphaBuyback`

- Holds USDC until `minBuybackThreshold` is reached, then burns any pre-bought
  ZOR to `0xdEaD`.
- Production must route through a DEX aggregator for the actual USDC→ZOR
  swap. V1 ships with the burn path only.

### `MerkleDistributor`

- OpenZeppelin-style double-hashed leaves + MerkleProof.verify. Standard.
- Unclaimed tokens after `claimDeadline` are sweepable by `SWEEPER_ROLE`.

### `ZOR`

- Fixed 1B supply; `_maxSupply()` overridden to `CAP` so ERC20Votes's mint
  ceiling is the published cap (audit TOKEN-001/TOKEN-002 fix carried
  forward).
- `mintForTestnet` gated to `block.chainid == 46630` and one-shot.
- `burn` + `burnFrom` available to all holders.

## 5. Known limitations

- **No live DEX on RH testnet for spot rotation.** Vault 1 (Long/Flat) ships
  with `StubSwapAdapter` (1:1 mock). V2 swaps in `RobinhoodChainRouterAdapter`
  against the live RH DEX once it exists.
- **Yield adapter is a stub.** Vault 3 holds USDC and reports `totalAssets()`
  == balance. Zero yield, zero risk. V2 plugs a real lending adapter.
- **Single manager per vault.** No bonding, no slashing, no permissionless
  factory. The `KEEPER_ROLE` is a single EOA.
- **No mainnet, no audit.** Self-verification only. V2 requires an external
  audit before any mainnet custody claim.

## 6. Audit checklist

When the V2 external audit lands, the auditor's checklist:

1. Re-verify all invariants in §3 against the V2 contracts (added bonding,
   permissionless factory, AI-agent rebalances).
2. Verify the EIP-712 signature scheme across chainid changes (no replay).
3. Verify the `RobustOracle` (or chainlink feed) staleness bounds on every
   oracle path; spot-check against RH mainnet feeds.
4. Verify the performance-fee HWM accrual in `SpotVaultMinimal` and the
   yield-slot performance fee in `YieldVault` (the latter is simpler and
   needs its own audit pass).
5. Verify `ReputationRegistry.challenge` semantics on the full published
   history.
6. Verify the `VaultFactory` CREATE2 salt uniqueness guarantees.

## 7. Disclosure

Found a security issue? Email `security@sidequest.app` (PGP key TBD). Please
DO NOT open a public GitHub issue.
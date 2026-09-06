# Zorpha V2+, Deferred Items

Every item that the original `Plan.md` calls for but V1 deliberately drops.
Each entry has a **trigger**; the moment we should re-open the discussion.

## 1. ERC-7540 async deposit/redemption queues

**Plan.md phase**: 2

**Why deferred**: ERC-7540 is a heavy protocol surface (cancel, request,
fulfill, claim). V1 ships with vanilla ERC-4626 because the curated launchpad
model doesn't need async settlement; there is no upstream-rail bottleneck
to wait out.

**Trigger to reopen**: TVL per vault > $1M where the daily deposit volume
exceeds the manager's intended rebalance cadence (so new deposits queue
behind the next rebalance to avoid premature swaps).

## 2. Dual-hurdle performance fee

**Plan.md phase**: 2

**Why deferred**: The dual-hurdle math (`FeeableReturn = max(0, NAV − HWM − BenchmarkHurdle)`)
needs a published benchmark per vault. With a single testnet manager, the
benchmark is the manager's own benchmark; which would be self-dealing. V1
ships with HWM-on-NAV-delta only.

**Trigger to reopen**: Multiple uncorrelated managers per strategy become
available, so a credible index (e.g., equal-weight basket of all peer vaults)
can be published.

## 3. Manager bonding + slashing

**Plan.md phase**: 2

**Why deferred**: Bonding + slashing implies (a) a bond denominated in some
asset (ZENT-style), (b) an oracle that can attest to misbehavior, and (c) a
slashing mechanism that doesn't grief honest managers. V1 uses a single
EoA manager; no economic stake, no slashing. Operational trust is the
deployment.

**Trigger to reopen**: The curator wants to onboard a third-party manager
they can't personally vett. At that point the curator posts the bond.

## 4. Permissionless vault factory

**Plan.md phase**: 2

**Why deferred**: Permissionless factory + manager bonding + slashing are
three things you build in one go. V1 ships gated; the V2 work is the
permissionless piece on top of the bonding work.

**Trigger to reopen**: Manager bonding lands.

## 5. AI-agent EIP-712 rebalances

**Plan.md phase**: 2 ("HUMANITY vs MACHINE season 1")

**Why deferred**: V1 ships with manual-signer rebalances. The EIP-712 path
already supports AI agents; the only change is the signer address. The
"GAME" framing (rewards, leaderboards, season rules) is V2.

**Trigger to reopen**: At least one external AI manager expresses interest
in running a Zorpha vault. The work itself is a single PR to
`StrategyExecutor` (no change) plus the dApp's leaderboard weighting.

## 6. Meta-vaults (allocators picking of top underlying managers)

**Plan.md phase**: 2

**Why deferred**: Allocators need enough peer vaults to pick from. V1 ships
with 3. V2 needs at least 10 distinct strategies.

**Trigger to reopen**: 10+ distinct underlying vaults exist.

## 7. Real `IYieldAdapter` for Vault 3

**Plan.md phase**: 2

**Why deferred**: V1 ships with `StubYieldAdapter` (zero yield, zero risk).
A real adapter requires (a) a lending market on RH mainnet, (b) an audited
adapter wrapper. Both are upstream dependencies.

**Trigger to reopen**: A live, audited lending market lands on RH mainnet.

## 8. ZOR governance + ve-locking

**Plan.md phase**: 2

**Why deferred**: V1 ships with no voting token. The Timelock + Safe model
is the V1 governance. Adding ve-locking requires porting `ZENTStaking` and
making `ZentGovernor` the timelock's proposer; which is a substantial
addition.

**Trigger to reopen**: Token holders ask for governance participation
beyond what the Safe+Timelock model can express.

## 9. External audit before any mainnet custody

**Plan.md phase**: 2

**Why deferred**: V1 is testnet-only with a single EOA manager. There is
no custody claim. Any move to mainnet requires:

- Re-running Slither with V2 contracts included.
- Engaging an external auditor (Trail of Bits / Spearbit / OpenZeppelin).
- A bug-bounty program with a meaningful TVL-capped pool.
- An emergency-pause runbook + a designated guardian multisig.

**Trigger to reopen**: Decision to go to mainnet. **MUST** happen before
mainnet deployment.

## 10. Cross-chain expansion

**Plan.md phase**: 3

**Why deferred**: Each chain integration requires its own oracle set, DEX
adapter, and possibly a different signature scheme (not all chains have
EIP-712). V1 is RH-only.

**Trigger to reopen**: Decision to expand.

## How to use this list

When you start a V2 sprint, copy the relevant entries into a new plan file
and link back here. The point of this doc is to make sure the items aren't
forgotten as the V1 code stabilizes.
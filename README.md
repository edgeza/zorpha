# Zorpha ($ZOR)

> Curated vaults on Robinhood Chain where every rebalance is signed onchain and published as a
> public receipt. Fixed-supply token, fee-funded buyback and burn.
>
> Site: **zorpha.xyz** · Token: **$ZOR** · Network: Robinhood Chain testnet (46630)

## Status

| Layer | State |
|---|---|
| Token (`Zorpha`, vesting, airdrop, treasury, buyback) | Audited internally, all findings fixed. |
| Vault (`SpotVaultMinimal`, `RWRotationVault`, `YieldVault`, executor, registry) | Audited internally, all findings fixed. Deposits enabled. |
| Contract tests | **97 / 97 passing**, incl. 7 stateful invariants with an enforced coverage floor. |
| Slither | Clean at high and medium severity. |
| Airdrop generator | Written, and cross-checked against the on-chain verifier. |
| Front end (`zorpha-web`) | Builds clean, 22 routes, typechecks, lints clean. |
| Third-party audit | **Not started.** Gate before mainnet. |
| Mainnet | Not deployed. |

Full internal audit, all 24 findings, with the mechanism behind each and the test that now
prevents it, is in
[`sidequest-protocol/docs/AUDIT-TOKEN-V1.md`](sidequest-protocol/docs/AUDIT-TOKEN-V1.md) and
published on the site at `/security`.

**A third-party audit has not been performed and remains the gate before mainnet.** An internal
review reliably finds the bugs its authors were capable of imagining; 24 findings in code that had
never been compiled is not evidence that a 25th does not exist.

## Repo layout

```
SideQuest/
├─ Plan.md                        Original concept doc
├─ Research/                      Deep-research report behind V1
├─ sidequest-protocol/
│  ├─ contracts/                  Foundry project
│  │  ├─ src/
│  │  │  ├─ Zorpha.sol            Fixed-supply ERC-20 + Permit + Votes. No mint, no owner.
│  │  │  ├─ ZorphaVesting.sol     Cliff + linear vesting. Unvested tokens carry no votes.
│  │  │  ├─ ZorphaBuyback.sol     Real swap + real burn, slippage-bounded, truthful events.
│  │  │  ├─ MerkleDistributor.sol Pull-based airdrop.
│  │  │  ├─ ProtocolTreasury.sol  50/50 fee split, non-discretionary.
│  │  │  ├─ InsuranceFund.sol     Governance-paid shortfall reserve.
│  │  │  ├─ vaults/               ERC-4626 vaults. Capital routes to adapters.
│  │  │  ├─ executor/             EIP-712 rebalance verifier, rate-limited
│  │  │  └─ oracle/, reputation/, adapters/, governance/
│  │  ├─ test/                    158 tests: unit, fuzz, invariant, generator parity
│  │  └─ script/
│  │     ├─ DeployZorphaToken.s.sol   Phase A: token + atomic distribution
│  │     ├─ DeployVaultsV1.s.sol      Phase B: vaults (gated on green tests)
│  │     └─ deploy-and-verify.sh      Both phases, with assertions
│  ├─ scripts/generate-airdrop.ts Merkle root + per-recipient proofs
│  ├─ docs/AUDIT-TOKEN-V1.md      ← the audit
│  ├─ docs/SECURITY.md            Threat model + role matrix
│  ├─ docs/RUNBOOK.md             Operator runbook
│  ├─ indexer/                    TypeScript indexer (viem + Supabase)
│  └─ supabase/migrations/
└─ zorpha-web/                    Next.js 15 marketing site + portal
   ├─ app/(marketing)/            /, /protocol, /token, /security, /roadmap, /faq, /legal
   ├─ app/portal/                 dashboard, vaults, receipts, managers, airdrop, vesting, governance
   ├─ lib/tokenomics.ts           SINGLE SOURCE OF TRUTH for supply numbers
   └─ lib/audit.ts                Findings rendered on /security
```

## Tokenomics

1,000,000,000 ZOR, minted once, no mint function. Numbers live in
[`zorpha-web/lib/tokenomics.ts`](zorpha-web/lib/tokenomics.ts) and are mirrored as basis points in
`DeployZorphaToken.s.sol`, which asserts the distribution consumes exactly `MAX_SUPPLY`.

| Bucket | Share | At launch | Cliff | Vest |
|---|---|---|---|---|
| Community & Ecosystem | 38% | 8% (airdrop) |, | 4y, seasonal, governance-approved |
| DAO Treasury | 20% |, | 6m | 4y |
| Core Contributors | 17% |, | 12m | 4y |
| Protocol-Owned Liquidity | 13% | 13% |, | fully unlocked |
| Early Backers | 8% |, | 12m | 3y |
| Insurance Fund | 4% |, | locked | governance release only |

**Float at launch: 21%.** Insiders (contributors + backers): 25%, nothing for 12 months.

## Quick start

```bash
curl -L https://foundry.paradigm.xyz | bash && foundryup
```

```bash
cd sidequest-protocol/contracts && forge build && forge test
```

```bash
cd zorpha-web && npm install && cp .env.example .env.local && npm run dev
```

The web app builds and renders with no env vars set, unconfigured contracts are named in a banner
rather than silently rendering as zero balances.

## Deploying

Read [`docs/AUDIT-TOKEN-V1.md`](sidequest-protocol/docs/AUDIT-TOKEN-V1.md) first, in particular the
pre-launch checklist. Then:

```bash
bash sidequest-protocol/contracts/script/deploy-and-verify.sh
```

`GOVERNANCE` must be a Safe and must not equal the deployer; both the shell script and the Solidity
script refuse to run otherwise. The token script ends by asserting the deploy key holds zero tokens
and zero roles; if it does not, the run reverts rather than half-launching.

## License

New Zorpha contracts are MIT. Reused ZENTORY contracts retain their original licenses (see file
headers). The Zorpha name and visual identity are not covered by the MIT grant.

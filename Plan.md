---
name: Zentory Vault Network Robinhood Chain
overview: Permissionless active-asset-management marketplace on Robinhood Chain. Verified managers (human or AI) run vault strategies under onchain risk mandates with permanent track records, dual-hurdle performance fees, and manager bonding. Real DeFi technology with a meme-able "onchain hedge fund" narrative and no rugpull surface.
todos:
  - id: spec-freeze
    content: Finalize vault spec (ERC-7575 + ERC-7540 conformance)
    status: pending
  - id: legal-review
    content: Jurisdiction review (FSCA + Stock Token restrictions)
    status: pending
  - id: brand-clearance
    content: Trademark + brand clearance for $ZENT extension
    status: pending
  - id: v1-contracts
    content: Build Vault Factory + Policy Controller + Performance Engine + Reputation Registry
    status: pending
  - id: audit
    content: Independent audit of V1 contracts
    status: pending
  - id: curated-vaults
    content: Launch 3 curated vaults (long/flat, RWA rotation, Morpho USDG)
    status: pending
  - id: dashboards
    content: Public manager profiles + verified track record dashboards
    status: pending
  - id: ai-agents
    content: Add EIP-712 AI-agent rebalance support
    status: pending
  - id: humanity-vs-machine
    content: Launch HUMANITY vs MACHINE Season 1
    status: pending
  - id: permissionless-factory
    content: Open permissionless vault factory with manager bonding
    status: pending
  - id: zent-expansion
    content: Expand ZENT utility to manager bonds + governance + fee discounts
    status: pending
isProject: false
---

# Zentory Vault Network on Robinhood Chain

## Decision summary

**Product**: Permissionless active asset-management marketplace on Robinhood Chain
**Architecture**: ERC-7575 (multi-asset vaults) + ERC-7540 (async deposits/redemptions) + EIP-712 signed rebalances + AI-agent compatible
**Token**: `$ZENT` (existing), expanded utility, not a new launch
**Why this fits**: deepest real technology in your research, naturally meme-able through manager leaderboards, no community needed because the technology attracts builders and managers first, structurally anti-rugpull.

---

## Strategic positioning

**Category**: "The active asset-management layer for Robinhood Chain"
**One-sentence pitch**: Deposit USDG into vault strategies run by verified humans or AI agents, with onchain risk mandates and permanent track records you can actually compare.
**The meme**: "Show me your onchain track record" / "The Hyperliquid Vaults for tokenized markets" / Humans-vs-AI manager seasons.
**Not**: another yield farm, another basket, a Hyperliquid clone, or a memecoin launch.

---

## Architecture (high level)

```
                 Investor deposits USDG
                          │
                          ▼
               ┌─────────────────────┐
               │   Vault Factory     │ (ERC-7575 multi-asset)
               └──────────┬──────────┘
                          │
            ┌─────────────┼─────────────┐
            │             │             │
      ┌──────────┐  ┌──────────┐  ┌──────────┐
      │ Manager  │  │ Manager  │  │   AI     │
      │  Vault   │  │  Vault   │  │  Vault   │
      │  #001    │  │  #017    │  │  #042    │
      └────┬─────┘  └────┬─────┘  └─────┬────┘
           │             │             │
           └─────────────┼─────────────┘
                         │
                         ▼
              ┌─────────────────────┐
              │  Execution Adapters │
              ├─────────────────────┤
              │ Uniswap / Rialto    │
              │ Morpho              │
              │ Lighter / Arcus     │
              │ Stock Tokens (RH)   │
              │ USDG / Tokenized TB │
              └──────────┬──────────┘
                         │
                         ▼
                P&L + performance fees
                         │
              ┌──────────┴──────────┐
              ▼                     ▼
        Investor shares      Manager (bonded)
```

### Core components

| Component | Purpose |
|---|---|
| Vault Factory | Deploys standardized manager vaults (ERC-7575) |
| Policy Controller | Enforces approved assets, max weights, min cash, turnover caps, slippage caps, leverage limits |
| Manager Bond | Manager stakes `ZENT` + own capital; slashable on provable mandate violation |
| Strategy Executor | Validates + executes EIP-712 signed rebalances (human or AI agent) |
| Execution Adapters | Pluggable router to Uniswap, Rialto, Morpho, Lighter, Stock Tokens |
| Risk Oracle | Computes drawdown, volatility, concentration, liquidity, benchmark alpha onchain |
| Performance Engine | Dual-hurdle accounting: `FeeableReturn = max(0, NAV − HWM − BenchmarkHurdle)` |
| Reputation Registry | Permanent, non-resettable per-manager + per-strategy records |
| Withdrawal System | ERC-7540 async: in-kind redemption where possible, queued USDG exits where liquidity requires |
| Compliance Layer | Jurisdiction gating, restricted-address handling, per-vault eligibility |

---

## Anti-rugpull structural properties

1. **Non-custodial**: Vault contracts hold capital; team never touches pooled funds.
2. **Manager bonding**: Every manager stakes `ZENT` + meaningful vault capital; provably bad trades can be slashed.
3. **No yield promises**: Fees are conditional on beating both HWM and benchmark.
4. **Verified track records**: Records live onchain and cannot be reset.
5. **Open risk mandates**: Every vault's constraints are public; off-mandate rebalances revert.
6. **Founder wallet disclosure**: All deployer, treasury, multisig wallets published.
7. **Multisig with timelock**: No single-key control of any protocol parameter.
8. **Public source + verification**: From day one.
9. **No transfer tax, no reflection, no emissions-funded APR**.
10. **Independent audit before mainnet custody** (non-negotiable).

---

## How it generates meme + attention without a community

The product itself produces the content:

- **Manager leaderboards**, verifiable, public, denominated in benchmark-alpha (the rare honest metric).
- **AI vs Human seasons**, periodic competitions with verifiable P&L.
- **Manager reputation as a brand**, top managers can build followings on verifiable track records.
- **Drawdown "callouts"**; every major loss is a public receipt of the manager's record.
- **"Show me your onchain track record"** becomes a natural reply to any yield claim.
- **First-mover category ownership**; there is currently no permissionless active-RWA-manager marketplace on Robinhood Chain.

---

## Token role (ZENT, expanded)

ZENT becomes the network token, not a speculative asset launching before the product:

| Use | Purpose |
|---|---|
| Manager bond | Required to create a vault; slashable on provable misconduct |
| Curator bond | Permissioned-list curators stake ZENT |
| Dispute/challenge bonds | Used for governance challenges |
| Vault-creation deposit | Spammable creation gets priced |
| Fee discounts | Lock ZENT for reduced protocol fees |
| Premium analytics | Tiered access to historical performance data |
| Governance | Over asset adapters, risk modules, fee parameters |
| Optional backstop | Subject to legal review |

**Not required**: to deposit as an investor, or to withdraw. No artificial toll on users.

---

## Launch sequence (no timeline pressure)

### Phase 0, Spec & legal
- Finalize vault spec (ERC-7575 + ERC-7540 conformance)
- Jurisdiction review (FSCA, US/UK/Canada restrictions on Stock Tokens)
- Trademark + brand clearance for `$ZENT` if extended

### Phase 1, Audited V1 contracts
- Vault Factory, Policy Controller, Performance Engine, Reputation Registry
- Single-asset (USDG) vaults only initially
- Manager = multisig (no permissionless manager creation yet)
- Independent audit

### Phase 2, Curated vaults live
- 3 curated vaults: long/flat drawdown defense, RWA momentum rotation, Morpho USDG yield allocator
- Public manager profile + verified track record
- Public dashboards

### Phase 3, AI-agent compatibility
- EIP-712 signed rebalances from agent wallets
- "AI Hedge Vault" as flagship
- First HUMANITY vs MACHINE season

### Phase 4, Permissionless manager creation
- Open vault factory with manager bonding
- Manager reputation marketplace
- Meta-vaults (allocators selecting top underlying managers)

### Phase 5, ZENT network expansion
- ZENT manager bond, dispute bonds, governance
- Fee discounts, premium analytics
- Only after organic TVL + fees + repeat depositors

---

## Comparison to rejected alternatives

| Why not | Reason |
|---|---|
| Twofold clone | Staking APR was operator-funded, not protocol revenue, proven unsustainable meme |
| HOOD10 | 5% tax reflexively dependent on volume; rewards collapse without trading |
| Marble | Wagering + prizes = regulatory surface |
| Generic RH mascot | No technology floor; commoditized |
| Pure memecoin | No technology to retain users after the chart |
| RECEIPTS | Great meme, but the *tech* doesn't attract users without culture first |
| IF/THEN | Solid, but a single-feature product, narrower ceiling than an asset-management layer |
| Sidebag | Cute, but a thin wrapper around a swap; limited long-term defensibility |
| GapSafe | Real tech, but infrastructure-only ceiling, needs partnerships to reach users |
| Move Zentory to RH *now* | Wrong, Zentory needs its HyperEVM track record to establish reputation before re-platforming |

---

## What this plan deliberately rejects

- Staking APR / emissions
- Reflection taxes
- Buyback-and-burn promises (until revenue exists)
- "Stake ZENT to deposit" UX toll
- Promised yields
- Transfer taxes
- Hidden mint authorities
- Team-custody of pooled capital

---

## Open items before Phase 1

1. **Brand clarity**: is `$ZENT` the final token name, or does the vault network need a new product brand layered above it (e.g., a "Vault Network by Zentory" naming)?
2. **Multi-chain posture**: build on Robinhood Chain first; defer HyperEVM adapter? Or dual-track?
3. **First manager partnerships**: are there 2–3 verifiable managers (human or AI-agent teams) willing to be the inaugural cohort?
4. **Audit budget + legal budget**: confirm scope before spec freeze.
5. **Initial benchmark choice**: S&P 500? 60/40? Crypto index? Per-vault or protocol-wide?

---

## Honest caveat

This is the higher-effort, higher-ceiling option in your research folder. It does not launch in a week, does not promise market-cap fireworks, and will not look like a "viral coin." What it offers instead is:

- A category of one on Robinhood Chain
- Defensible technology that compounds with every manager who joins
- A narrative that is genuinely meme-worthy *because* it is rare (verified onchain track records)
- Zero rugpull optics, structurally

That is the most aligned answer to "meme + real tech + no community + no rugpull" given everything in your five research chats.
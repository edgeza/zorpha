# zorpha-web

Marketing site and protocol portal for **Zorpha ($ZOR)**. Next.js 15 App Router, React 19,
TypeScript, Tailwind CSS 3, wagmi + viem.

```bash
npm install
cp .env.example .env.local     # fill in what you have; blanks degrade gracefully
npm run dev
```

The site builds and renders with **no** environment variables set. Unconfigured contracts are
named in a banner in the portal; unconfigured indexer means empty states. Neither fails the build.

## Routes

**Marketing** — static, indexed, no wallet required.

| Route | Purpose |
|---|---|
| `/` | Hero, the problem, mechanism, vaults, token summary |
| `/protocol` | How a rebalance works, vault specifications, guarantees |
| `/token` | Tokenomics: allocation donut, supply curve, fee route, contract spec |
| `/security` | Full internal audit output, including open findings, plus the trust model |
| `/roadmap` | Phases ordered by dependency, each with its gate |
| `/faq` | Product, token, governance and risk questions |
| `/legal/{terms,privacy,disclaimer}` | Templates — **replace with counsel-reviewed text before launch** |

**Portal** — `noindex`, wallet-gated where it needs to be.

| Route | Purpose |
|---|---|
| `/portal` | Balance, voting weight, burn ledger, latest receipts |
| `/portal/vaults` · `/portal/vaults/[id]` | Vault list and detail with full receipt history |
| `/portal/receipts` | Every rebalance, newest first |
| `/portal/leaderboard` · `/portal/managers/[address]` | Manager records |
| `/portal/airdrop` | Season 1 eligibility check and claim |
| `/portal/vesting` | Schedule, vesting progress, claim |
| `/portal/governance` | Voting mechanics, delegation, live role assignments |

## Architecture notes

`lib/tokenomics.ts` is the single source of truth for every supply number on the site. The same
basis points are hardcoded in `sidequest-protocol/contracts/script/DeployZorphaToken.s.sol`, which
asserts the distribution consumes exactly `MAX_SUPPLY`. The module throws at import if the
allocations do not sum to 10,000 bps, so a bad edit fails the build rather than shipping a wrong pie
chart.

`lib/audit.ts` holds the audit findings rendered on `/security`, so the public page and
`docs/AUDIT-TOKEN-V1.md` cannot drift.

`lib/contracts.ts` reads every address as a **literal** `process.env.NEXT_PUBLIC_X`. This is
load-bearing — see the comment at the top of the file, and audit finding M-01.

`lib/wagmi.ts` imports `injected` from `@wagmi/core`, not from the `wagmi/connectors` barrel. The
barrel statically pulls in the Base/Coinbase connector and its optional `@x402/*` peers, which
fails the webpack build.

## Gates

```bash
npm run typecheck    # tsc --noEmit
npm run lint
npm run build        # also typechecks
```

## Known gaps

- **Vault deposits are gated** by `NEXT_PUBLIC_ENABLE_VAULT_DEPOSITS`, which defaults to enabled
  and exists as an incident kill switch. It is not a workaround for an open bug: audit finding
  V-01 — the yield vault priced shares against an adapter balance it never funded, so a redeemer
  received nothing — is fixed, and recorded as `fixed` in `lib/audit.ts`. `YieldVault` overrides
  the ERC-4626 deposit and withdraw hooks, so a deposit is forwarded to the adapter and a
  redemption recalls from it within the same transaction.
- The legal pages are engineer-written templates and are labelled as such on the page.
- `/api/airdrop/[address]` reads Merkle proofs from `data/airdrop/<address>.json`, which does not
  exist until the Season 1 snapshot is generated. Until then every lookup returns "not eligible".

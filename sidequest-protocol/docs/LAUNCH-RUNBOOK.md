# Zorpha launch runbook — testnet to mainnet

Everything below was verified against Robinhood Chain on 1 September 2026, not
assumed. Where something is unverified it says so.

---

## 0. The three identities you need

This is the part that trips people up. You need **three separate things**, and
conflating any two of them is how launches go wrong.

| | What | Why separate |
|---|---|---|
| **Rabby** (you already have this) | Your personal wallet | Signs Safe transactions, and it is what you use to click around the portal. Never holds protocol authority. |
| **Deployer key** | A throwaway EOA, private key on disk | `forge script` needs a raw private key — a browser extension cannot sign a deploy. This key ends the deploy holding **zero tokens and zero roles**; the script asserts it and reverts otherwise. |
| **Governance Safe** | Multisig at app.safe.global | Owns the Timelock, which owns everything else. `DeployZorphaToken` **refuses to run** if `GOVERNANCE` equals the deployer. |

**Rabby is the right choice** and needs no change. It is an EIP-1193 injected
wallet, so the portal's `injected()` connector picks it up, and it handles
custom chains cleanly.

**Never put your Rabby private key in an env file.** Generate a dedicated
deployer key instead:

```bash
cast wallet new
```

That prints an address and a private key. Fund the address with testnet gas,
export the key into your shell for the deploy, and never commit it. It is
disposable by design — after the deploy it controls nothing.

---

## 1. Chain facts (verified)

| | Testnet | Mainnet |
|---|---|---|
| Chain ID | `46630` | `4663` |
| RPC | `https://rpc.testnet.chain.robinhood.com/rpc` | `https://rpc.mainnet.chain.robinhood.com` |
| RPC fallback | `https://robinhood-sepolia-rpc.publicnode.com` | `https://robinhood-rpc.publicnode.com` |
| Explorer | `https://explorer.testnet.chain.robinhood.com` | `https://robinhoodchain.blockscout.com` |
| Block time | **0.170s** (measured over 1,000 blocks) | — |
| `getLogs` cap | **10,000 results**, not a block range | — |
| Native token | Sepolia ETH | ETH |

Note the `/rpc` path on testnet. Omit it and you get a **TLS handshake
failure**, not a 404 — which is exactly why the original hostnames in this repo
(`testnet.rpc.robinhood.com`) looked plausible and never worked.

Already deployed on testnet, verified by `eth_getCode`:

- Safe singleton + proxy factory, both **1.4.1 and 1.3.0**
- Deterministic CREATE2 deployer (`0x4e59b448…`)
- Multicall3, Permit2

Safe's hosted UI supports **both** chains (`safe-config.safe.global` returns
"Robinhood Testnet" and "Robinhood Chain", each with a transaction service), so
you can create and operate a Safe from the normal app.

---

## 2. Testnet tokens (verified on-chain, but read the caveat)

`decimals()` and `symbol()` read directly from each contract:

| Use | Symbol | Address | Decimals |
|---|---|---|---|
| Cash asset | USDC | `0xAc80194dc1aE8eF52df73e7e1864fB3C62290fe0` | **6** ✅ |
| Equity 1 | TSLA | `0xC9f9c86933092BbbfFF3CCb4b105A4A94bf3Bd4E` | 18 |
| Equity 2 | HOOD | `0x211016b753C2403fe78B1306864AC570C2BbC6cF` | 18 |

**There is a second token also called USDC** at
`0xbf4479C07Dc6fdc6dAa764A0ccA06969e894275F` with **18 decimals** and far more
holders. Do not use it. The contracts and the deploy script express USDC
amounts as `1e6` (`BUYBACK_THRESHOLD_USDC=1000 * 1e6`), so an 18-decimal cash
asset would make the buyback threshold effectively unreachable and misprice
every vault denominated against it.

> **Caveat.** Testnet tokens are permissionless — anyone can deploy something
> called TSLA. These were chosen on holder count plus correct decimals, which is
> a heuristic, not verification. Confirm against Robinhood's own docs before
> mainnet. Getting this wrong on testnet costs nothing; getting it wrong on
> mainnet is unrecoverable.

---

## 3. Testnet, step by step

### 3.1 Add the chain to Rabby

Rabby → Settings → Add Custom Network:

- Name `Robinhood Chain Testnet`
- RPC `https://rpc.testnet.chain.robinhood.com/rpc`
- Chain ID `46630`
- Symbol `ETH`
- Explorer `https://explorer.testnet.chain.robinhood.com`

### 3.2 Get testnet gas

```
https://faucet.testnet.chain.robinhood.com
```

Confirmed live (it rate-limits, which is how we know it exists). Fund **both**
your Rabby address and the deployer address from 3.3.

### 3.3 Create the deployer key

```bash
cast wallet new
```

Save the address, fund it from the faucet. Keep the key in your shell only.

### 3.4 Create the governance Safe

Go to **app.safe.global**, switch the network to Robinhood Testnet, connect
Rabby, create a Safe.

For testnet a 1-of-1 with your Rabby is fine. **For mainnet use at least 2-of-3
with keys on separate devices** — a 1-of-1 Safe is a single point of failure
wearing a multisig costume.

Record the Safe address as `GOVERNANCE`.

### 3.5 Deploy the token layer

```bash
cd sidequest-protocol/contracts
```

```bash
export PRIVATE_KEY=0x<deployer key from 3.3>
export GOVERNANCE=0x<Safe address from 3.4>
export USDC_TOKEN=0xAc80194dc1aE8eF52df73e7e1864fB3C62290fe0
export LIQUIDITY_RECIPIENT=$GOVERNANCE
export AIRDROP_MERKLE_ROOT=0x<from step 3.6, or a placeholder for now>
export AIRDROP_CLAIM_DEADLINE=$(python -c "import time;print(int(time.time())+90*86400)")
export RPC_URL=https://rpc.testnet.chain.robinhood.com/rpc
```

```bash
forge script script/DeployZorphaToken.s.sol:DeployZorphaToken --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast -vvv
```

The script ends by asserting the deployer holds zero ZOR, that the buckets sum
to `MAX_SUPPLY`, and that every privileged role moved to the Timelock. If any
assertion fails the whole run reverts rather than leaving you half-launched.

Copy the printed addresses.

### 3.6 Generate the airdrop tree

Write a snapshot CSV (`address,amount`, whole ZOR):

```bash
npx tsx sidequest-protocol/scripts/generate-airdrop.ts --snapshot snapshot.csv --out zorpha-web/data/airdrop
```

It prints `AIRDROP_MERKLE_ROOT=0x…` and a snapshot SHA-256. **Publish the CSV
and its hash before opening claims** so anyone can rebuild the root and confirm
the allocation was not changed afterwards.

Because the root is immutable in the constructor, generate the tree *before*
3.5 if you want real claims on the first deploy. Otherwise redeploy the
distributor once you have the real root.

### 3.7 Deploy the vault layer

```bash
export TIMELOCK=0x<from 3.5>
export TREASURY=0x<from 3.5>
export STOCK_TOKEN_1=0xC9f9c86933092BbbfFF3CCb4b105A4A94bf3Bd4E   # TSLA
export STOCK_TOKEN_2=0x211016b753C2403fe78B1306864AC570C2BbC6cF   # HOOD
export ORACLE_UPDATERS=0x<your keeper address>
export ORACLE_QUORUM=1
```

```bash
forge script script/DeployVaultsV1.s.sol:DeployVaultsV1 --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast -vvv
```

Leave `STOCK_FEED_1` / `STOCK_FEED_2` unset on testnet — there is no published
Chainlink testnet feed list, so the script wires the self-operated
`MedianOracle`. `ORACLE_QUORUM=1` is acceptable for testnet only.

You must then **post prices** to the MedianOracle or every rebalance reverts on
staleness. The vault fails closed by design.

### 3.8 Verify the contracts

```bash
forge verify-contract <address> src/Zorpha.sol:Zorpha --chain-id 46630 --verifier blockscout --verifier-url https://explorer.testnet.chain.robinhood.com/api --watch
```

Repeat per contract, or use `script/deploy-and-verify.sh` which does both
phases plus verification.

### 3.9 Apply the database

Two migrations, in order:

- `supabase/migrations/001_initial.sql`
- `supabase/migrations/002_indexer_state_and_counters.sql`

002 is not optional. Without it the indexer throws on startup by design — the
old code silently fell back to an upsert that never incremented
`total_rebalances`, so the leaderboard read zero forever.

Either authenticate the database connector or paste both files into the
Supabase SQL editor.

### 3.10 Deploy the indexer

```bash
railway login
```

New service, root directory `sidequest-protocol/indexer`. Variables:

```
RPC_URL=https://rpc.testnet.chain.robinhood.com/rpc
RPC_URL_FALLBACK=https://robinhood-sepolia-rpc.publicnode.com
CHAIN_ID=46630
EXPLORER_URL=https://explorer.testnet.chain.robinhood.com
SUPABASE_URL=https://<ref>.supabase.co
SUPABASE_SERVICE_ROLE_KEY=<service role key — Railway only, never the browser>
REPUTATION_REGISTRY_ADDRESS=0x<from 3.7>
START_BLOCK=<the deploy block from 3.5>
```

**Set `START_BLOCK`.** Leaving it at 0 makes the first run try to scan from
genesis on a chain already past block 111,000,000.

Health: `/healthz` (liveness), `/readyz` (liveness + database).

### 3.11 Point the front end at it

Fill the blanks you asked about — every one comes from a deploy output:

| Env var | Source |
|---|---|
| `NEXT_PUBLIC_ZOR_ADDRESS` | 3.5 · `ZOR` |
| `NEXT_PUBLIC_TIMELOCK_ADDRESS` | 3.5 · `Timelock` |
| `NEXT_PUBLIC_TREASURY_ADDRESS` | 3.5 · `Treasury` |
| `NEXT_PUBLIC_BUYBACK_ADDRESS` | 3.5 · `Buyback` |
| `NEXT_PUBLIC_INSURANCE_ADDRESS` | 3.5 · `InsuranceFund` |
| `NEXT_PUBLIC_MERKLE_DISTRIBUTOR_ADDRESS` | 3.5 · `MerkleDistributor` |
| `NEXT_PUBLIC_VESTING_ADDRESS` | 3.5 · `Vesting` |
| `NEXT_PUBLIC_VAULT_FACTORY_ADDRESS` | 3.7 · `Factory` |
| `NEXT_PUBLIC_STRATEGY_EXECUTOR_ADDRESS` | 3.7 · `Executor` |
| `NEXT_PUBLIC_REPUTATION_REGISTRY_ADDRESS` | 3.7 · `Reputation` |

Plus `NEXT_PUBLIC_SUPABASE_URL` and `NEXT_PUBLIC_SUPABASE_ANON_KEY` (the
**anon** key — RLS makes it read-only; the service role key must never reach
the browser).

The portal names every unset address in a banner rather than rendering a
confident zero, so you can watch it clear as you fill them in.

### 3.12 Post-deploy actions only the Safe can do

1. Timelock queues and executes `ProtocolTreasury.acceptOwnership()` —
   `Ownable2Step` is deliberately two-phase.
2. Safe calls `ZorphaVesting.fund(...)` with the real contributor and backer
   schedules. The deploy script does not do this on purpose: those are real
   people's addresses and amounts, and they do not belong in a committed env
   file.
3. Safe queues `ZorphaBuyback.setRouter(...)` once a ZOR route exists (see
   Known gaps).

---

## 4. Testnet validation checklist

Do not skip to mainnet until every line passes.

**Token**
- [ ] `totalSupply() == 1e27` and `balanceOf(deployer) == 0`
- [ ] Portal shows your ZOR balance; the "not configured" banner is gone
- [ ] Delegate to yourself → voting weight becomes non-zero
- [ ] `burn` reduces `totalSupply`
- [ ] No `mint` selector exists

**Airdrop**
- [ ] An eligible address sees its allocation and claims successfully
- [ ] Second claim reverts `AlreadyClaimed`
- [ ] A tampered amount reverts `InvalidProof`
- [ ] An ineligible address sees "not in the snapshot"

**Vesting**
- [ ] Safe funds a schedule; beneficiary sees the right cliff and end date
- [ ] Pre-cliff claim reverts; post-cliff releases the expected fraction
- [ ] `getVotes(vestingContract) == 0` — unvested tokens must not vote

**Vaults**
- [ ] Post an oracle price, deposit, confirm shares minted
- [ ] Redeem returns principal (this is audit finding V-01 — verify it live)
- [ ] Sign a rebalance, submit through the executor, receipt appears in the portal
- [ ] Stale oracle → rebalance reverts rather than mispricing
- [ ] Circuit breaker blocks deposits, redemptions still work

**Buyback**
- [ ] Send USDC to the treasury, `sweep`, confirm 50/50 split
- [ ] With a router set: `execute` reduces `totalSupply` and the burn ledger updates

**Indexer**
- [ ] `/readyz` returns 200
- [ ] Receipts appear within a poll cycle
- [ ] Leaderboard `total_rebalances` increments (proves migration 002 applied)
- [ ] Restart the service — it resumes from the cursor, does not re-scan

**Wallets**
- [ ] Rabby connects
- [ ] WalletConnect QR connects a phone wallet
- [ ] Wrong-network state offers "Switch network" and works
- [ ] Safe's own browser can use the portal (Safe connector auto-connects)

---

## 5. Mainnet deltas

Mainnet is **not** a redeploy with different env values. Four things change.

### 5.1 Real oracles — the big one

Chainlink has **57 live feeds on chain 4663**, including 35 tokenised equities
at 8 decimals. See `CHAINLINK-FEEDS-MAINNET.md`.

Set `STOCK_FEED_1` / `STOCK_FEED_2` to real proxies and the self-operated
`MedianOracle` is bypassed:

| Asset | Chainlink proxy |
|---|---|
| TSLA / USD | `0x4A1166a659A55625345e9515b32adECea5547C38` |
| NVDA / USD | `0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15` |
| AAPL / USD | `0x6B22A786bAa607d76728168703a39Ea9C99f2cD0` |
| SPY / USD | `0x319724394D3A0e3669269846abE664Cd621f9f6A` |

**Do not ship mainnet on the self-operated oracle.** It would mean one key set
decides the price every vault marks its NAV against.

### 5.2 Real swap venue

Robinhood Chain has Uniswap (per Robinhood's own integrations page). Deploy
`RobinhoodChainRouterAdapter` — a real Uniswap V3 adapter already in this repo
— against the live router, instead of `StubSwapAdapter`.

You need **two** instances: one per vault pair (equity ↔ USDC), and one for the
buyback (USDC → ZOR). Grant each `VAULT_ROLE` to its caller.

### 5.3 Governance hardening

- Safe at 2-of-3 minimum, keys on separate devices
- `ORACLE_QUORUM` above 1 with independent updater keys
- Timelock delay confirmed at 48h

### 5.4 Everything on the pre-launch checklist

`AUDIT-TOKEN-V1.md` has the full list. The gating item is a **third-party
audit**. All 24 internal findings are closed, but an internal review reliably
finds only the bugs its authors could imagine.

---

## 6. Known gaps

Named honestly, because these will bite otherwise.

1. **`RobinhoodChainRouterAdapter` has no test coverage.** It is real code and
   it compiles, but no test exercises it. Until the buyback runs against it on
   testnet, "it should work" is the strongest claim available.
2. **The buyback cannot run without a ZOR market.** No pool, no route, no
   burn. Fee revenue accumulates in the contract meanwhile — recoverable via
   the timelocked `withdrawUsdc`, which exists precisely so it cannot be
   stranded.
3. **Legal pages are engineer-written templates**, labelled as such on the
   page. Replace before mainnet.
4. **The portal's contract reads have never run against deployed contracts.**
   They typecheck; that is not the same thing. Expect to find something on
   3.11.
5. **No CI.** Every finding in the audit except the compile errors would have
   been caught by a job running `forge build && forge test` on push.
6. **Testnet token addresses are unverified** beyond decimals and holder
   count. Confirm against Robinhood's docs.

---

## 7. Order of operations, compressed

```
Rabby: add chain          →  faucet: fund Rabby + deployer
cast wallet new           →  app.safe.global: create Safe
generate-airdrop.ts       →  DeployZorphaToken       →  DeployVaultsV1
verify contracts          →  apply migrations 001 + 002
Railway: indexer          →  Vercel: fill 10 addresses
run section 4 checklist   →  fix what it finds
third-party audit         →  legal review
mainnet: Chainlink feeds + Uniswap adapter + 2-of-3 Safe
```

Nothing after "run the checklist" should start until the checklist is green.

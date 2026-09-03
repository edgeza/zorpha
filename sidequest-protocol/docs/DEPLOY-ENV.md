# Filling the ten contract addresses

The block in `zorpha-web/.env.example` that reads

```
NEXT_PUBLIC_ZOR_ADDRESS=
NEXT_PUBLIC_VESTING_ADDRESS=
...
NEXT_PUBLIC_REPUTATION_REGISTRY_ADDRESS=
```

is not filled in by hand. All ten values are outputs of the two deploy
scripts, and `contracts/script/deploy-and-verify.sh` writes them into
`zorpha-web/.env.local` for you at the end of a successful run.

What you do fill in by hand is the set of **inputs** those scripts need. That is
what this document covers.

---

## 0. What blocks a deploy

Four things must exist before either script will run. Each of them is a hard
`require` in Solidity, so getting one wrong means a reverted broadcast rather
than a quiet misconfiguration.

### 0.1 A governance address that is not the deployer

Both scripts refuse to run if `GOVERNANCE == deployer`:

```solidity
require(gov != deployer, "GOVERNANCE must not be the deployer EOA");
```

This is deliberate. The scripts end by asserting that the deploy key holds zero
tokens and zero roles, and that assertion is meaningless if the deploy key is
also the governance key.

- **Testnet:** a second account in Rabby is enough. Create one, copy its
  address, and use it as `GOVERNANCE`. Nothing about the flow requires it to be
  a contract.
- **Mainnet:** this must be a real multisig. Deploy a Safe at
  [app.safe.global](https://app.safe.global) on Robinhood Chain first. Every
  post-deploy action in section 4 is a Safe transaction, and the timelock is
  constructed with the Safe as its sole proposer, executor and admin. A single
  EOA here undoes the entire access-control design.

### 0.2 The base asset address (`USDC_TOKEN`)

**Confirm this before mainnet.** LI.FI's token list for Robinhood Chain
(chain 4663, 243 tokens) contains no plain USDC. The stablecoins it carries are
Paxos **USDG** (`0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`, 6 decimals),
USDe, and `syrupUSDC`. The vault contracts are written against a generic
6-decimal ERC-20 and never hardcode USDC, so USDG works — but the naming
throughout the codebase says USDC, and the two must be reconciled before the
vaults take real deposits. The bridge page already opens on USDG for this
reason.

On testnet, deploy a mock 6-decimal ERC-20 and point `USDC_TOKEN` at it.

### 0.3 The airdrop root

`AIRDROP_MERKLE_ROOT` comes from the generator, not from you:

```bash
cd sidequest-protocol && npm install && npm run airdrop -- --snapshot data/<your-snapshot>.csv
```

It prints the root and writes the proof file the portal serves. The script
self-verifies every leaf against the tree it just built, so a root it prints is
a root the distributor will accept.

`AIRDROP_CLAIM_DEADLINE` is a unix timestamp and must be in the future at
deploy time:

```bash
date -d '+90 days' +%s
```

### 0.4 A tokenised equity for phase B (`STOCK_TOKEN_1`)

Only needed if you deploy vaults. Robinhood Chain mainnet carries tokenised
equities — AAPL, TSLA, NVDA, MSFT, GOOGL and others — so pick the one whose
mandate you actually want to run and use its address. On testnet, a mock
18-decimal ERC-20 is fine.

---

## 1. Set the script inputs

These live in your shell, not in a committed file. `PRIVATE_KEY` especially:
it is a deploy key, and the whole point of the handover assertions is that it
holds nothing afterwards.

```bash
export PRIVATE_KEY=0x...              # deployer EOA, funded with gas
export GOVERNANCE=0x...               # Safe (mainnet) or second account (testnet)
export USDC_TOKEN=0x...               # see 0.2
export LIQUIDITY_RECIPIENT=0x...      # where the 13% protocol-owned liquidity goes
export AIRDROP_MERKLE_ROOT=0x...      # from the generator
export AIRDROP_CLAIM_DEADLINE=...     # unix seconds, in the future
export RH_TESTNET_RPC_URL=https://rpc.testnet.chain.robinhood.com/rpc
export RH_EXPLORER_URL=https://explorer.testnet.chain.robinhood.com
export RH_EXPLORER_API_KEY=...
```

Optional, with sane defaults if omitted:

| Variable | Default | Notes |
| --- | --- | --- |
| `TIMELOCK_DELAY` | `172800` (48h) | Delay on every privileged action |
| `BUYBACK_THRESHOLD_USDC` | `1000e6` | Minimum accumulated fees before a buyback can fire |
| `CHAIN_ID` | `46630` | Set to `4663` for mainnet |
| `DEPLOY_VAULTS` | `false` | Set `true` to run phase B |
| `STOCK_TOKEN_2`, `STOCK_FEED_1`, `STOCK_FEED_2` | unset | Phase B. Without feeds, vaults fall back to the median oracle |
| `ORACLE_UPDATERS`, `ORACLE_QUORUM` | **required** | Phase B. Must be the address your price keeper signs with, never the deployer. See section 4.4 |

---

## 2. Run it

```bash
cd sidequest-protocol/contracts && ./script/deploy-and-verify.sh
```

Seven steps: build, token tests, full suite, slither, phase A, contract
verification, phase B. It stops on the first failure, and phase B refuses to
run at all if the suite is red.

Phase A prints the seven token-layer addresses and then independently reads
`balanceOf(deployer)` back off-chain to confirm the distribution actually
emptied the deploy key. Phase B prints the three vault-layer addresses.

To deploy the token alone, leave `DEPLOY_VAULTS` unset. That is a valid launch:
the portal reports the vault addresses as unconfigured by name rather than
rendering empty panels.

---

## 3. What lands in `.env.local`

The script writes these for you. The mapping from what it prints to what the
web app reads:

| Script output | Web variable |
| --- | --- |
| `ZOR` | `NEXT_PUBLIC_ZOR_ADDRESS` |
| `Vesting` | `NEXT_PUBLIC_VESTING_ADDRESS` |
| `MerkleDistributor` | `NEXT_PUBLIC_MERKLE_DISTRIBUTOR_ADDRESS` |
| `Buyback` | `NEXT_PUBLIC_BUYBACK_ADDRESS` |
| `Treasury` | `NEXT_PUBLIC_TREASURY_ADDRESS` |
| `InsuranceFund` | `NEXT_PUBLIC_INSURANCE_ADDRESS` |
| `Timelock` | `NEXT_PUBLIC_TIMELOCK_ADDRESS` |
| `Factory` (phase B) | `NEXT_PUBLIC_VAULT_FACTORY_ADDRESS` |
| `Executor` (phase B) | `NEXT_PUBLIC_STRATEGY_EXECUTOR_ADDRESS` |
| `Reputation` (phase B) | `NEXT_PUBLIC_REPUTATION_REGISTRY_ADDRESS` |

The write is a **merge**, not an overwrite. Anything the script does not own —
`NEXT_PUBLIC_WC_PROJECT_ID`, the Supabase pair, `NEXT_PUBLIC_SITE_URL` — is
carried through and re-appended under a separator, and the previous file is
copied to `.env.local.bak` first. None of those three can be recovered from a
deploy, so losing them to a redeploy would mean going back to the Reown and
Supabase dashboards.

Once written, paste the same values into Vercel's environment variables for the
production deployment. `.env.local` is local only.

---

## 4. What the script cannot do

Five things need a human with the Safe. The script prints them at the end.

**4.1 Accept treasury ownership.** `ProtocolTreasury` uses `Ownable2Step`, so
the transfer to the Timelock is pending until accepted. Queue
`acceptOwnership()` through the Timelock. Until this is done the treasury still
answers to the previous owner.

**4.2 Fund the real vesting schedules.** The script forwards the contributor
and backer tranche to the Safe rather than writing schedules, because those are
real people's addresses and amounts and do not belong in a committed env file.
The Safe calls `ZorphaVesting.fund()` with the actual list.

**4.3 Set the buyback router.** `ZorphaBuyback.setRouter()` needs a live ZOR
market to point at, which does not exist at deploy time. Until it is set, fee
revenue accumulates in the contract and is withdrawable via `withdrawUsdc`. The
buyback cannot execute against an unset router, so nothing is at risk while you
wait.

**4.4 Seat the real oracle updater set.** `ORACLE_UPDATERS` has no usable
default. Phase B would fall back to the deployer alone, and `_handOver`
renounces `UPDATER_ROLE` from the deployer while leaving it in the `updaters`
array -- an oracle that can never reach quorum, and vaults that revert on their
first NAV read. Both the deploy script and `testnet-launch.sh` now refuse that
outright, the wrapper in preflight so it costs nothing.

Set it to the address your price keeper actually signs with. Seating an address
nobody posts from is the same dead oracle by a slower route: the deploy
succeeds and the first rebalance reverts on staleness. To read the address the
current keeper posts from, ask the oracle it is already feeding -- the entry
whose report is fresh is the live one:

```bash
cast call $ORACLE 'updaterCount()(uint256)' --rpc-url $RPC_URL
cast call $ORACLE 'updaters(uint256)(address)' 1 --rpc-url $RPC_URL
cast call $ORACLE 'reports(address)(int256,uint64)' $CANDIDATE --rpc-url $RPC_URL
```

A single-updater median is still a single point of failure feeding every vault's
pricing. `ORACLE_QUORUM=1` is acceptable on testnet only. Raise both before
accepting live deposits: the script refuses a quorum higher than the number of
updaters, but it cannot tell you that one updater is too few.

**4.5 Publish the Season 1 snapshot criteria** before opening claims. The root
is committed on-chain at deploy; publishing the criteria afterwards means
publishing them after anyone can already tell whether they qualified.

---

## 5. Testnet then mainnet

Run the whole thing on testnet (`CHAIN_ID=46630`) first, including phase B, and
exercise the portal against it: connect a wallet, read a balance, claim an
airdrop, view a receipt. The failure modes that matter — an unsatisfiable oracle
quorum, a missing router, a treasury whose ownership was never accepted — all
look identical to success until someone tries to use them.

For mainnet, change `CHAIN_ID` to `4663`, point the RPC and explorer variables
at mainnet, and confirm section 0.2 before anything else. Everything else is the
same commands with a real Safe in `GOVERNANCE`.

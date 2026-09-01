# Launch checklist: testnet to mainnet

Work top to bottom. Each phase has a gate at the end; do not start the next
phase until the gate closes. `docs/DEPLOY-ENV.md` covers what the variables mean
and where they come from.

Chain facts, verified 1 September 2026 by reading the chains directly:

| | Testnet | Mainnet |
| --- | --- | --- |
| Chain ID | 46630 | 4663 |
| RPC | `https://rpc.testnet.chain.robinhood.com/rpc` | `https://rpc.mainnet.chain.robinhood.com` |
| Explorer | `https://explorer.testnet.chain.robinhood.com` | `https://robinhoodchain.blockscout.com` |
| Stablecoin | none — deploy fixtures | USDG `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` (6dp) |
| Yield venue | none — deploy fixtures | Steakhouse USDG `0xBeEff033F34C046626B8D0A041844C5d1A5409dd` |
| DEX | none | SwapRouter02 `0xCaf681a66D020601342297493863E78C959E5cb2` |

**Testnet is a bare chain.** USDG, Steakhouse and Uniswap all return no code at
46630. That is why phase 1 exists, and why phase 4 is not optional: testnet can
prove the protocol's own accounting and nothing at all about whether it talks to
real venues correctly.

---

## Phase 0 — Before anything

- [ ] **Governance address that is not the deployer.** Both deploy scripts
      hard-revert otherwise. Testnet: a second Rabby account is fine. Mainnet:
      a Safe at [app.safe.global](https://app.safe.global) on chain 4663.
- [ ] Deployer EOA funded with gas on the target chain.
- [ ] `git config user.email juan@autonama.co.za` — Vercel blocks deployments
      whose commit author is not associated with the account.
- [ ] Toolchain: `forge --version` (1.8.1), `cast`, `jq`, `slither`.
- [ ] Airdrop root generated, from `sidequest-protocol/` not `contracts/`:
      `npm install && npm run airdrop -- --snapshot data/<file>.csv`
- [ ] `AIRDROP_CLAIM_DEADLINE` set to a future unix timestamp:
      `date -d '+90 days' +%s`

**Gate:** `forge test` is green with zero failures.

---

## Phase 1 — Testnet fixtures

```bash
export PRIVATE_KEY=0x...
export RH_TESTNET_RPC_URL=https://rpc.testnet.chain.robinhood.com/rpc
forge script script/DeployTestnetFixtures.s.sol:DeployTestnetFixtures \
  --rpc-url "$RH_TESTNET_RPC_URL" --broadcast -vvv
```

- [ ] Ran, and the four addresses printed.
- [ ] Exported `USDG_TOKEN`, `STOCK_TOKEN_1`, `STOCK_TOKEN_2`, `YIELD_TARGET`
      from its output.
- [ ] Leave `SWAP_ROUTER` **unset** on testnet. There is no DEX, so the spot
      vault falls back to the stub and exercises the rebalance path without
      real price discovery.

**Gate:** `cast call $YIELD_TARGET "asset()(address)"` returns `$USDG_TOKEN`.

---

## Phase 2 — Testnet deploy

```bash
export GOVERNANCE=0x...            # NOT the deployer
export LIQUIDITY_RECIPIENT=0x...
export AIRDROP_MERKLE_ROOT=0x...
export AIRDROP_CLAIM_DEADLINE=...
export DEPLOY_VAULTS=true
./script/deploy-and-verify.sh
```

- [ ] Phase A printed seven token addresses.
- [ ] The script's own check passed: **deployer holds 0 ZOR**.
- [ ] Phase B printed the vault addresses, including the yield and swap adapters.
- [ ] Read the warnings at the end of phase B. On testnet the swap stub warning
      is expected; the **yield stub warning must not appear** — if it does,
      `YIELD_TARGET` was not picked up and the vault earns nothing.
- [ ] `zorpha-web/.env.local` was written, and your
      `NEXT_PUBLIC_WC_PROJECT_ID` survived (the script merges, and backs up to
      `.env.local.bak`).

**Gate:** every address in `.env.local` is non-empty, and the portal's "not
configured" banner is gone.

---

## Phase 3 — Testnet end to end

Contract flows. Each should be done from the portal where a UI exists for it,
because the point is to test the whole stack rather than the contracts alone.

**Yield vault (`zqUSD`) — the one that will hold real size**
- [ ] Deposit tUSDG. Shares minted, balance shown in the portal.
- [ ] `cast send $YIELD_TARGET "accrue(uint256)" 500000000` to simulate yield.
- [ ] NAV per share rose in the portal.
- [ ] Redeem. You receive **less than** the full gain — that is the 10%
      performance fee. If you receive all of it, fees are broken; see the
      regression tests in `ERC4626YieldAdapter.t.sol`.
- [ ] `cast call $VAULT "performanceFeeAccrued()(uint256)"` is non-zero
      **without anyone having called `evaluateFees`**.
- [ ] `claimFees()` moves the accrued amount to the treasury.

**Spot vault (`zqHOOD`)**
- [ ] Deposit, then have the manager sign an EIP-712 rebalance.
- [ ] Submit it through `StrategyExecutor` from a different address — submission
      is permissionless by design.
- [ ] Receipt event emitted; it appears in the portal's receipt list.
- [ ] Replay the same signature: must revert on the nonce.
- [ ] Submit an expired signature: must revert on expiry.
- [ ] Exceed the daily rate limit: must revert.

**Oracle**
- [ ] Let a price go stale past `maxOracleStaleness`, attempt a rebalance,
      confirm it **reverts** rather than trading on a stale price.

**Token layer**
- [ ] Airdrop claim from an eligible address succeeds; a second claim reverts.
- [ ] An ineligible address cannot claim.
- [ ] Vesting: nothing claimable before cliff; linear after.
- [ ] Timelock: queue a privileged call, confirm it cannot execute before the
      48h delay, then execute it.
- [ ] Circuit breaker: set it, confirm deposits are refused, unset it.

**Web**
- [ ] All routes return 200 (`/`, `/protocol`, `/whitepaper`, `/token`, `/faq`,
      `/roadmap`, `/tools/bridge`, `/legal/*`, `/portal`).
- [ ] Wallet connect works for injected, MetaMask, Coinbase and WalletConnect.
      The wallet approval dialog shows the Zorpha mark, not a broken image.
- [ ] Bridge widget loads and quotes a route.
- [ ] Paste the deployed URL into a Slack/Discord/X compose box: the social card
      renders with the headline and the three figures.
- [ ] No console errors on any route.

**Gate:** every box above ticked, and no unexplained revert anywhere.

---

## Phase 4 — Mainnet fork validation

This is the phase that actually de-risks mainnet, because it is the only one
that exercises the real venues.

```bash
RH_MAINNET_RPC_URL=https://rpc.mainnet.chain.robinhood.com \
  forge test --match-path 'test/fork/*' -vv
```

- [ ] All six pass.
- [ ] `test_SwapAdapterExecutesARealTrade` logs a sane AAPL amount for 1,000
      USDG (roughly 3.0–3.1 AAPL at ~$324).
- [ ] `test_SteakhouseVaultIsWhatWeThinkItIs` reports the target still holds
      hundreds of millions of USDG. If it has shrunk sharply, reconsider the
      target before pointing depositor money at it.

**Gate:** six of six passing against a fork taken that same day.

---

## Phase 5 — Mainnet deploy

```bash
export CHAIN_ID=4663
export RH_TESTNET_RPC_URL=https://rpc.mainnet.chain.robinhood.com   # see note
export GOVERNANCE=0x...            # the Safe, not an EOA
export USDG_TOKEN=0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168
export YIELD_TARGET=0xBeEff033F34C046626B8D0A041844C5d1A5409dd
export SWAP_ROUTER=0xCaf681a66D020601342297493863E78C959E5cb2
export SWAP_FEE_TIER=500
export STOCK_TOKEN_1=0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9   # AAPL
```

> The RPC variable is still named `RH_TESTNET_RPC_URL` in the deploy script.
> Point it at mainnet; renaming it mid-launch is not worth the risk.

- [ ] `GOVERNANCE` is a Safe, and you can execute a transaction from it.
- [ ] Ran `./script/deploy-and-verify.sh`.
- [ ] **Neither stub warning appeared.** If either did, stop — the vaults are
      not products.
- [ ] Contract verification succeeded on Blockscout for all seven token
      contracts and the vault layer.

**Gate:** deployer holds 0 ZOR and no privileged role anywhere.

---

## Phase 5b — Leadership layer

Permissionless vault creation, with the leader's capital subordinated to
depositors'. Run after the vault layer, because it needs the factory.

```bash
export ZOR_TOKEN=0x...          # from phase A
export VAULT_FACTORY=0x...      # from phase B
export APPROVED_YIELD_TARGETS=0xBeEff033F34C046626B8D0A041844C5d1A5409dd,0xde770c84FE66E063336b31737cFE9790f18c4087
forge script script/DeployLeadership.s.sol:DeployLeadership   --rpc-url "$RH_TESTNET_RPC_URL" --broadcast -vvv
```

- [ ] Launcher deployed, deployer holds no role on it.
- [ ] **Grant `DEPLOYER_ROLE` on the factory to the launcher.** The script
      prints this; it cannot do it itself, because factory admin is the Safe.
      Until it happens nobody can launch anything.
- [ ] At least one venue approved. With none, `launchYieldVault` reverts for
      everyone.
- [ ] Every approved venue is a real ERC-4626 whose `asset()` you have checked.
      The allowlist is the only thing standing between permissionless creation
      and a leader pointing a vault at a contract they wrote.

Exercise it end to end from a **second account**, not the deployer:

- [ ] Approve ZOR bond and seed capital, call `launchYieldVault`.
- [ ] Vault, escrow and adapter all deployed; `vaultSummary(1)` reads back.
- [ ] Deposit from a **third** account. Coverage ratio falls as the vault grows.
- [ ] Accrue yield on the venue, claim fees: leader and treasury both paid.
- [ ] Force a drawdown smaller than the buffer. Depositor redeems **whole**;
      `totalAbsorbed()` is non-zero. This is the product claim — see it work.
- [ ] Force a drawdown larger than the buffer. Depositor takes only the
      uncovered part, and the escrow is empty.
- [ ] Leader reallocates to a second approved venue. NAV does not move.
- [ ] Leader tries an unapproved target: reverts.
- [ ] Someone other than the leader tries to reallocate: reverts.
- [ ] Leader requests an escrow withdrawal that would breach 5%: reverts after
      the 7-day wait.
- [ ] Governance slashes a bond; the leader cannot then reclaim it.

**Gate:** a depositor was made whole out of a leader's capital, on chain, and
you watched it happen.

---

## Phase 6 — Manual steps no script can do

Each needs the Safe.

- [ ] Timelock queues and executes `ProtocolTreasury.acceptOwnership()`.
      `Ownable2Step` leaves it pending until this runs.
- [ ] Safe calls `ZorphaVesting.fund()` with the real contributor and backer
      schedules.
- [ ] Seat the real oracle updater set and raise `ORACLE_QUORUM` above 1. A
      single-updater median is a single point of failure feeding every vault.
- [ ] Publish the Season 1 snapshot criteria **before** opening claims.
- [ ] Once a ZOR market exists, Safe queues `ZorphaBuyback.setRouter()`. Until
      then fee revenue accumulates and is withdrawable; the buyback cannot fire
      against an unset router, so nothing is at risk while you wait.

---

## Phase 7 — Sizing, before you invite deposits

- [ ] **Cap the spot vaults.** Measured on the AAPL/USDG 0.05% pool: $10k fills
      at 0.44%, $20k at 0.94%, $40k at 31%. With `maxSlippageBps = 100` a
      rebalance above roughly $20k reverts. A vault holding more than it can
      rotate is a vault that cannot rebalance.
- [ ] Do not widen `maxSlippageBps` to make that revert go away. The revert is
      the protection.
- [ ] The yield vault has no such ceiling — ERC-4626 deposits do not slip. If
      you want size early, it goes there.
- [ ] Announce with the real numbers. `docs/AUDIT-TOKEN-V1.md` and the site say
      what is and is not audited; keep them true.

---

## Rollback

If something is wrong after mainnet deploy and before real deposits:

1. `NEXT_PUBLIC_ENABLE_VAULT_DEPOSITS=false` in Vercel, redeploy. Kills the
   deposit surface across all vaults in one change, no contract call.
2. Risk council sets the circuit breaker on affected vaults.
3. Timelock queues an adapter swap if the venue is the problem — the migration
   path is tested, including the share-rounding trap on full exit.

Withdrawals stay open in all three cases. That is deliberate.

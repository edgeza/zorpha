# Zorpha ($ZOR) — Protocol Audit, V1

| | |
|---|---|
| **Date** | 1 September 2026 |
| **Reviewer** | Internal review. **No third-party audit has been performed.** |
| **Commit state** | Pre-deployment. Nothing is deployed to any network, mainnet or testnet. |
| **In scope** | Whole protocol. Token layer (`Zorpha.sol`, `ZorphaVesting.sol`, `ZorphaBuyback.sol`, `MerkleDistributor.sol`, `ProtocolTreasury.sol`, `InsuranceFund.sol`), vault layer (`SpotVaultMinimal.sol`, `RWRotationVault.sol`, `YieldVault.sol`, `StrategyExecutor.sol`, `ReputationRegistry.sol`, `MedianOracle.sol`), both deploy pipelines, the off-chain airdrop generator, and the front-end contract integration in `zorpha-web/`. |
| **Out of scope** | Economic modelling of the allocation, legal characterisation of the token, the indexer, Supabase RLS policies. |

## Verdict

**All findings are closed. The remaining gate before mainnet is a third-party audit.**

Twenty-four findings were identified across two passes. All twenty-four are fixed and covered by
regression tests.

> **On the test count.** This document used to say "green at 97 of 97, including seven stateful
> invariants" here, while its own closing checklist said 158/158 and 13 — the headline was never
> updated after later passes. Both numbers were quoted back at us as current, because a figure in a
> verdict reads as the state of the repo rather than the state of one audit pass.
>
> So this line no longer carries a number. **Run `forge test` for the current count**; at the time of
> writing it is 215 across 23 suites with 13 stateful invariants, and CI runs it on every push. The
> before/after table below is deliberately a snapshot of *this audit*, and is labelled as such.

The first pass covered the token layer and left five vault-layer findings open, one critical. The
second pass closed all five and uncovered three more in the process: a reputation flag a manager
could mint for themselves, rotation-vault receipts that did not commit to the basket they described,
and a rotation vault charging none of the performance fee it advertised. All three are fixed.

The single most important result: **before this review, the repository did not compile and the test suite had never run.** Three compilation errors sat in production source and two more in tests. Consequently every finding below H-02 was undetectable by any automated check, and the existing suite contained three tests asserting behaviour that is impossible.

Two findings would have caused direct, unrecoverable loss of funds if deployed as written:

- **C-01** — the buyback contract performed no swap, spent no USDC, bought no tokens, and emitted an event reporting that it had. All fee revenue reaching it was permanently unrecoverable.
- **V-01** — the USDC yield vault priced shares against an adapter balance it never funded. A depositor could burn every share and receive nothing.

A third would have destroyed the product's core claim rather than its funds:

- **V-06** — a manager could publish arbitrary performance figures, self-challenge quoting the same hash, and be recorded as `upheld` — which the portal renders as a green "Upheld" badge — while permanently blocking any genuine challenge.

### Test state

Both columns are **as of this audit's second pass**, not as of today. Later work has moved every
figure in the right-hand column upward; see the note in the verdict above.

| | Before this audit | At close of this audit |
|---|---|---|
| Compiles | ❌ no | ✅ yes |
| Token-layer tests | 8, never executed | **40, all passing** |
| Full suite | 46 written, never executed | **97 total, 97 passing** |
| Failing tests | unknown | **0** |
| Invariants | 2, both tautologies, 100% revert rate | **7 real invariants, <10% revert rate, coverage floor enforced** |
| Airdrop generator | did not exist | **written and cross-checked against the on-chain verifier** |

Reproduce with:

```bash
cd sidequest-protocol/contracts && forge test
```

---

## Severity definitions

| Severity | Meaning |
|---|---|
| **Critical** | Direct loss of user or protocol funds, or unbounded supply/authority compromise. |
| **High** | Loss of funds under specific conditions, permanent loss of protocol capability, or a trust model that differs materially from what is documented. |
| **Medium** | Incorrect accounting, deployment failure, or a security control that does not function as intended. |
| **Low / Info** | Missing observability, gas, or process issues with no direct security impact. |

---

## Findings summary

| ID | Sev | Status | Scope | Title |
|---|---|---|---|---|
| C-01 | Critical | ✅ Fixed | Token | Buyback contract never bought anything back |
| C-02 | Critical | ✅ Fixed | Deploy | Entire supply left in the deploy key |
| C-03 | High | ✅ Fixed | Deploy | Treasury and buyback owned by the deploy key |
| H-01 | High | ✅ Fixed | Token | Mint function that could never succeed, with tests asserting it did |
| H-02 | High | ✅ Fixed | Tooling | The repository did not compile |
| H-03 | High | ✅ Fixed | Token | Vesting treated the cliff as additive with the vesting term |
| M-01 | Medium | ✅ Fixed | Frontend | Every contract address resolved to the zero address in the browser |
| M-02 | Medium | ✅ Fixed | Docs | Documentation denied a capability the token has |
| M-03 | Medium | ✅ Fixed | Deploy | Oracle deployed permanently unable to reach quorum |
| M-04 | Medium | ✅ Fixed | Deploy | Deploy script reverted in every production configuration |
| M-05 | Medium | ✅ Fixed | Token | Voting checkpoints keyed to block numbers on an L2 |
| M-06 | Medium | ✅ Fixed | Token | Vesting accepted already-vested schedules; quadratic gas |
| M-07 | Medium | ✅ Fixed | Token | Buyback had no slippage protection |
| L-01 | Low | ✅ Fixed | Token | Revoking a vesting schedule emitted no event |
| L-02 | Low | ✅ Fixed | Frontend | Unconfigured backend crashed the build |
| L-03 | Info | ✅ Fixed | Tooling | `via_ir` silently invalidates time-based tests |
| V-01 | Critical | ✅ Fixed | Vault | Yield vault valued shares against an adapter balance it never funded |
| V-02 | High | ✅ Fixed | Vault | Signed-rebalance path could not execute at all |
| V-03 | High | ✅ Fixed | Vault | Reputation registry reported disputes as unchallenged |
| V-04 | Medium | ✅ Fixed | Vault | Spot vault circuit breaker and fee accrual were never tested |
| V-05 | Medium | ✅ Fixed | Vault | Invariant suite passed without exercising anything |
| V-06 | High | ✅ Fixed | Vault | A manager could mint their own "verified" badge |
| V-07 | Medium | ✅ Fixed | Vault | Rotation vault receipts did not commit to the basket |
| V-08 | Medium | ✅ Fixed | Vault | Rotation vault charged none of its advertised performance fee |

---

# Critical

## C-01 — The buyback contract never bought anything back

**Status:** Fixed · **Scope:** `ZorphaBuyback.sol` (was `SIDEQUESTBuyback.sol`)

### What the code did

The contract was documented as: *"Accumulates USDC from protocol fees and uses it to buy SIDEQUEST from the market, then burns the purchased SIDEQUEST."* The implementation was:

```solidity
function execute() external {
    uint256 usdcBalance = usdc.balanceOf(address(this));
    if (usdcBalance < minBuybackThreshold) revert BelowThreshold(usdcBalance);

    uint256 sidequestBalance = sidequest.balanceOf(address(this));
    if (sidequestBalance > 0) {
        sidequest.safeTransfer(deadAddress, sidequestBalance);
    }
    emit BuybackExecuted(msg.sender, usdcBalance, sidequestBalance);
}
```

There is no swap. There is no call to any router. USDC is read and never spent.

### Impact

Three distinct failures, each serious on its own.

1. **Fee revenue was permanently unrecoverable.** USDC accumulated in the contract with no path out. `rescueToken` explicitly refused to move it:
   ```solidity
   require(token != address(sidequest) && token != address(usdc), "cannot rescue sidesq or usdc");
   ```
   There was no `withdraw`, no `sweep`, and no owner escape hatch. Every dollar of protocol fees routed here by `ProtocolTreasury.sweep` was locked forever.

2. **The event lied.** `usdcSpent` was set to the contract's entire USDC balance while zero USDC was spent. Any dashboard, indexer or analytics integration reading `BuybackExecuted` would have reported large, entirely fictional buyback volume. `execute()` was permissionless and repeatable, so the same fake volume could be re-emitted indefinitely by anyone, at will.

3. **The value-accrual narrative was unbacked.** "50% of fees buy and burn the token" is the token's entire economic proposition. Going to market on that claim, backed by a contract that provably cannot buy, is a disclosure exposure well beyond a code bug.

### Fix

`ZorphaBuyback` now performs a real swap through an injected `ISpotSwapAdapter`, with:

- a caller-supplied `minZorOut`, so a sandwich attempt cannot force a bad fill;
- **both legs measured as balance deltas across the swap**, never read from the adapter's return value, so a malicious or buggy router cannot over-report;
- `revert NothingSwapped()` if no USDC actually left, and `revert InsufficientOutput()` if the measured output is short;
- a real `burn()` call, reducing `totalSupply`, rather than a transfer to `0xdead`;
- cumulative `totalUsdcSpent` / `totalZorBurned` counters for the portal, incremented from measured deltas;
- a timelocked `withdrawUsdc`, so fee revenue can never be stranded again.

### Regression tests

`test/Zorpha.t.sol :: ZorphaBuybackTest` — nine tests, including:

- `test_ExecuteActuallyBuysAndBurns` — asserts USDC leaves, ZOR is acquired, **and `totalSupply` actually falls**.
- `test_LyingRouterCannotFakeABurn` — drives `execute` with a `StealingRouter` that takes the USDC, delivers nothing, and returns a value claiming a full fill. The transaction must revert rather than book a phantom burn.
- `test_EventReportsTrueAmounts` — pins the emitted numbers to the real deltas.
- `test_UsdcCanAlwaysBeRecovered` — guards the fund-lock regression directly.

---

## C-02 — The deploy script left the entire supply in the deploy key

**Status:** Fixed · **Scope:** `script/DeployPipelineV1.s.sol`

### What the code did

```solidity
r.sidequest = new SIDEQUEST();   // constructor mints 1,000,000,000 to msg.sender
```

That was the last time the token appeared in the script. All 1,000,000,000 tokens remained in the deploying EOA. Additionally:

- `SIDEQUESTVesting` was **never deployed** by the pipeline.
- `MerkleDistributor` was **never deployed** by the pipeline — despite `.env.example` defining `NEXT_PUBLIC_MERKLE_DISTRIBUTOR_ADDRESS` and the app shipping an airdrop claim page against it.

### Impact

Launching from this script would have put 100% of supply in a single hot key, with no vesting contract, no airdrop distributor, no treasury allocation and no liquidity allocation. Every published tokenomics commitment would have been unenforced and unenforceable — sound only for as long as one private key stayed both uncompromised and honest.

### Fix

`script/DeployZorphaToken.s.sol` distributes the entire supply atomically inside the deploy transaction and then asserts, as launch-blocking `require`s:

```solidity
require(airdropAmount + liquidityAmount + insuranceAmount + govAmount == supply, "...");
require(d.zor.balanceOf(deployer) == 0, "deployer still holds ZOR");
require(d.buyback.owner() == address(d.timelock), "buyback not timelocked");
require(d.insurance.owner() == address(d.timelock), "insurance not timelocked");
require(d.vesting.admin() == gov, "vesting admin wrong");
```

If any invariant fails, the run reverts rather than half-launching.

**Deliberate design note.** Contributor and backer vesting schedules are *not* created by the script. Those entries contain real people's addresses and amounts, which do not belong in a committed env file. The script forwards that tranche to the governance Safe, which calls `ZorphaVesting.fund` itself (runbook step 4). The script performs only the trustless part of the distribution.

---

# High

## C-03 — Treasury and buyback were owned by the deploy key, contradicting the published role matrix

**Status:** Fixed · **Scope:** `ProtocolTreasury.sol`, `ZorphaBuyback.sol`, deploy pipeline

`docs/SECURITY.md` stated:

| Contract | Role | Holder (V1) |
|---|---|---|
| `ProtocolTreasury` | `Ownable2Step` | Governance (Safe) |
| `SIDEQUESTBuyback` | `Ownable2Step` | Governance (Safe) |

Both were constructed with `Ownable(msg.sender)` and ownership was never transferred. The real holder was the deployer EOA.

This matters most on `ProtocolTreasury.rescue`, which moves an arbitrary amount of any token to an arbitrary address — that is, it can drain all accumulated protocol fees. The documented trust model and the actual trust model differed precisely on the function with the largest blast radius.

**Fix:** both are owned by the Timelock from the deploy transaction, and the script refuses to run when `GOVERNANCE` is unset or equals the deployer. Handover is asserted before success is reported.

---

## H-01 — A mint function that could never succeed, with tests asserting that it did

**Status:** Fixed · **Scope:** `Zorpha.sol` (was `SIDEQUEST.sol`)

The token exposed:

```solidity
function mintForTestnet(address to, uint256 amount) external onlyTestnet {
    require(msg.sender == DEPLOYER, "SIDEQUEST: not deployer");
    require(!_testnetMintDone, "SIDEQUEST: testnet mint disabled");
    _testnetMintDone = true;
    _mint(to, amount);
}
```

The constructor already minted `CAP`, and `_maxSupply()` was overridden to return `CAP`. In OpenZeppelin 5.6.1, `ERC20Votes._update` reverts when supply exceeds `_maxSupply()`:

```solidity
if (from == address(0)) {
    uint256 supply = totalSupply();
    if (supply > _maxSupply()) revert ERC20ExceededSafeSupply(supply, cap);
}
```

So any call reverted unconditionally. Confirmed by execution:

```
[FAIL: ERC20ExceededSafeSupply(1000000100000000000000000000, 1000000000000000000000000000)]
  test_MintForTestnet_OnlyChain46630()
[FAIL: ERC20ExceededSafeSupply(...)] test_MintForTestnet_OnlyOnce()
```

**Two consequences.** The function was dead code that also documented a capability the token did not have. More importantly, `test_MintForTestnet_OnlyChain46630` asserted it *worked* — proving the suite had never been executed, and that no test in the repository could be trusted as evidence of anything.

A secondary issue: after any burn, `totalSupply < CAP`, so on chain 46630 the function became genuinely callable and burned supply could be re-minted once.

**Fix:** removed entirely. `test_NoMintEntrypointExists` asserts both `mintForTestnet` and `mint` are absent from the ABI, so a mint cannot be reintroduced quietly.

---

## H-02 — The repository did not compile

**Status:** Fixed · **Scope:** build

Five distinct errors, three in production source:

| File | Error |
|---|---|
| `src/vaults/YieldVault.sol:64` | `IERC20Metadata` used, never imported |
| `src/adapters/RobinhoodChainRouterAdapter.sol:159` | `StubSwapAdapter` calls `safeTransferFrom` with no `using SafeERC20 for IERC20` |
| `test/SIDEQUEST.t.sol` | imports `../../src/...` from `test/` (one level too deep) |
| `test/VaultFactory.t.sol` | same |
| `test/reputation/ReputationRegistry.t.sol` | assigns the public-mapping getter `latest(addr)` (8-tuple) to a struct; needed `getLatest` |

There were no `out/` or `broadcast/` directories, corroborating that the project had never been built or deployed.

**This is the finding that enabled all the others.** No CI check, however well designed, can catch a bug in code that does not reach the compiler.

**Fix:** all five corrected. `forge build` is clean; `forge test` executes.

**Recommendation:** add CI that runs `forge build && forge test` on every push and blocks merge on failure. Every finding in this report except this one would have been caught by that job.

---

## H-03 — Vesting treated the cliff as additive with the vesting term

**Status:** Fixed · **Scope:** `ZorphaVesting.sol`

```solidity
uint256 totalPeriod = uint256(s.cliffDuration) + s.vestDuration;
uint256 elapsedFromStart = timestamp - s.startTime;
if (elapsedFromStart >= totalPeriod) return s.totalAmount;
return (uint256(s.totalAmount) * elapsedFromStart) / totalPeriod;
```

Vesting accrued over `cliff + vestDuration`, not over `vestDuration`.

### Impact

For the published contributor schedule — 12-month cliff, 48-month vest — the actual behaviour was:

| | Intended | As written |
|---|---|---|
| Fully vested at | month 48 | **month 60** |
| Released at cliff | 25.0% | **20.0%** |

Every contributor and backer schedule would have paid out on the wrong curve and completed a year late. The original test even encoded the wrong behaviour in a comment (*"Linear over (cliff + vestDuration) = 395 days"*) while asserting only `assertGt(..., 0)`, so it passed without checking the value.

**Fix:** accrual is linear over `vestDuration` from `startTime`, with the cliff gating the first release. `test_CliffIsNotAdditiveWithVestDuration` pins the exact cliff fraction (25%), the midpoint (50%), and the end date.

---

# Medium

## M-01 — Every contract address resolved to the zero address in the browser

**Status:** Fixed · **Scope:** `zorpha-web/lib/contracts.ts`

```typescript
function addr(name: keyof Env, fallback = ZERO): `0x${string}` {
  const v = process.env[name];                    // <-- dynamic key
  return ((v && v.startsWith('0x') ? v : fallback) as `0x${string}`);
}
```

Next.js inlines client-side env vars via a webpack `DefinePlugin` pass that rewrites only *statically analysable* `process.env.FOO` member expressions. `process.env[name]` with a variable key is not analysable, so no substitution occurred, `process.env` was effectively empty in the client bundle, and every address fell through to `0x0000…0000`.

**This fails silently and asymmetrically.** In `next dev` a real `process.env` exists, so everything works. In a production build the token page reads `balanceOf` on the zero address and renders a confident `0`, and the airdrop page submits claims against the zero address.

**Fix:** every lookup is a literal `process.env.NEXT_PUBLIC_*` reference, addresses are regex-validated, and the portal renders an explicit banner naming any unconfigured contract instead of showing a plausible zero.

---

## M-02 — Documentation denied a capability the token has

**Status:** Fixed · **Scope:** `docs/SECURITY.md`, token page

`Zorpha` extends `ERC20Votes` and carries real checkpointed voting weight. Meanwhile:

- `docs/SECURITY.md`: *"Long-tail governance attacks (V1 has no voting token)"*
- the token page listed *"Not a governance token (no voting weight)"* as a **feature**

Both were false. Understating a token's capabilities on a public site is a disclosure problem, and the threat model was built on an assumption the code contradicted.

**Fix:** voting is kept and described accurately — weight exists and is queryable today, no Governor is deployed, and the governance page states plainly that there is currently no on-chain venue for a proposal.

---

## M-03 — Oracle deployed permanently unable to reach quorum

**Status:** Fixed · **Scope:** deploy pipeline, `MedianOracle.sol`

```solidity
r.oracle = new MedianOracle(8, 1 hours, 100 * 1e8, 1_000_000 * 1e8, 3, gov);  // minQuorum = 3
r.oracle.addUpdater(deployer);                                                 // one updater
```

`latestRoundData` reverts unless at least `minQuorum` reports are fresh:

```solidity
if (count < minQuorum) revert InsufficientFreshReports(count, minQuorum);
```

With one updater and a quorum of three, the count can never exceed one. Every price read reverts forever, so any vault falling back to this oracle was bricked from deployment. Because the vaults fail closed on a bad oracle — correct behaviour — this manifests as a permanently unusable vault rather than a mispriced one.

**Fix:** quorum is derived from the actual updater set, `require(quorum <= oracleUpdaters.length)` before broadcast, and a post-deploy assertion `require(r.oracle.minQuorum() <= r.oracle.updaterCount())`. The script prints an explicit instruction to seat a real multi-key set before accepting deposits — a single-updater median is a single point of failure even when it functions.

---

## M-04 — The deploy script reverted in every production configuration

**Status:** Fixed · **Scope:** deploy pipeline

`VaultFactory` grants its deploy role only to the constructor admin:

```solidity
constructor(address admin_) {
    _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    _grantRole(DEPLOYER_ROLE, admin_);
}
```

The script passed `admin_ = gov`, then called `r.vaultFactory.deploySpotVault(...)`, `r.spotVault.setSwapAdapter(...)` and `r.spotVault.grantRole(...)` from the deployer key. Whenever `GOVERNANCE != deployer` — i.e. every real deployment, since governance should be a multisig — the run reverted with `AccessControlUnauthorizedAccount`, **after the token had already been deployed and broadcast**, leaving a partially deployed system.

The bug hides in testing precisely because `GOVERNANCE` defaults to `deployer` via `vm.envOr("GOVERNANCE", deployer)`.

**Fix:** `script/DeployVaultsV1.s.sol` deploys the factory and vaults with the deployer as temporary admin, wires everything, then hands each contract to governance and renounces the deployer's role, asserting no deployer authority survives.

---

## M-05 — Voting checkpoints keyed to block numbers on an L2

**Status:** Fixed · **Scope:** `Zorpha.sol`

`ERC20Votes` defaults to a block-number clock. Robinhood Chain does not guarantee a stable block interval, so any governance period expressed in blocks drifts in wall-clock terms — a "three day" vote can quietly become five, or two.

**Fix:** `clock()` and `CLOCK_MODE()` are overridden to report timestamps per ERC-6372. Pinned by `test_VotingClockIsTimestampBased`.

---

## M-06 — Vesting accepted already-vested schedules, and used quadratic gas

**Status:** Fixed · **Scope:** `ZorphaVesting.sol`

Two issues in `fund`:

1. **`startTime_` was entirely unvalidated.** A start time far in the past created a schedule already claimable in full, defeating the cliff. Fixed with `MAX_BACKDATE = 90 days`, plus a new `cliffDuration <= vestDuration` check.

2. **In-batch duplicate detection was O(n²).** A nested loop compared every beneficiary against every prior one. Fixed by writing each schedule inside the single pass, which makes the mapping itself the duplicate check for both pre-existing and in-batch duplicates, at one storage read per entry.

Pinned by `test_ExcessivelyBackdatedStartReverts`, `test_CliffLongerThanVestReverts`, `test_DuplicateBeneficiaryInBatchReverts`.

---

## M-07 — Buyback had no slippage protection

**Status:** Fixed · **Scope:** `ZorphaBuyback.sol`

Distinct from C-01: even had a swap existed, `execute()` took no minimum-output parameter and accepted whatever the venue returned. A permissionless, fully-predictable market buy of the contract's entire balance with no bound is a standing invitation to sandwich the protocol's own treasury.

**Fix:** `execute(uint256 minZorOut)`, enforced against the measured delta. Pinned by `test_SlippageBoundIsEnforced`.

---

# Low / Informational

## L-01 — Revoking a vesting schedule emitted no event

**Status:** Fixed. `revoke()` moved tokens and permanently altered a beneficiary's schedule with no log. For a protocol whose entire pitch is a verifiable record, an unlogged privileged action is a hole in that record. `Revoked(beneficiary, vestedKept, unvestedReturned)` and `ScheduleCreated(...)` added.

## L-02 — An unconfigured backend crashed the build instead of degrading

**Status:** Fixed. `lib/supabase.ts` was marked `'use client'` yet imported by server components, and called `createClient('', '')` at module load — which throws. A deployment without backend env vars failed during prerender rather than rendering the marketing site. The client is now lazy, the module is server-safe, and every query degrades to an empty result with an explicit empty state.

## L-03 — `via_ir` silently invalidates time-based tests

**Status:** Fixed (documented). `foundry.toml` sets `via_ir = true`. The IR optimiser rematerialises the `TIMESTAMP` opcode at each use rather than caching it in a stack slot, so a local `uint256 t0 = block.timestamp` picks up the **post-`vm.warp`** value. Observed directly:

```
├─ [0] VM::warp(11)
├─ [536] Zorpha::getPastVotes(holder, 11)   // expected 1, got 11
│   └─ ← [Revert] ERC5805FutureLookup(11, 11)
```

Any time-based assertion in this repository can pass or fail for reasons unrelated to the contract. Time-based tests now use literal timepoints, with the reason documented inline.

---

# Vault layer — second pass

All five findings left open by the first pass are closed, along with three further issues found
while remediating them.

## V-01 — Yield vault valued shares against an adapter balance it never funded

**Severity: Critical · Status: Fixed**

`YieldVault` overrode `totalAssets()` to report its adapter's balance:

```solidity
uint256 adapterAssets = adapter.totalAssets();
return adapterAssets > performanceFeeAccrued ? adapterAssets - performanceFeeAccrued : 0;
```

but never overrode the ERC-4626 `_deposit` / `_withdraw` hooks. Deposited funds stayed on the vault;
the adapter balance stayed zero.

**Consequence.** `totalAssets()` returned 0 while `totalSupply()` was positive, so share price was
zero. A redeemer burned every share and received nothing, while their principal remained stranded in
the vault. It also inflated share issuance for any later depositor, diluting the first. Reproduced:

```
[FAIL: assertion failed: 0 != 100000000000] test_Deposit_RoutesThroughAdapter()
[FAIL: assertion failed: 900000000000 != 1000000000000] test_Withdraw_ReturnsFunds()
```

The second is a depositor redeeming a 100,000 USDC position and receiving **zero**.

**Fix.** Both hooks now route capital through the adapter — `_deposit` forwards in, `_withdraw`
recalls first, clamped to what the adapter reports so a partially-liquid adapter produces a clear
shortfall rather than an arithmetic error. Two adjacent gaps were closed at the same time:

- **`setAdapter` stranded the position.** Repointing the adapter without moving the capital would
  have reproduced this exact bug on purpose — the new adapter reports zero, every share reprices to
  nothing. It now migrates the full position in the same transaction.
- **Accrued fees were unpayable.** `performanceFeeAccrued` only ever *subtracted* from
  `totalAssets()`; there was no `claimFees`, so it depressed every holder's NAV in exchange for
  nothing and `feeRecipient` was a dead storage slot. Added.

**Regression tests.** The invariant this restores is asserted after every deposit and withdrawal:

```solidity
adapter.totalAssets() == vault.totalAssets() + vault.performanceFeeAccrued()
```

plus `testFuzz_DepositThenRedeemIsWhole` over 256 runs asserting a deposit-then-redeem round trip
returns the principal to within one wei, and `test_SetAdapter_MigratesThePosition`.

## V-02 — The signed-rebalance path could not execute at all

**Severity: High · Status: Fixed**

```solidity
uint256 cutoff = block.timestamp - 1 days;
```

This underflows on any chain whose timestamp is below 86400 — which is exactly the state a fresh
Foundry or Anvil instance starts in, where `block.timestamp` is 1. Every rate-limited rebalance
reverted with `panic: arithmetic underflow`, so the EIP-712 mechanism the entire protocol is built
around had never been exercised by a test. The same expression appeared in the public
`getRecentRebalanceCount` view.

**Fix.** A shared `_windowCutoff()` clamps at zero. Two adjacent improvements while in there:

- The sliding window was trimmed by `delete` followed by re-push, which zeroes every slot and then
  pays to write each survivor a second time. It is now compacted in place, preserving order.
- The signature is verified **before** any storage is touched, so a forged command cannot make the
  protocol pay for the compaction.

All nine executor tests pass, including nonce replay, daily limiting and window sliding.

## V-03 — Reputation registry reported disputes as unchallenged

**Severity: High · Status: Fixed**

`challenge` wrote only to `history[manager][index]`. The portal reads `getLatest`, which returned a
*separate duplicated copy* that challenges never touched. The two diverged the instant anything was
disputed, so an overturned commitment kept displaying as unchallenged.

**Fix.** The duplicated `latest` mapping is deleted outright and `getLatest` now derives from
`history`, so the two cannot disagree. Duplicated mutable state was the defect, not the missing
write.

## V-04 — Spot vault circuit breaker and fee accrual were never tested

**Severity: Medium · Status: Fixed**

Both tests failed with `AccessControlUnauthorizedAccount` before reaching a single assertion: the
suite never granted `RISK_COUNCIL_ROLE` or `KEEPER_ROLE`. The circuit breaker and the fee logic were
entirely unverified while appearing covered.

**Fix.** Roles wired correctly. `KEEPER_ROLE` is deliberately withheld from the test contract so
`test_KeeperOnly_Rebalance` still means something — granting it made that negative test silently
pass for the wrong reason, which is how the original gap arose.

## V-05 — The invariant suite passed without exercising anything

**Severity: Medium · Status: Fixed**

The handler pranked `rebalanceTo` as the vault's own address, which holds no keeper role:

```
| VaultHandler | rebalanceTo | 64010 | 64010 | 0 |     <- calls | reverts | discards
```

**Every one of 64,010 rebalance calls reverted.** Forge defaults to `fail_on_revert = false`, so the
suite reported both invariants holding across 128,000 calls while never once exercising a rebalance.
The two assertions were also tautologies — one checked that a `uint256` was at least zero.

**Fix.** Rewritten with seven real invariants: fee solvency, full backing of outstanding shares, net
never exceeding gross, receipt count matching executed rebalances, no value created from nothing,
and two covering the V-01 failure class (a vault with worthless shares must be closed to new
capital; an open vault must have a non-zero share price). The handler now holds the keeper role and
the venue is funded on both legs.

Critically, an `afterInvariant` **coverage floor** fails the run outright if no deposit or rebalance
ever succeeded:

```solidity
assertGt(handler.depositCalls(), 0, "no deposit ever succeeded: invariants proved nothing");
assertGt(handler.rebalanceCalls(), 0, "no rebalance ever succeeded: invariants proved nothing");
```

Revert rate went from 100% to under 10%. Two of the new invariants failed on first run and were
investigated before being adjusted — the dust state they flagged turned out to be handled by
`maxDeposit`, which is asserted rather than assumed.

## V-06 — A manager could mint their own "verified" badge

**Severity: High · Status: Fixed**

A challenge was resolved by comparing the stored commitment against a hash **the challenger
supplied**, and a match set `upheld = true`:

```solidity
if (c.commitment != expectedCommitment) { c.upheld = false; /* overturned */ }
else                                    { c.upheld = true;  /* upheld */ }
```

So a manager could publish any figures at all, immediately self-challenge quoting that same hash,
and be recorded as upheld. The `!c.challenged` guard then **permanently blocked** a genuine
challenge from anyone else. The portal renders `upheld` as a green "Upheld" badge, so the worst case
was a fabricated track record displaying as independently verified — on a protocol whose entire
proposition is that track records can be checked.

**Fix.** Only a mismatch is a dispute; a matching counter-commitment reverts with `NoDispute` and
leaves the window open. `upheld` can now only be set by a governance arbiter via a separate
`resolveChallenge`, because deciding which of two off-chain computations is correct is not something
a hash comparison between the disputing parties can settle. `test_ManagerCannotSelfMintUpheld` pins
the exact attack.

## V-07 — Rotation vault receipts did not commit to the basket

**Severity: Medium · Status: Fixed**

`RWRotationVault` reused the single-asset commitment helper, which takes one `targetBps` and one
`cashLeg`. It squeezed itself in by passing `rebalanceCount % 65536` as the target weight and the
constant `10000` weight checksum as the cash leg. The resulting hash bound **neither the basket
weights nor the per-token legs** — the only fields a rotation receipt exists to attest. Two
rebalances into completely different baskets could hash identically.

**Fix.** A dedicated `basketCommitment` binds the full weight array and every token leg, using
`abi.encode` rather than `encodePacked` so two dynamic arrays cannot collide. Tests assert that
reordering either the weights or the legs changes the hash.

## V-08 — Rotation vault charged none of its advertised performance fee

**Severity: Medium · Status: Fixed**

Slither flagged `RWRotationVault.performanceFeeAccrued` as assignable-to-constant, which is what a
never-written storage slot looks like from the outside. The vault stored `performanceFee`,
`highWaterMark` and `performanceFeeAccrued`, and the deploy script configured 20% — but there was no
`evaluateFees` and no `claimFees`. The protocol earned **zero** from this vault while the site
advertised a 20% performance fee.

**Fix.** Both implemented, mirroring `SpotVaultMinimal`: charged only above the high-water mark,
clamped so the accrual can never exceed holdings, and payable in the base asset. Five tests cover
no-accrual-below-HWM, accrual on a new high, no double-billing at the same high, keeper gating, and
the empty-claim revert.

---

# Off-chain airdrop generator

The airdrop claim page existed but `scripts/generate-airdrop.ts` did not, so there was no way to
produce a Merkle root or any proofs — the claim flow could not have been run at all.

Written, with the failure mode that matters guarded explicitly. If the generator and
`MerkleDistributor.claim` disagree on leaf encoding, pair ordering, or odd-node promotion, every
proof fails for real recipients with no diagnosable reason — and **neither side's own tests would
notice**, because each is internally self-consistent.

`test/AirdropGeneratorParity.t.sol` closes that seam: it hardcodes the root and all proofs from an
actual generator run over a deliberately odd-sized (five recipient) snapshot, so the odd-node
promotion path is exercised, and asserts the contract accepts every one. It also asserts the
distributor is left holding **exactly zero**, which independently confirms the generator's reported
total matches the tree's real contents.

Generator-side properties worth noting: duplicate addresses are a hard error rather than a silent
double allocation; odd nodes are promoted rather than duplicated (duplication is the classic source
of forgeable proofs in hand-rolled trees); every proof is verified against the root before being
written; and the snapshot's SHA-256 is recorded in a manifest so anyone can rebuild the root and
confirm the allocation was not changed after the fact.

---

# Static analysis

`slither . --config-file slither.config.json` — **130 results, none at high or medium severity.**
The excluded detector list is limited to `solc-version`, `pragma`, `naming-convention`,
`code-complexity`, `similar-lines` and `unused-import`, all informational, so the absence of
high/medium results is a real outcome rather than a filtered one.

Slither surfaced one genuine finding and one accepted one.

**Genuine — acted on.** `constable-states` flagged `RWRotationVault.performanceFeeAccrued` as
assignable-to-constant, which is what a never-written storage slot looks like from the outside. That
became finding V-08: the vault charged none of the 20% performance fee it advertised.

**Accepted, with reasoning.** `reentrancy-no-eth` reports `YieldVault.setAdapter`, because
`adapter` is written after the external `old.withdraw(...)` call. The window is real in principle:
between the withdraw and the write, the vault holds the capital while `totalAssets()` still reads the
drained old adapter, so NAV reads as zero.

It is not reachable. `setAdapter` and all four ERC-4626 entrypoints (`deposit`, `mint`, `withdraw`,
`redeem`) are `nonReentrant`, so no state-changing path can execute inside that window. Slither
continues to report it because its cross-function reentrancy detector lists `totalAssets()` — a
`view` — among the reachable functions, and it does not model `nonReentrant` as protection. Reading
a stale NAV without being able to act on it is not exploitable, and the whole sequence is atomic.

The remaining results are gas and style: `cache-array-length`, `too-many-digits` (CREATE2
`creationCode`), `immutable-states`, `assembly` (the executor's `ecrecover` decode),
`cyclomatic-complexity`, and a set of `incorrect-equality` hits which are all `== 0` early-return
guards on balances — the correct way to express "nothing to do", not the computed-balance comparison
that detector targets.

---

# Positive observations

Not everything needed changing. Worth recording:

- **`MerkleDistributor` is sound.** Double-hashed leaves committing `(index, account, amount)`, a bitmap for claim state, an immutable root and deadline, and payment to the committed `account` rather than `msg.sender` — so third-party submission is harmless and front-running is pointless. Now covered by 10 tests including tampered-amount and tampered-recipient cases.
- **Vaults fail closed on oracle failure.** A stale or out-of-bounds price reverts rather than pricing the trade wrongly. This is the right default and it is why M-03 produced an unusable vault rather than a mispriced one.
- **`Ownable2Step` throughout.** A mistyped ownership transfer requires the recipient to accept, so a typo does not permanently orphan a contract.
- **Claim-before-transfer ordering.** Both `ZorphaVesting.claim` and `MerkleDistributor.claim` update state before transferring, so neither is reentrancy-sensitive.
- **Performance-fee-only economics.** No management fee means an idle vault costs a depositor nothing — a genuinely user-favourable choice that also removes a whole class of fee-accrual bugs.

---

# Pre-launch checklist

Ordered by dependency. Nothing below the first unchecked box should be started.

**Before mainnet deployment**

- [x] Fix V-01 through V-08; `forge test` fully green (158/158, 13 invariants)
- [x] Slither reports 0 high and 0 medium, triaged in [SLITHER-TRIAGE.md](SLITHER-TRIAGE.md)

      Correcting the record: this box previously read "Slither clean at high and
      medium severity (132 results, all informational or gas)". That was never
      observed. A mutually-exclusive flag pair plus a PATH problem meant Slither
      had never successfully compiled this project, and the deploy script
      reported the resulting crash as if it were a finding. The first run that
      actually completed (2026-09-01) returned 2 high and 43 medium. All 45 were
      read, judged false positives, and suppressed line-by-line with reasons.
- [x] Off-chain airdrop generator written and cross-checked against the on-chain verifier
- [ ] CI running `forge build && forge test` on every push, blocking merge
- [ ] **Third-party audit**, with the report published including accepted risks
- [ ] Governance Safe created; signers confirmed and geographically distributed
- [ ] Multi-key oracle updater set seated, `ORACLE_QUORUM` raised above 1

**At deployment**

- [ ] `GOVERNANCE` set to the Safe, verified `!= deployer` (the script enforces this)
- [ ] `LIQUIDITY_RECIPIENT` set to the protocol-owned liquidity address
- [ ] `AIRDROP_MERKLE_ROOT` generated from the published snapshot; root published *before* claims open
- [ ] Confirm the script's post-deploy assertions all passed
- [ ] Timelock queues and executes `ProtocolTreasury.acceptOwnership()` (two-step transfer)

**After deployment, before claims**

- [ ] Safe calls `ZorphaVesting.fund` with the real contributor and backer schedules
- [ ] Safe calls `ZorphaBuyback.setRouter` once a ZOR market exists
- [ ] Verify all contracts on the block explorer
- [ ] Publish addresses to `zorpha-web` env; confirm the portal's "not configured" banner clears
- [ ] Re-verify on-chain that `balanceOf(deployer) == 0`

**Governance**

- [ ] Replace all three legal templates with counsel-reviewed text
- [ ] Publish Season 1 snapshot criteria *before* taking the snapshot
- [ ] Decide whether to ship a Governor, or state indefinitely that voting weight has no venue

---

*Reviewed against OpenZeppelin Contracts 5.6.1, Solidity 0.8.28, Foundry 1.8.1, Slither. This is
an internal review by the authors of the code and **is not a substitute for a third-party audit** —
it reliably finds the bugs its reviewers were capable of imagining. Twenty-four findings in code
that had never been compiled is not evidence that a twenty-fifth does not exist.*

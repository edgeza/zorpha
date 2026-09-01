# Slither triage

Slither 0.11.5, 84 contracts, 96 detectors. `contracts/` only — `lib/`,
`test/`, `script/` and `node_modules/` are filtered out by
`slither.config.json`.

**Current state: 0 high, 0 medium. 98 findings remain, all low or below.**

Reproduce:

```bash
cd sidequest-protocol/contracts && ./script/deploy-and-verify.sh
```

Step 4 of that script runs Slither and refuses to deploy on any high or medium
finding. It writes the full report to `contracts/slither-report.json`
(gitignored, regenerated every run).

---

## Read this first: the tool was silently broken

Until 2026-09-01 this project had **never successfully run Slither**, and the
deploy script reported that fact as a clean-ish security failure. Three
separate faults stacked up:

1. The script passed `--fail-high --fail-medium`. Those are mutually exclusive
   in argparse — `--fail-medium` already means *medium or greater* — so Slither
   exited on a usage error without analysing anything.
2. Slither shells out to `forge` through the OS process API. On Windows that
   resolves against the **system** PATH, and `foundryup` installs into
   `~/.foundry/bin`, which is typically only on the shell's PATH. Even with the
   flags fixed, `crytic-compile` died with `FileNotFoundError` before reading a
   line of Solidity.
3. The whole thing was wrapped in
   `slither ... || echo "slither found high/medium issues"`. So a usage error, a
   missing binary and a genuine vulnerability all produced the same sentence.

Fault 3 is the one that mattered. Anything that makes a broken tool look like a
working tool reporting bad news is worse than the tool simply being absent,
because it converts "I should investigate" into "I know what this is".

The step now runs with `--fail-none` and reads findings out of the JSON report,
so the exit code means *Slither ran* and the report says *what it found*. A
tooling failure now prints `slither could not run … this is a tooling failure,
not a finding` and names the log.

Any earlier claim that this codebase was "Slither clean" was unverified.
This document is the first run that actually happened.

---

## Suppressed findings

Two detector families are excluded wholesale in `slither.config.json`. Every
other suppression is a `// slither-disable-next-line` on the exact line it
concerns, with its reasoning beside it — so the detector stays live for code
written later.

### Excluded in config

| Detector | Count | Why |
| --- | --- | --- |
| `incorrect-equality` | 28 | Every instance is a `== 0` guard: `supply == 0`, `updatedAt == 0`, `usdcSpent == 0`. The detector targets strict equality against attacker-movable balances (`address(this).balance == 32 ether`); the protocol has no such comparison. |
| `uninitialized-local` | 8 | Accumulator locals (`uint256 sum;` then `sum += …` in a loop). Solidity zero-initialises. Noise by construction. |

Both are re-reviewable by deleting them from `detectors_to_exclude`.

### Suppressed inline, with reasons

| Site | Detector | Verdict |
| --- | --- | --- |
| `ZorphaBuyback.execute` | `reentrancy-balance` ×2 (**High**), `unused-return` | The balance snapshots either side of the swap *are* the defence. `execute()` is `nonReentrant`, every other entrypoint is Timelock-only, and the router is Timelock-set, so no swap callee can re-enter to move them. Both legs are floored by the post-call balance, so a router donating tokens mid-swap can only revert the call, never inflate a burn. The ignored `swap()` return is deliberate and commented in the source: trusting it is exactly how a lying router would over-report a fill. Covered by `test_LyingRouterCannotFakeABurn`. |
| `YieldVault.setAdapter` | `reentrancy-no-eth` | Requires the *currently installed* adapter to be hostile, and installing one is `ADAPTER_SETTER_ROLE`. The guard blocks re-entry into every state-changing path; what remains reachable is `rawAssets()`, a view, which such an adapter could only mislead itself with. |
| `YieldVault._withdraw` | `unused-return` | `absorb()`'s return is ignored on purpose. A buffer that cannot cover the full shortfall pays what it has and the depositor takes the rest — the designed waterfall. `super._withdraw` transfers against the real balance, so an underpaying escrow reverts there rather than silently shorting anyone. Covered by `test_DepositorTakesTheLossOnlyAfterTheBufferIsGone` and `testFuzz_DepositorNeverLosesMoreThanTheUncoveredShortfall`. |
| `ERC4626YieldAdapter.withdraw` | `unused-return` ×3 | What actually arrived is measured by balance delta afterwards — the one number a miscounting target cannot lie about. Redeeming by share count on full exit is the fix for the rounding trap in `test_FullExitSurvivesShareRounding`. |
| `RWRotationVault._readPrice`, `SpotVaultMinimal._oraclePrice` | `unused-return` | Partially destructured `latestRoundData()`. Only `startedAt` is dropped; `roundId`, `answer`, `updatedAt` and `answeredInRound` are all checked on the following three lines. |

---

## What remains (non-blocking)

| Impact | Detector | Count | Note |
| --- | --- | --- | --- |
| Low | `calls-loop` | 56 | External calls inside loops, all in `RWRotationVault` over the basket. Bounded: the constructor enforces a basket of 2–5. |
| Low | `timestamp` | 19 | `block.timestamp` comparisons. All are multi-hour windows (oracle staleness, 7-day escrow delay, vesting cliffs) where validator drift is immaterial. |
| Low | `reentrancy-events` | 4 | Events emitted after external calls. Affects off-chain log ordering only, never on-chain state. |
| Low | `reentrancy-benign` | 3 | Writes after external calls that no other function reads. |
| Informational | `too-many-digits`, `missing-inheritance`, `assembly`, `costly-loop`, `cyclomatic-complexity` | 12 | Style. `assembly` is the ECDSA split in `StrategyExecutor`. |
| Optimization | `cache-array-length`, `immutable-states` | 4 | Gas. `performanceFee` could be `immutable` in two vaults. |

None of these block a deploy, and none are dismissed as wrong — they are
accepted at their stated severity.

---

## Still outstanding

Slither is a linter, not an audit. **No third-party audit has been performed.**
The first-loss waterfall in `FirstLossEscrow` — the mechanism the whole product
rests on — has been reviewed only by its author. That remains the gate before
mainnet, and static analysis passing does not move it.

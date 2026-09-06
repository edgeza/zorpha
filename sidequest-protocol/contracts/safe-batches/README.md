# Safe transaction batches

JSON files for the Safe Transaction Builder at https://app.safe.global.
Safe `0xC75E64Ccf3ce6E2F40939Ab58255681769BcF8C4`, chain shortname `robinhood`.

Each file is calldata only. Nothing here signs or sends: the Safe is 2-of-2, so
every batch needs a signature from the PC wallet `0x070E3c…f8eF` AND the phone
`0x40Aaa6…a844A` before it can execute.

## Two things that bite

**The nonce.** Transaction Builder assigns the next free nonce, which is rarely
the one a batch was written for. Check `nonce()` on the Safe and set it manually
on the review screen, or the batch queues behind something else and blocks it.

**Deadlines.** Batches containing a Uniswap `mint` carry a deadline. Generate
them shortly before signing, or regenerate: an expired deadline reverts with
`Transaction too old` and, because these batches run with `safeTxGas = 0`, the
whole Safe transaction reverts and the nonce does NOT advance.

## Executed

| File | What it did | Safe nonce |
|---|---|---|
| *(deleted)* | queue Timelock -> ProtocolTreasury handover | 0 |
| *(deleted)* | lock 800,000,000 ZOR in vesting, non-revocable | 1 |
| *(deleted)* | add second Safe owner, threshold 2 | 2 |
| *(deleted)* | first ZOR/USDG pool, concentrated band — drained by bots | 3 |
| `5-withdraw-position-1027313.json` | exit and burn that position | 4 |
| `A-consume-nonce5-send-1-ZOR.json` | throwaway to clear a stuck nonce | 5 |
| `6-new-pool-03pct-fullrange.json` | ZOR/USDG 0.3% pool, FULL RANGE | 6 |
| `C-launch-yield-vault.json` | launch zsUSDG over Steakhouse USDG | 7 |
| `D-first-deposit-zsusdg.json` | first deposit into the vault | 9 |
| `E-add-liquidity-100usdg.json` | deepen the pool via `increaseLiquidity` | 8 |
| `F-concentrated-lp-100usdg.json` | concentrated LP, -20%/+25% | 10 or 11 |
| `G-single-sided-zor.json` | single-sided ZOR, +50%/+200% | 10 or 11 |
| `H-rerange-concentrated.json` | re-range an idle position | 10 or 11 |

F, G and H all landed across nonces 10 and 11; the exact mapping was not recorded
at the time, which is the reason this file exists.

## Not yet executed

| File | Notes |
|---|---|
| `3-treasury-execute.json` | Executable from 2026-09-06 22:15:12 UTC. Until it runs, the deploy key `0x90D5fE…FB02` still owns ProtocolTreasury and can call `rescue()`. Nonce has moved well past 3 — set it manually. |
| `B-lower-seed-minimum.json` | Superseded: its `setParams` call was folded into `C` as action 0. |

## Liquidity, one standing rule

Keep the FULL-RANGE position `#1034952` in place. Concentrated bands (`F`, `G`,
`H`) hold a finite amount of ZOR at a price anyone can compute, and one was
emptied end-to-end in six minutes on 4 September. Full range cannot be drained
that way, and it is what stops a repeat.

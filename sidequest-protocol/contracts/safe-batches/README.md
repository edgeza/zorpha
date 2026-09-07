# Safe transaction batches

JSON files for the Safe Transaction Builder at https://app.safe.global.
Safe `0xC75E64Ccf3ce6E2F40939Ab58255681769BcF8C4`, chain shortname `robinhood`.

Each file is calldata only. Nothing here signs or sends: the Safe is 2-of-2, so
every batch needs a signature from the PC wallet `0x070E3c…f8eF` AND the phone
`0x40Aaa6…a844A` before it can execute.

Both of those are hot software keys, and 2-of-2 means each one is independently
capable of freezing the protocol by being lost. The Safe is the sole beneficiary
of a non-revocable 800,000,000 ZOR schedule, so there is no recovery path if
either key goes. Moving to 2-of-3 with a hardware key is the open fix.

## Two things that bite

**The nonce.** Transaction Builder assigns the next free nonce, which is rarely
the one a batch was written for. Check `nonce()` on the Safe and set it manually
on the review screen, or the batch queues behind something else and blocks it.

**Deadlines.** Batches containing a Uniswap `mint` carry a deadline. Generate
them shortly before signing, or regenerate: an expired deadline reverts with
`Transaction too old` and, because these batches run with `safeTxGas = 0`, the
whole Safe transaction reverts and the nonce does NOT advance.

## Record the nonce when you sign

This table was reconstructed from the chain on 7 September 2026 because six
executions had gone unrecorded and three rows were wrong. The nonce is free to
write down at signing time and expensive to recover afterwards, so write it
down.

Reconstruction method, if it is ever needed again. The Safe emits
`ExecutionSuccess` per execution and `ExecutionFailure` for an inner call that
failed while consuming its nonce. There are 18 of the former and none of the
latter, so the events map to nonces 0 to 17 in order with no gaps. Each
execution is then identified by the contracts its receipt touched and the
events they emitted.

## Executed

| Nonce | Block | File | What it did |
| --- | --- | --- | --- |
| 0 | | *(deleted)* | queue Timelock -> ProtocolTreasury handover |
| 1 | | *(deleted)* | lock 800,000,000 ZOR in vesting, non-revocable |
| 2 | | *(deleted)* | add second Safe owner, threshold 2 |
| 3 | | *(deleted)* | first ZOR/USDG pool, concentrated band, drained by bots |
| 4 | | `5-withdraw-position-1027313.json` | exit and burn that position |
| 5 | | `A-consume-nonce5-send-1-ZOR.json` | throwaway to clear a stuck nonce |
| 6 | 54993355 | `6-new-pool-03pct-fullrange.json` | ZOR/USDG 0.3% pool, FULL RANGE. Position `#1034952`, 11,103,864 ZOR and 488.57 USDG |
| 7 | | `C-launch-yield-vault.json` | launch zsUSDG over Steakhouse USDG |
| 8 | 55455450 | `F-concentrated-lp-100usdg.json` | concentrated LP, ticks 391020 to 395580. NEW position `#1045817`, 12,058,020 ZOR and 100 USDG |
| 9 | 55455977 | `D-first-deposit-zsusdg.json` | first deposit into the yield vault |
| 10 | 55829534 | `H-rerange-concentrated.json` | burned `#1045817`, minted `#1052227`, 12,065,062 ZOR and 200 USDG |
| 11 | 55830059 | `G-single-sided-zor.json` | single-sided ZOR, position `#1052234`, 10,000,000 ZOR and no USDG |
| 12 | 56256123 | `I-stock-vault-roles.json` | roles on the NVDA vault and its swap adapter, Safe's admin renounced |
| 13 | 56613695 | `3-treasury-execute.json` | Timelock executed the ProtocolTreasury handover |
| 14 | 56651597 | `J-seed-stock-vault.json` | seeded the NVDA vault, including its first rebalance |
| 15 | 56739485 | `K-adapter-admin-to-timelock.json` | swap adapter admin to the Timelock |
| 16 | 56853183 | `L-raise-seed-minimum.json` | `minSeedEscrow` 90 -> 1,000 USDG |
| 17 | 56864010 | `L-second-rebalance.json` | second rebalance of the NVDA vault |

Two files are prefixed `L`. They are distinct batches at nonces 16 and 17; the
table is the tiebreaker.

### Three corrections made on 7 September 2026

**`3-treasury-execute.json` had been sitting under "Not yet executed" with a
warning that the deploy key `0x90D5fE…FB02` still owned ProtocolTreasury and
could call `rescue()` to move any token balance anywhere.** It ran at nonce 13.
`ProtocolTreasury.owner()` is the Timelock `0x813D69B8…36Fc`, and `rescue()`
reverts `OwnableUnauthorizedAccount` for everyone else. The warning described a
hole that no longer existed, which is the worst kind of stale note: a reader
either panics or learns to distrust the file.

**Nonce 8 was recorded as `E-add-liquidity-100usdg.json`. It was `F`.** Nonce 8
minted a NEW position `#1045817`, confirmed by an ERC-721 `Transfer` from the
zero address to the Safe in the same receipt. An `increaseLiquidity` on an
existing position cannot do that.

**`F`, `G` and `H` were recorded as landing "across nonces 10 and 11", exact
mapping unknown.** They are nonces 8, 11 and 10 respectively. `H` is the only
one of the three whose receipt carries a pool `Burn`, because re-ranging closes
the old position first, and `G` is the only one that moves no USDG, because it
is single-sided.

## Never executed

| File | Notes |
| --- | --- |
| `B-lower-seed-minimum.json` | Superseded: its `setParams` call was folded into `C` as action 0. Nonce 16 has since reversed it. |
| `E-add-liquidity-100usdg.json` | **No onchain trace.** Position `#1034952` has exactly one `IncreaseLiquidity`, at its creation in nonce 6. The full-range position was never topped up, so the 100 USDG this batch would have added to it is not in the pool. The 100 USDG that did go in belongs to `F`, which is a separate concentrated position. |

That second row matters for any claim about market depth. Every USDG ever
placed on the quote side of this pair totals 788.57 across four mints, less
212.40 returned by the burn in nonce 10, so 576. There is no batch waiting to
change that.

## Liquidity, one standing rule

Keep the FULL-RANGE position `#1034952` in place. Concentrated bands (`F`, `G`,
`H`) hold a finite amount of ZOR at a price anyone can compute, and one was
emptied end-to-end in six minutes on 4 September. Full range cannot be drained
that way, and it is what stops a repeat.

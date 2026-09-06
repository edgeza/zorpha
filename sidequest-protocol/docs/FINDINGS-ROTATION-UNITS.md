# Finding: the rotation vault destroys 80% of a deposit on a clean round trip

**Status:** **fixed.** Found 2026-09-02 by inspection while closing the
"audit every fee-bearing contract" item from
[FINDINGS-FEE-CLAIM-BACKING.md](FINDINGS-FEE-CLAIM-BACKING.md).
**Contract:** `src/vaults/RWRotationVault.sol`
**Severity:** the most serious defect found in this codebase. A depositor who
deposits and immediately redeems, with no fee, no price movement and no other
holder, receives a fraction of what they put in. The remainder stays in the
vault, owned by nobody.

---

## The measurement

No performance fee. No price change. Alice is the only depositor.

| | |
| --- | --- |
| Deposited | **10 HOOD** (1,000,000,000 at 8dp) |
| Redeemed all shares, received | **2 HOOD** (200,000,000) |
| Retained by the vault | 160,000,000 base units, owned by no one |

**80% of principal, gone, in two transactions.**

## Why

`asset()` is `tokens[0]`; the ERC-4626 unit a depositor pays in and is paid out
in. `totalAssets()` returned `grossValue()` net of fees, and `grossValue()` is
denominated in **`baseAsset`**, a different token:

```solidity
// grossValue() sums every leg into BASE units
function totalAssets() public view override returns (uint256) {
    uint256 gross = grossValue();
    return gross > performanceFeeAccrued ? gross - performanceFeeAccrued : 0;
}
```

No conversion function is overridden, checked: `_convertToShares`,
`_convertToAssets`, `previewDeposit` and `previewRedeem` are all inherited. So
OpenZeppelin's `ERC4626` sized every share against a base-denominated total and
then moved `asset()` tokens by that number. The two differ by a decimal gap
**and** the oracle price.

Nothing reverts. The depositor is simply paid the wrong amount.

## It was live on the deployed vault

Rotation vault `0x6cb2a47bf911b7eed21a7b16d90c89986daa44e8` on testnet 46630:

| | |
| --- | --- |
| `asset()` | `0x3474…8ACF`, **18 decimals** |
| `baseAsset()` | `0x1C23…D735`, **6 decimals** |

A twelve-decimal gap plus a ~$250 price, so the error there is far larger than
the 5× in the fixture above. It was listed in the portal as `zqROT`, described
as "Rotates between approved real-world assets on a signed mandate".

`totalSupply` was **0**, so nobody lost money. The first depositor would have.

## Why nothing caught it

Nine tests passed either side of this, including a real fee test that is not
vacuous. None of them compared a deposit against its own redemption **in a
single unit**. Every assertion was either about a base-denominated quantity or
about shares, and both are internally consistent; the mismatch only shows when
you put HOOD in one end and count HOOD out the other.

`test_Units_DepositRedeemRoundTrip` does exactly that, and nothing more.

## Fix

`totalAssets()` converts to `asset()` units; the fee subsystem stays entirely in
base units.

```solidity
function netValueInBase() public view returns (uint256) {
    uint256 gross = grossValue();
    return gross > performanceFeeAccrued ? gross - performanceFeeAccrued : 0;
}

function totalAssets() public view override returns (uint256) {
    return baseToToken(0, netValueInBase());
}
```

`baseToToken` already existed as the exact inverse of `tokenToBase`, so the fix
is three lines. The split keeps each subsystem in one unit:

- **Fee subsystem**, `grossValue`, `performanceFeeAccrued`, `highWaterMark`,
  `getNavPerShare`, and the payout in `claimFees`, all base units, unchanged.
- **ERC-4626 surface**, `totalAssets`, and everything OpenZeppelin derives from
  it, asset units.

This is what `SpotVaultMinimal` already does: its `grossValue()` converts the
cash leg *into* asset units for precisely this reason. The rotation vault
converted everything the other way.

Reverting on a stale oracle is not a new failure mode: `grossValue()` already
prices every leg, so `totalAssets()` could always revert.

Round trip after the fix: **10 HOOD in, 10 HOOD out**, exactly.

## The two fee-state bugs, found at the same time

This vault was the third and last checked against the other two findings, and it
had both.

### Equalisation, and it bites the FIRST depositor here

The constructor seeds `highWaterMark = 10 ** baseDecimals` = 1,000,000. A real
entry NAV is base-value-per-share and lands nowhere near that, **20,000,000**
on the fixture. So the first depositor's own entry is already twenty times above
the mark, and the first fee evaluation charges 20% of a gain from the sentinel up
to their own entry price: **a gain nobody earned**.

On the other two vaults this needed a cohort to leave first. Here it is reachable
by the very first deposit. Fixed with `_markFirstEntry()`, as on the others.

### Fee-claim backing

Same as [FINDINGS-FEE-CLAIM-BACKING.md](FINDINGS-FEE-CLAIM-BACKING.md): the claim
is a fixed base-denominated number, `grossValue()` is live, and once the vault
empties the sentinel price cannot carry the encumbrance. Measured at **19.5%** of
the incoming deposit. Fixed with `_reconcileFeeClaimWhenEmpty()`.

That closes the audit item. **Three contracts subtract an accrued fee from a live
balance, and all three were affected.** The framing that found them was the
invariant, not the resemblance: `performanceFeeAccrued` is fixed, the balance
behind it is not, nothing binds them.

## One of my own tests was vacuous, which is worth recording

The first version of the second-cohort test asserted
`highWaterMark == getNavPerShare()` immediately after the new deposit. It passed
with `_markFirstEntry` **disabled**, because in that scenario the incoming price
happened to equal the departed mark; there was no gap to detect.

I only found it by disabling each fix and checking that a specific test failed.
That check is cheap and I had not been doing it. The replacement moves the price
between the exit and the entry so a gap is guaranteed, and it now fails
`40000000 != 10000000` without the fix.

Every fix in this file is now verified by disabling it:

| Disabled | Fails |
| --- | --- |
| `_markFirstEntry` | `..._MarksTheNewEntryPrice`, `test_FirstDepositor_PaysOnlyForTheirOwnGain` |
| `_reconcileFeeClaimWhenEmpty` | `test_UnclaimedFee_DoesNotDiluteTheNextDepositor` |
| `totalAssets` conversion | `test_Units_DepositRedeemRoundTrip` |

## Open

- [x] Fix the unit mismatch.
- [x] Apply both fee-state fixes.
- [x] Confirm every test detects the absence of its fix.
- [ ] **Auditor review.** This changes what a depositor receives, and it changes
      fee accounting. Three vaults now share two fixes that all need the same eye.
- [ ] **Redeploy the rotation vault.** The one on testnet has the broken
      arithmetic. It holds nothing, so there is nothing to migrate; but it is
      listed in the portal and must not stay listed.
- [ ] Add the round-trip assertion to the other two vaults. Both are internally
      consistent today, but nothing pins that, and this is the assertion that
      would have caught the worst bug in the codebase on day one.

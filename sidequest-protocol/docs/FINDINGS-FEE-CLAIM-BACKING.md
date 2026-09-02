# Finding: an unclaimed performance fee becomes a debt paid by the next depositor

**Status:** open, unremediated. Reproduced in
`test/vaults/SpotVaultMinimal.t.sol::test_UnclaimedFee_DilutesTheNextDepositor`,
which passes and therefore pins the behaviour as it currently stands.
**Contracts:** `src/vaults/SpotVaultMinimal.sol` and `src/vaults/YieldVault.sol`.
Both. See **It is in the yield vault too** below — I guessed the yield vault
was safe and the guess was wrong.
**Severity:** a depositor loses value on entry with no warning and no
counterparty who did anything wrong. **10%** of the deposit in the spot
reproduction, **9%** in the yield one, both instant and both silent.

Found while fixing [FINDINGS-EQUALISATION.md](FINDINGS-EQUALISATION.md) in the
spot vault — the equalisation test reported an entry NAV of 0.9 where 1.0 was
expected, and the 0.1 turned out to be a second, unrelated defect.

---

## The mechanism

`performanceFeeAccrued` is a number **denominated in asset units**. It is backed
by whatever the vault happens to be holding, which may be either leg:

```solidity
function totalAssets() public view override returns (uint256) {
    uint256 gross = grossValue();
    return gross > performanceFeeAccrued ? gross - performanceFeeAccrued : 0;
}
```

Strike the fee while the vault sits in cash, then let the price move against
cash, and the claim outgrows the value behind it. Nothing rebases the claim,
because nothing is watching the relationship between the two.

## The reproduction, step by step

A 20% performance fee, an asset priced at $50,000, a depositor holding ten of it.

| Step | Price | Vault holds | `performanceFeeAccrued` | `grossValue()` | `totalAssets()` |
| --- | --- | --- | --- | --- | --- |
| Alice deposits 10 | 50k | 10 asset | 0 | 10 | 10 |
| Keeper goes flat | 50k | 500,000 cash | 0 | 10 | 10 |
| Price halves | 25k | 500,000 cash | 0 | **20** | 20 |
| Fees evaluated | 25k | 500,000 cash | **2** | 20 | 18 |
| Alice redeems all | 25k | 50,000 cash | 2 | 2 | 0 |
| **Price recovers** | 50k | 50,000 cash | **2** | **1** | **0** |
| Bob deposits 10 | 50k | 50,000 cash + 10 asset | 2 | 11 | **9** |

Alice was charged correctly: she gained 10, and 20% of 10 is 2. Nothing about
her transaction is wrong.

But the 2 was struck at $25,000 and held as cash. At $50,000 that cash is worth
**1**. The claim says 2. The gap is 1, and `totalAssets()` floors at zero rather
than reporting it.

Bob deposits 10 and holds 9. His loss is exactly the uncovered part of Alice's
fee — asserted to within 2 base units in the test. He was given no signal: the
vault reported `totalAssets() == 0`, which is indistinguishable from an ordinary
empty vault.

## It is in the yield vault too

I first wrote that the yield vault was "likely unreachable — it holds a single
leg, so the claim and the backing cannot diverge on a price move". The reasoning
was sound and the conclusion was wrong. A price move is not the only thing that
can separate a claim from its backing. **A venue loss does it just as well.**

`test_UnclaimedFee_AgainstAVenueLoss` in `test/vaults/YieldVault.t.sol`, on a 10%
fee vault:

| | |
| --- | --- |
| Alice deposits | 1,000 |
| Venue doubles, fee struck | 100 |
| Alice redeems out | vault empty, 100 held against a 100 claim — exactly covered |
| **Venue loses 90% of what remains** | backing 10, claim **100** |
| Bob deposits | 1,000 |
| **Bob holds** | **910** |

Bob's 90 of loss is the shortfall to the unit. Same defect, same silence.

And the route is *more* ordinary here, not less. A lending or staking venue
taking a haircut is the central risk a yield vault exists to take a view on. The
spot vault needs a price to move against the leg a fee was struck in; the yield
vault only needs the venue to do the thing the vault is built to survive.

This also means option 3 below has to be evaluated against both contracts.

### Why the guess was wrong, which matters more than the finding

I reasoned from the mechanism I had just seen (a price splitting two legs) rather
than from the invariant that mechanism violated (a claim in one unit, backed by a
balance that can move independently of it). Reasoning from the example finds the
second instance only if it resembles the first. Reasoning from the invariant finds
the class. The invariant here is one line:

> `performanceFeeAccrued` is a fixed number. `grossValue()` is not. Nothing binds
> them, so anything that moves the second breaks the pair.

Put that way, "which contracts are affected" is answerable without a test: every
contract that subtracts an accrued fee from a live balance. That is both of them,
and it would have been both of them on the first pass.

## Three things make it worse than it first looks

### It is silent by construction

`totalAssets()` clamps at zero. That clamp is the right defensive choice for
arithmetic — an unsigned underflow would be worse — but it means the one number
that could reveal the shortfall is the number that hides it. There is no view
function that reports the claim against its backing.

### The fee cannot be claimed out of the way

```solidity
uint256 bal = IERC20(asset()).balanceOf(address(this));
paid = accrued <= bal ? accrued : bal;
require(paid > 0, "SpotVaultMinimal: no underlying liquidity");
```

`claimFees` pays from the **asset leg only**. In the state above the vault holds
nothing but cash, so `claimFees` reverts. The claim is simultaneously
uncollectable by its beneficiary and costly to the next depositor: it can only be
resolved by someone depositing the asset — which is to say, by the victim.

### The only lever is silent too

`writeDownAccruedFees` is the sole escape, and it **emits no event**:

```solidity
function writeDownAccruedFees(uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
    uint256 accrued = performanceFeeAccrued;
    require(amount > 0 && amount <= accrued, "SpotVaultMinimal: bad write-down");
    performanceFeeAccrued = accrued - amount;
}
```

An admin can reduce the protocol's fee claim to zero and leave no trace an
indexer or a depositor could follow. That is a governance-transparency gap
independent of this finding and cheap to close.

### It does not get stuck. It completes.

The obvious hope is that an unbacked claim simply cannot be paid, and sits there
as a harmless accounting artifact. It does not.

`YieldVault._pullFromAdapter` takes what is available rather than reverting:

```solidity
uint256 available = adapter.totalAssets();
adapter.withdraw(needed < available ? needed : available);
```

So `claimFees` reverts on the empty vault — and then succeeds the moment a new
depositor tops the adapter up. Pinned at the end of
`test_UnclaimedFee_AgainstAVenueLoss`: the recipient is paid the **full 100**,
of which **90 was Bob's principal**, and `performanceFeeAccrued` returns to zero
with everything looking settled.

This is the sentence that matters: **a depositor's principal is transferred to
the fee recipient, and the books balance afterwards.** Not stuck, not flagged,
not recoverable.

### And the yield vault has no lever at all

`writeDownAccruedFees` exists **only on `SpotVaultMinimal`**. Grepped across
`src/`: it is the single write-down in the codebase. `YieldVault` has no way to
forgive a claim, so governance cannot choose to absorb the shortfall even having
spotted it. The only paths are to pay it out of the next depositor or to upgrade
the contract.

## How reachable is it

More reachable than the equalisation case, because it needs no dust and no
unusual sequence — only that a fee be struck while the vault is in one leg and
the price then move against that leg. For a long/flat vault, going flat is the
*point*: it is what the strategy does in a drawdown, which is also when fees
crystallise. The precondition is the intended behaviour.

It does not require the vault to empty. Emptying only makes the loss land on a
single identifiable depositor instead of being spread across holders, which is
what made it visible.

## What is not wrong with it

The fee itself. Alice's charge was correct on her own gain, and the high-water
mark did its job. This is not an overcharge — the protocol is owed 2. The defect
is that the debt is carried in units the vault may not hold, with no mechanism to
reconcile the two and no disclosure that it is outstanding.

## Options

Not chosen — the first two are cheap, the rest are design decisions.

1. ~~**Emit an event on `writeDownAccruedFees`.**~~ **Done.**
   `AccruedFeesWrittenDown(amount, remaining)`, plus three tests covering the
   emission, the bounds and the access control. No behaviour change; landed
   independently of the decisions below.
1b. **Give `YieldVault` a write-down too.** It has none, so it has no remediation
   path at all. Symmetric with the spot vault, but it adds an admin power to a
   contract that currently lacks one, so it is a decision rather than a cleanup.
2. **Expose the shortfall.** A view returning the claim and its backing, so the
   condition is at least legible on chain and a UI can refuse the deposit. Does
   not fix anything; stops the silence.
3. **Denominate the claim in shares, not assets.** A fee held as a share of the
   vault moves with the vault, so it cannot outgrow its backing. This is what
   most performance-fee designs do, and it makes the whole class of defect
   unreachable rather than mitigated. Largest change and the one to put to the
   auditor first.
4. **Crystallise on the leg actually held.** Track the claim per leg at accrual
   time. Preserves asset denomination but doubles the accounting.
5. **Settle before rebalancing.** Require the claim be paid or written down
   before the keeper may change the mix. Simple, but hands the keeper a way to
   block rebalancing by leaving a fee unpaid.

Option 3 looks right to me. I have not implemented it: it changes what the fee
recipient owns and how every existing accrual would be interpreted, and that is
not a decision to take without the auditor.

## Reproducing

```bash
forge test --match-test test_UnclaimedFee_DilutesTheNextDepositor -vv
```

## Open

- [x] Reproduce it in a test that pins current behaviour.
- [x] Option 1: make the write-down observable. Landed, with tests.
- [ ] Decide between options 2–5. Option 3 is the one that removes the class.
- [ ] Decide option 1b: whether `YieldVault` gets a write-down lever.
- [x] Check `YieldVault` for the same defect. **It has it**, via a venue loss
      rather than a price move; 9% of the incoming deposit in the reproduction.
      My prediction that it was safe was wrong.
- [ ] Audit every remaining contract that subtracts an accrued fee from a live
      balance. That framing, not "contracts like the spot vault", is the one that
      finds them: two of two checked are affected.
- [ ] If the vault ships before this is fixed, the depositor-facing copy has to
      say that entering a vault can cost value on entry, and the UI should read
      the shortfall and refuse. Neither exists today.

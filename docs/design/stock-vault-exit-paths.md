# Stock vault exit paths

Slice 2 of the oracle-free stock vault. Fixes the withdrawal path on
`SpotVaultMinimal`, which cannot deliver what it advertises.

**Spec status:** approved design, not yet implemented.
**Predecessor:** `docs/design/oracle-free-stock-vault.md`, which carries slice 1
and the measurements that produced this.

## Why

Three defects, all measured against the live vault
`0xB129495f0ad616EdD2f28b3B49470FC1f0FAD413` on 7 September 2026. They look like
three problems and are one.

**1. A withdrawal cannot reach the cash leg.** `_withdraw` covers a shortfall by
buying asset with cash: `cashIn = assetToCash(shortfall)` rounds down, `minOut`
permits the fill to come back up to `maxSlippageBps` short, and then
`super._withdraw` transfers the full amount and reverts. At a 50/50 position:

```
redeem 40%   ok
redeem 50%   ERC20InsufficientBalance(vault, 27710798703467998,
                                             27710807884585675)
```

short by 9,181,117,677 wei. The swap runs and buys asset, just less than the
following transfer demands. So the vault was exitable only as far as its asset
leg reached, and the tolerance that stops the swap reverting is exactly what
makes the transfer revert.

**2. A refusing oracle locks everyone out of the standard path.** `grossValue()`
calls `cashToAsset(cashBalance)`, which reads the oracle, so `totalAssets()`
reverts whenever any of the TWAP adapter's five guards fires. The liquidity
floor exists to make the adapter refuse when the pool goes thin, which is
precisely the stressed market where holders want out. Measured with the oracle
mocked to revert as its floor would:

```
redeem()               false
redeemEmergency()      true
totalAssets() readable false
maxRedeem() readable   true
```

**3. The vault lies about which path works.** That last line is the real defect.
`maxRedeem` is not overridden, so it returns `balanceOf(owner)` and reports
shares as redeemable while `redeem` reverts. `maxWithdraw` reverts outright, and
so does `maxDeposit`, which cannot even be asked whether deposits are open. Any
integrator reading the ERC-4626 interface is misled.

### One root cause

The exit path depends on oracle-priced conversion of the cash leg.

- it cannot convert the dust, giving defect 1
- it cannot price the leg when the oracle refuses, giving defect 2
- it prices the leg with no allowance for the cost of converting it, which is
  the shortfall in defect 1 and the lie in defect 3

`totalAssets()` values the cash leg at the oracle price. Realising that value
means crossing a venue that charges. The gap between those two numbers is the
whole bug.

### Severity, stated honestly

Lower than it first appears. `redeemEmergency` already pays both legs pro-rata
with no oracle read and no venue call, and provably empties the vault:

```
redeemEmergency(all)   true, cash left 0, asset left 0
```

So there has always been a working exit and the vault is not a fund trap. No
third party is exposed either: `totalSupply` equals the governance Safe's
balance on both live vaults. What is broken is the standard path, and the
interface's honesty about it, which is what a depositor or an integrator would
actually rely on.

## What changes

One contract, `src/vaults/SpotVaultMinimal.sol`. No new constructor parameters:
the haircut reuses `maxSlippageBps`, which already exists and already means
"the venue cost this vault tolerates".

### The withdrawal swap must fully cover, or revert

```solidity
uint256 bal = IERC20(asset()).balanceOf(address(this));
if (bal < assets) {
    uint256 shortfall = assets - bal;
    uint256 cashIn = assetToCash(shortfall);
    if (cashToAsset(cashIn) < shortfall) cashIn += 1;            // round UP
    cashIn = (cashIn * (10000 + maxSlippageBps)) / 10000 + 1;    // pay the cut
    uint256 cashBal = cashAsset.balanceOf(address(this));
    if (cashIn > cashBal) cashIn = cashBal;
    _swap(address(cashAsset), asset(), cashIn, shortfall);       // must cover
}
super._withdraw(caller, receiver, owner, assets, shares);
```

Three changes from the deployed version: the conversion rounds up rather than
down, the input is grossed up so the venue's cut is paid out of the cash leg
rather than out of the depositor's delivery, and `minOut` is the whole shortfall
so a fill that cannot cover reverts inside `_swap` instead of at the transfer
with `ERC20InsufficientBalance`. That revert is
`require(received >= minOut, "slippage")`, a plain `Error(string)` and not a
custom error, which is worth knowing because it is the failure an integrator
will actually see.

Note which line carries the guarantee. It is `minOut`, not the gross-up: the
gross-up only makes the fill likely to clear the bound, while `_swap` refusing
below `minOut` is what makes under-delivery impossible. Simplifying the gross-up
away would cost nothing visible until a wider spread arrived.

### The bounds must be deliverable, not aspirational

```solidity
/// Value the cash leg, or report that the oracle is refusing to price it.
/// The zero short-circuit matters: a vault holding no cash needs no oracle
/// to answer and must not be gated on one.
function _cashLegValue() internal view returns (uint256 value, bool priced) {
    uint256 cashBal = cashAsset.balanceOf(address(this));
    if (cashBal == 0) return (0, true);
    try this.cashToAsset(cashBal) returns (uint256 v) { return (v, true); }
    catch { return (0, false); }
}

/// What an exit could actually realise: the asset leg outright, plus the cash
/// leg net of the venue's cut for converting it.
function _deliverableAssets() internal view returns (uint256 amount, bool priced) {
    (uint256 cashValue, bool ok) = _cashLegValue();
    if (!ok) return (0, false);
    uint256 realisable = (cashValue * (10000 - maxSlippageBps)) / 10000;
    return (IERC20(asset()).balanceOf(address(this)) + realisable, true);
}

function maxRedeem(address owner) public view override returns (uint256) {
    if (isCircuitBreakerActive) return 0;
    (uint256 deliverable, bool priced) = _deliverableAssets();
    if (!priced) return 0;
    uint256 held = balanceOf(owner);
    // Exact case first. Deriving the bound by conversion loses wei to the
    // virtual-share offset and refuses a full exit the vault can serve.
    if (previewRedeem(held) <= deliverable) return held;
    return _convertToShares(deliverable, Math.Rounding.Floor);
}

function maxWithdraw(address owner) public view override returns (uint256) {
    if (isCircuitBreakerActive) return 0;
    (uint256 deliverable, bool priced) = _deliverableAssets();
    if (!priced) return 0;
    uint256 byShares = _convertToAssets(balanceOf(owner), Math.Rounding.Floor);
    return byShares < deliverable ? byShares : deliverable;
}
```

The exact-case short-circuit is not an optimisation, and it was found by
testing. An earlier version derived the bound only by conversion, and
OpenZeppelin's virtual-share offset made `_convertToShares(assetBalance)` come
out 501 wei below the supply, so a vault holding **no cash at all** was refused
a full exit. That reintroduced the original defect in a new form.

`maxDeposit` and `maxMint` get the same treatment. Both reach `totalAssets()`
and so revert when the oracle refuses, though only once supply is non-zero,
because `maxDeposit` short-circuits on an empty vault. Measured against the
deployed contract:

```
supply 0,   maxDeposit callable   true
supply > 0, maxDeposit callable   false
supply > 0, maxMint    callable   false
```

Both must return zero rather than revert. A caller cannot currently even ask
whether the vault is open.

### The in-kind exit stops being gated by the breaker

`redeemEmergency` is the only path that needs neither oracle nor venue, and it
pays both legs exactly pro-rata. It is currently blocked by
`isCircuitBreakerActive`. That is backwards: a breaker should suspend the paths
that can misprice and preserve the one that cannot. The per-owner cooldown
stays, since it exists to stop the path being used as a free rebalance.

## What it delivers

Measured with a prototype, against a fresh vault seeded with the live position,
on a mainnet fork:

| position | `maxRedeem` | executes |
|---|---:|---|
| fully long, 10000 | 100.00% | yes |
| 7500 | 99.75% | yes |
| 50/50, 5000 | 99.50% | yes |
| 2500 | 99.25% | yes |
| fully flat, 0 | 98.99% | yes |

**Superseded.** Those figures are from before the conversion cost was charged to
the withdrawer; see "Who bears the conversion cost, settled" below. Capacity is
now 100% at every position, and the withheld margin has moved out of the bound
and into the payout, where it belongs.

Against 40% before, on a 50/50 position, with the failure arriving as an untyped
ERC-20 error.

Every advertised maximum executes. The residual one percent is `maxSlippageBps`,
the vault's own slippage allowance, withheld against the possibility of a
costlier fill. It is not the venue's realised cost: the live pool charges 5bps,
a factor of twenty less. Declining to promise the allowance is correct rather
than a shortcoming, since the allowance is what the vault must tolerate, not
what a fill actually costs. `redeemEmergency` recovers it in kind.

## What this deliberately does not do

- **It does not make `totalAssets()` survive a refusing oracle.** Falling back
  to the asset leg alone would keep everything readable, and would underpay
  anyone redeeming during the outage while handing their share of the cash leg
  to the holders who stayed. Closing the standard path and leaving the in-kind
  path, which is exactly fair, is the better trade. This is a fairness argument,
  not a liveness one.
- **It does not touch the first-loss coverage decay.**
  `FirstLossEscrow.minCoverageBps` is enforced only on leader withdrawal, so
  deposits dilute coverage without limit. Real, and not this spec: the
  requirements cannot be settled until permissionless launch is designed, and
  coverage on the one live yield vault is 1,999% with the Safe as its only
  depositor. It belongs to slice 3.
- **It does not add a second asset, baskets, or permissionless launch.**

## Migration

Immutable contracts, so this is a redeploy and a move.

1. **Deploy** the new `SpotVaultMinimal` with the slice-1 parameters, admin on
   the Safe so the role batch can complete atomically. Verify on Blockscout
   before anything else, using the v2 standard-input API with a browser user
   agent, because forge's agent is challenged.
2. **Propose, through the Timelock, granting `VAULT_ROLE` on the existing swap
   adapter to the new vault.** This is the long pole. The adapter gates callers
   by that role and its `DEFAULT_ADMIN_ROLE` is the Timelock, whose minimum
   delay is 172,800 seconds. A fresh vault cannot trade for 48 hours. Deploying
   a new adapter instead would skip the wait and add an unaudited address; take
   the wait.
3. **After the delay, execute the grant.**
4. **One Safe batch:** `redeemEmergency` the whole position out of the old
   vault, which empties both legs with nothing stranded; approve and deposit
   into the new vault; `rebalanceTo` the intended target; grant `KEEPER_ROLE`
   and `RISK_COUNCIL_ROLE` as slice 1 did; hand `DEFAULT_ADMIN_ROLE` to the
   Timelock; Safe renounces last. Same shape as batch I, and replayed as the
   Safe against the artifact on disk before signing.
5. **Register** the new vault: a Supabase migration in the shape of 013, adding
   the row and seeding `indexer_cursor` at the deployment block.
6. **Repoint** `zorpha-web/lib/deployment.ts` and `lib/contracts.ts`, and drop
   the old vault from `LIVE_VAULTS`.

The old vault is left empty and unregistered. It holds nothing and no third
party has shares, so there is nothing to wind down.

### The track record spans both addresses

Receipts are keyed by vault address, and the old vault keeps its two. The record
is therefore presented **by manager, not by vault**: `rebalances.manager`
already exists and `/portal/managers/[address]` already aggregates across
vaults, so the manager's history is continuous across the redeploy while the
per-vault pages show their own chapters. A "succeeds" pointer from the old
vault's row to the new one makes the lineage explicit rather than implied.

This matters beyond tidiness. The protocol's claim is that a stranger can verify
a track record without trusting anybody. If the record restarts every time a
contract is fixed, that claim is false, so the record has to survive the
protocol's own redeploys.

## Testing

The existing suite is 403 tests and stays green. The prototype broke four, all
of them bug-reproduction tests in `test/vaults/WithdrawShortfall.t.sol` plus
`test_EmergencyRedeem_WorksWhenTheVenueIsDry`, which assert that the defect
exists. They are rewritten to assert the fixed behaviour, including that the
refusal is now the typed `ERC4626ExceededMaxRedeem` rather than
`ERC20InsufficientBalance`.

### The invariant that would have caught all three

```
for any position, and any holder:
    redeem(maxRedeem(owner))          must succeed
    withdraw(maxWithdraw(owner))      must succeed
    redeemEmergency(balanceOf(owner)) must succeed, whatever the oracle does
```

Nothing asserted this, which is why a `maxRedeem` returning `balanceOf(owner)`
unconditionally survived. It goes into `test/invariants/` as a handler-driven
invariant with rebalances, deposits, withdrawals and oracle failures in the
action set, and as a bounded fuzz test over target weight and redemption
fraction.

### The harness gaps that hid the defects

Each is a test-infrastructure fix rather than a contract fix, and each is why a
green suite meant nothing here.

- **`MockSpotAdapter` fills at the oracle price exactly.** There was no venue
  cost for a fill to come short by. The spot vault suite moves to
  `SlippingSpotAdapter` at the live pool's 5bps; the perfect-fill mock stays for
  tests that are genuinely about something else. The comment on
  `SlippingSpotAdapter` already noted it was written because the slippage bound
  had never been exercised. It hid this too.
- **The suite pairs an 8-decimal asset with 6-decimal cash.** One cash unit is
  100 asset units there, and `previewRedeem`'s truncation absorbs the rounding.
  The live pair is 18 against 6, where one USDG unit is 4.3e9 NVDA wei. The
  decimal gap is the mechanism, so the suite must carry an 18/6 pair.
- **No test made the oracle refuse.** Stale and non-positive answers were
  covered; a reverting `latestRoundData()` was not, and reverting is what the
  TWAP adapter's guards actually do.
- **No test asserted that `maxDeposit` could be called at all.**

### Fork tests

- A fresh vault seeded with the live position, exercising capacity and execution
  at 10000, 5000 and 0, which is the table above.
- The migration Safe batch, replayed as the Safe against the artifact on disk.

## Who bears the conversion cost, settled

The open question this section used to carry has been decided: **the exiting
holder pays for their own conversion.** It was recorded here as a slice-3
question, and it was recorded wrongly, claiming the cost already fell on the
withdrawer "through the haircut in `_deliverableAssets`". That was false. The
haircut caps how much the last exit may take and never touches who pays.

### What was wrong

The withdrawer was paid `previewRedeem(shares)`, the full oracle-priced NAV of
their shares, while the venue's cut on converting the cash leg came out of the
pool. So it landed on whoever stayed. Measured, two holders, the live 5bps
venue, a 50/50 position, one holder exiting:

```
bob previewRedeem before   999750000000000000
bob previewRedeem after    974762626260775861
                           a loss of 249 bps of his position
```

That is one stranger's exit taking 2.49% from a holder who did nothing. It
scales with realised venue cost, which is square-law in trade size, so a thin
pool and a large exit could take most of a small remainder.

### The correction

The withdrawer's own shares pay for their own conversion. Let `gross` be the
oracle NAV of the shares presented, `bal` the asset leg, and `h`
`maxSlippageBps`. The payout `net` is defined by

```
net + cost(net) = gross,    cost(net) = max(0, net - bal) * h / (10000 - h)
```

which solves in closed form to

```
net = (gross * (10000 - h) + bal * h) / 10000
```

floored, so rounding favours the vault. An exit the asset leg already covers
converts nothing and therefore pays nothing: `net == gross` whenever
`gross <= bal`.

`previewRedeem` returns `net`. `previewWithdraw` inverts it, returning the
shares needed to cover a requested net payout plus its own cost. The remaining
holders are left exactly whole: the shares burned are worth `net` plus the cut,
and both leave the pool together.

### It also removes the capacity limit

Inverting the bound at the maximum gives `gross` equal to the whole NAV, because
a holder absorbing their own conversion cost can always be served. So capacity
is **100% of the holding at every position**, replacing the earlier table's
98.99% to 100% band. The withdrawer receives less than oracle NAV by their own
conversion cost, which is the honest number, rather than receiving all of it and
sending the bill to everyone else.

`redeemEmergency` is untouched and remains the cost-free exit: it pays both legs
in kind, pro rata, converting nothing.

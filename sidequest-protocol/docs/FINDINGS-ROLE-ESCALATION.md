# The timelock on adapter installs was advisory

**Severity:** high, defeats the delay that protects depositor funds
**Status:** fixed in the deploy handover; live testnet deployment still needs the re-handover below
**Found:** 2 September 2026, by asking why a queued migration had to wait

## What was wrong

`YieldVault.setAdapter` is `onlyRole(ADAPTER_SETTER_ROLE)`, and `DeployVaultsV1`
hands that role to the `Timelock` and to nobody else. Read on its own, that says
repointing where depositor funds are held takes 48 hours; the window a
depositor would need to exit ahead of a venue change they disagree with.

It did not take 48 hours. OpenZeppelin's `AccessControl` makes
`DEFAULT_ADMIN_ROLE` the admin of every role unless `_setRoleAdmin` says
otherwise, and the deploy handed `DEFAULT_ADMIN_ROLE` to governance. So:

```
getRoleAdmin(ADAPTER_SETTER_ROLE)   == DEFAULT_ADMIN_ROLE
gov holds DEFAULT_ADMIN_ROLE        == true
grantRole(ADAPTER_SETTER_ROLE, gov) from gov  -> SUCCEEDS
```

Two transactions, grant, then call; and the delay is gone. Confirmed by
simulation against the deployed testnet vault `0x521a90ba…`, not by reading.

## Why it matters more than it looks

The threat model is not a stranger. Nobody outside governance gains anything
here. It is that **the guarantee the code advertised did not exist**:

- if the governance Safe is compromised, the 48h window that was supposed to let
  depositors exit provides none, funds can be moved to an attacker's venue in
  one block
- `updateDelay` on `TimelockController` requires `msg.sender == address(this)`,
  so shortening the delay genuinely does need the delay. The one place the
  timelock was airtight was protecting itself
- an advisory delay is worse than no delay, because it stops anyone looking for
  the protection. A drill was written and passed asserting the Timelock refuses
  early execution, true, and it proved the *Timelock* withholds while saying
  nothing about whether the *vault* requires the Timelock at all

The same reasoning applies to every other role, since `DEFAULT_ADMIN_ROLE`
administers all of them: governance could grant itself `UPDATER_ROLE` on the
oracle, `KEEPER_ROLE` on the executor, and so on. Those are less severe because
no delay was ever claimed for them, governance managing its own operators is
the intended design. `ADAPTER_SETTER_ROLE` is the one where a security property
was asserted and not delivered.

## What was already right

The leadership layer. `VaultLauncher` gives launched vaults `DEFAULT_ADMIN_ROLE`
to the Timelock and keeps only `ADAPTER_SETTER_ROLE` for itself, then renounces
admin explicitly:

```solidity
IAccessControl(vault).grantRole(0x00, vaultAdmin);            // vaultAdmin == Timelock
IAccessControl(vault).grantRole(ADAPTER_SETTER_ROLE, address(this));
IAccessControl(vault).renounceRole(0x00, address(this));
```

Confirmed on the launched vault `0xba812020…`: the Timelock holds
`DEFAULT_ADMIN_ROLE`, the launcher holds `ADAPTER_SETTER_ROLE`, governance holds
neither. Nothing to escalate from. The bug was only ever in the three
factory-deployed vaults.

That asymmetry is the useful lesson: the newer, more carefully reviewed path got
it right, and the older one was never revisited when `ADAPTER_SETTER_ROLE` was
introduced.

## The fix

`DeployVaultsV1._handOverVault` replaces `_handOver` for the three factory
vaults. `DEFAULT_ADMIN_ROLE` goes to the Timelock; governance keeps
`RISK_COUNCIL_ROLE` and `KEEPER_ROLE`; the deployer is stripped of everything;
and the function asserts all three afterwards, because a handover that silently
half-applied would leave exactly the state it exists to prevent.

Governance keeping `RISK_COUNCIL_ROLE` is deliberate; the circuit breaker has
to be pullable in one block, and a delay on the emergency stop would be a worse
bug than this one.

What governance loses is the `DEFAULT_ADMIN_ROLE` set: `claimFees`,
`setFeeRecipient`, `setSwapAdapter`, `setFirstLossEscrow`,
`writeDownAccruedFees`. Every one of those either moves money or moves the
pointer to where money lives, and none is an emergency.

### The one operational cost

`claimFees` is in that set, so **collecting accrued fees now takes a queued
Timelock action.** Nobody is harmed by a two-day delay on the protocol's own
fee revenue, and the recipient is fixed, so this was accepted rather than
worked around.

The tidier alternative is to gate `claimFees` on `KEEPER_ROLE`, which is where
`evaluateFees` already sits and which governance retains, routine operations on
a fixed recipient, with everything that changes a pointer left timelocked. That
is a contract change, so it needs a vault redeploy and therefore a factory
redeploy, since `VaultFactory` compiles vault bytecode into itself. It was not
worth that risk for ergonomics on the day, and it is a reasonable thing for an
auditor to push back on. Flagged rather than silently decided.

## Tests

`test/vaults/RoleEscalation.t.sol`, 8 tests. The first two are the pair that
matters:

- `test_OldHandover_GovEscalatesToSetAdapter_WithNoDelay` reproduces the bug , 
  gov grants itself the role and repoints the adapter, and the test asserts it
  *succeeds*. A security test asserting the hole is open reads backwards, and is
  the point: it is the reason the deploy must not give gov admin
- `test_AdapterSetterRole_IsAdministeredByDefaultAdmin` pins the mechanism, so
  self-administering the role later is a deliberate act with a failing test
  attached rather than a quiet change to the threat model

The rest assert gov cannot grant itself the role or call `setAdapter`, that the
Timelock still can (or the fix would have bricked the function it protects),
that gov keeps the circuit breaker, that a holder of only operational roles has
no path, and that the deployer is left with nothing.

## Still to do on the live testnet deployment

The deploy script is fixed; the three already-deployed vaults are not. No
redeploy is needed; the handover is repeatable:

```
# for each of spot 0x11ea3629, rotation 0x15257073, yield 0x521a90ba
grantRole(0x00, 0x8cca58C0…)   # timelock becomes admin
grantRole(KEEPER_ROLE, gov)    # if not already held
revokeRole(0x00, gov)          # gov loses the escalation path
```

Both calls must come from gov while it is still admin, and the revoke must be
last. After it, `script/testnet-yield-drill.sh` step 6 (`claimFees`) needs the
Timelock, so that leg becomes a queued action or the drill reports it as
skipped.

## Related

- [[FINDINGS-EQUALISATION]]; the other case where a passing test asserted less
  than its name implied
- `docs/BURNED-KEYS.md`, why a deployer left holding admin is not hypothetical
  here

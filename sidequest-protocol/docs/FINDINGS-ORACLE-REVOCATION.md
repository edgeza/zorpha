# Finding: revoking UPDATER_ROLE does not remove an updater's price from the median

**Status:** open. Found 2026-09-02 while revoking a burned key's oracle access on
testnet 46630, transaction
`0x68a0fbb6d24bc513c53962527d61c6a8f78c8b8c8f305b312adf20997066c18f`.
**Contract:** `src/oracle/MedianOracle.sol`
**Severity:** an incident-response action that looks like it worked and only
partly does. Not exploitable on its own; it lengthens the window in which a
compromised key still moves the price.

---

## What happened

I told the user to revoke a burned key's oracle access with:

```bash
cast send $ORACLE 'revokeRole(bytes32,address)' $(cast keccak 'UPDATER_ROLE') $BURNED_KEY
```

That was the wrong command. `MedianOracle` has `removeUpdater`, and it was
callable at the time, `updaters.length` was 2 against a `minQuorum` of 1, so its
own guard would have passed.

## Why the difference matters

`UPDATER_ROLE` gates `report()`. It does not gate being *counted*:

```solidity
uint256 n = updaters.length;
for (uint256 i = 0; i < n; i++) {
    Report memory r = reports[updaters[i]];
    if (r.timestamp != 0 && block.timestamp - r.timestamp <= maxStaleness) {
        fresh[count] = r.price;
        count++;
        ...
```

`latestRoundData` iterates the **`updaters` array** and reads each entry's stored
report. It never checks `hasRole`. So revoking the role stops a key writing a
*new* price and leaves its *last* price in the median until that report ages past
`maxStaleness`.

`removeUpdater` does both, revokes the role *and* removes the array entry, so
the influence stops in the same transaction:

```solidity
function removeUpdater(address u) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(hasRole(UPDATER_ROLE, u), "not updater");
    require(updaters.length > minQuorum, "MedianOracle: would break quorum");
    _revokeRole(UPDATER_ROLE, u);
    ...  // swap-and-pop out of `updaters`
}
```

## Consequences on the testnet oracle

| | |
| --- | --- |
| `hasRole(UPDATER_ROLE, burned key)` | **false**; the key cannot report again |
| `updaters` array | still contains it |
| `updaterCount()` | reports **2**; only **1** address holds the role |
| `reports[burned key]` | `(0, 0)`; it never reported, so it contributes nothing |
| `latestRoundData()` | healthy, on governance's fresh price |

**The security goal was achieved by luck, not by the command.** That key had
never reported. Had it reported a minute earlier, its price would have kept
counting toward the median for up to an hour after the revoke, and the
transaction receipt would have looked exactly as successful.

The array entry is also now **permanently unremovable**: `removeUpdater` requires
`hasRole(UPDATER_ROLE, u)`, which is now false, so it reverts with
`"not updater"`. `updaterCount()` on this oracle over-reports by one for the life
of the contract. That is academic here because the vault layer is being
redeployed, but it would not be academic on mainnet.

## The operational rule

**Use `removeUpdater`, never `revokeRole`, to retire an oracle updater.** For a
mainnet 2-of-3 with a one-hour staleness window, `revokeRole` on a compromised
key leaves that key's price in the median for up to an hour, during which every
vault's NAV, slippage bound and rebalance decision still partly follows it.

If the role has already been revoked directly, the array entry cannot be cleaned
up and the oracle must be replaced to restore an accurate `updaterCount()`.

## It also weakens a gate I had just written

`MainnetSafety.check` reads `oracle.updaterCount()`, which is `updaters.length`.
As this incident shows, that can exceed the number of addresses actually holding
`UPDATER_ROLE`. On a clean deploy the two agree, because `addUpdater` is the only
path and it maintains both; so the gate is sound at deploy time, which is when
it runs. But it is counting array slots, not authority, and the two can diverge
afterwards.

Hardened in `DeployVaultsV1` instead, where the seated list is known: every
address in `ORACLE_UPDATERS` must hold the role, and `updaterCount()` must equal
the list length exactly. That is checkable at the one moment both facts are
available.

## Options

1. **Make the read path role-aware.** Add `hasRole(UPDATER_ROLE, updaters[i])` to
   the `latestRoundData` loop, so a revoked updater stops counting immediately
   however it was revoked. Costs one `SLOAD` per updater per read, on the hottest
   path in the protocol; every NAV read, every rebalance, every redemption.
2. **Make `removeUpdater` work on an already-revoked address.** Drop the
   `hasRole` precondition so the array can always be cleaned up. Small, and it
   makes the mistake above recoverable instead of permanent.
3. **Document and rely on the runbook.** Cheapest, and it depends on whoever is
   responding to an incident at 3am reading the right line.
4. **Both 1 and 2.** Correct by construction, and recoverable when someone still
   gets it wrong.

Option 2 is unambiguously worth doing; it is a one-line change that turns a
permanent mistake into a fixable one. Option 1 is the real fix and it costs gas
on the hottest read in the system, which is a decision rather than a cleanup.

## Open

- [x] Document the rule: `removeUpdater`, never `revokeRole`.
- [x] Harden the deploy-time oracle assertion so roles and array length must
      agree.
- [ ] Decide options 1-4.
- [ ] Put "use `removeUpdater`" in the incident-response runbook, which does not
      currently mention the oracle at all.
- [ ] The testnet oracle now over-reports `updaterCount()`. Replaced rather than
      repaired, as part of the vault-layer redeploy.

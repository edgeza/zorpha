# Keys that must never be used on mainnet

Every key here has had its private key exposed in plaintext — pasted into a
terminal that was then shared, or printed by `cast wallet new` and copied along
with the surrounding output. They are all fine on testnet, where nothing of
value sits behind them. None of them may hold a role, a balance or a signing
authority on chain 4663.

Checked against, not remembered: `script/check-burned-keys.sh` fails if any of
these addresses holds a role on a mainnet deployment.

| Address | Was | Exposed | Still used on testnet |
| --- | --- | --- | --- |
| `0xB4a7C2DeebB5EaDC34e120bC8a5708508DC17f4b` | deployer; `authorizedSigner` until rotated | private key pasted in full | yes — deploy key for 46630 |
| `0x5EC41DBe5Ca00cB00B896570c5Ff8fFc274cB5F6` | manager signer (`zorpha-signer`) | printed by `cast wallet new`, copied with the surrounding terminal output | yes — signs testnet rebalances |

## Why the signer being public does not invalidate the testnet drills

The spot and rotation drills prove that the EIP-712 path works: that a
correctly signed rebalance is accepted, that a replayed one reverts on the
nonce, that an expired one reverts on the deadline, and that the rate limit
bites. None of those depend on the signing key being secret — they depend on
the *signature* being checked. A public key signs just as validly.

What a public signer would break is the security property on mainnet: anyone
could direct rebalances within a vault's limits. `StrategyExecutor` bounds the
damage (per-vault `dailyLimit`, oracle staleness checks, no path to withdrawing
depositor funds) but "an attacker can move the book within limits, repeatedly"
is not a position to launch from.

## Before mainnet

- [ ] Generate a fresh deployer key on a machine whose terminal output is not
      shared. Fund it, deploy, and let the handover assertions empty it as
      designed.
- [ ] Generate a fresh manager signer the same way, and set it via
      `setAuthorizedSigner` from the Safe.
- [ ] `GOVERNANCE` must be a Safe on mainnet, not an EOA, so no single key
      exposure is fatal. See DEPLOY-ENV.md 0.1.
- [ ] Run `script/check-burned-keys.sh` against the mainnet deployment and
      confirm it passes.

## How to avoid adding to this list

`cast wallet new` prints the private key to stdout, so anything that captures
the terminal captures the key. Two ways round it:

```bash
# Import straight into a keystore; the key is prompted for, never echoed.
cast wallet import <name> --interactive

# Or generate into a keystore directly, so it is never printed at all.
# The path and name are positional, not flags.
cast wallet new ~/.foundry/keystores <name>
```

The second is the safer default and is what the guides should say.

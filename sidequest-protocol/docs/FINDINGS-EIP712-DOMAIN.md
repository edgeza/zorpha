# Finding: the rebalance domain is non-standard, so managers sign blind

**Status:** open. Noticed 2026-09-02 while writing
`contracts/script/testnet-spot-drill.sh`.
**Contract:** `src/executor/StrategyExecutor.sol`
**Severity:** not a vulnerability. The domain is cryptographically sound. It is
a usability and auditability gap, plus one real forward-compatibility problem,
and it sits directly on top of the mechanism this protocol is marketed on.

---

## What it is

`StrategyExecutor` builds its own EIP-712 domain:

```solidity
keccak256("EIP712Domain(uint256 chainId,address executor)")
```

The conventional domain is:

```solidity
keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
```

Two fields present, two absent, and the address field renamed.

## What is fine about it

The two fields that matter for replay are both there. `chainId` stops a
signature crossing chains; the executor's own address stops it crossing
contracts. `_verifySignature` enforces the 65-byte layout, normalises `v`, and
rejects high-`s` per EIP-2, so malleability is handled. Nothing here lets a
signature be reused where it should not be.

The drill confirms the encoding empirically rather than by reading: it computes
the domain separator and compares it against `DOMAIN_SEPARATOR()` on chain, so
a mistake in either surfaces as a mismatch rather than an opaque
`InvalidSignature`.

## What is not fine

**1. Managers sign blind.** This is the important one.

Wallets render EIP-712 payloads as readable fields only when the domain matches
the standard type. With a custom domain, MetaMask, Rabby and the rest fall back
to showing an opaque 32-byte hash. A manager approving a rebalance sees

```
0xe7fe9ddd0fbced38e5f4e1dfdbcaa2ca232fc9e96ce68f28858d3442e35278f0
```

and not

```
Rebalance
  vault:            0x95fb…3708
  targetWeightBps:  5000
  nonce:            3
  expiry:           2026-09-02 13:15 UTC
```

The protocol's whole claim is that a manager cannot move the book by holding a
key, only by signing an instruction that is checkable and published. That claim
is weakest at the exact moment it matters most: a manager who cannot read what
they are signing cannot refuse a payload that says something other than what
they were told. The receipt is published afterwards, which is good, and does
not help the person signing.

It also means a compromised frontend can present one rebalance and have a
manager sign another, with nothing in the wallet to give it away.

**2. There is no `version`.** The standard includes it so a protocol can
invalidate a whole generation of signatures by bumping it. Without it, if the
`Rebalance` struct ever gains a field, the old and new payloads live under the
same domain and any signature still in flight stays valid against whichever
interpretation the contract now holds. There is no in-flight signature problem
today because `MAX_SIGNAL_EXPIRY` is 7 days, which bounds the window — but that
is a mitigation by accident, not by design.

**3. `name` is absent**, which costs nothing cryptographically and is the field
wallets show first when they can render anything at all.

## Options

Not chosen. Changing the domain invalidates every signature made under the old
one, so it is a coordinated change, not a patch.

1. **Adopt the standard domain.** Use OpenZeppelin's `EIP712` base with a name
   and version. Managers then see readable fields, and `version` becomes
   available for future format changes. Every unexecuted signature is
   invalidated at the swap, which on a 7-day expiry window means announcing it
   and waiting a week.
2. **Keep the domain, add a readable summary.** The signing UI shows the decoded
   fields next to the hash it is about to sign. Cheaper, and worth doing
   regardless — but it protects only against a manager's own inattention, not
   against a frontend that lies, because the hash is still the only thing the
   wallet independently confirms.
3. **Accept it.** Defensible while the signer is a single internal key on
   testnet. Not defensible once third-party leaders sign for other people's
   money, which is the direction the leadership layer is already going.

Option 1 before any external manager signs anything, is my read. It should be
in the auditor's scope either way, since it is a deliberate deviation from a
standard and deviations are what an auditor most wants to know about.

## Reproducing

`./script/testnet-spot-drill.sh <signer> <keeper>` prints the digest it signs.
Paste that payload into any wallet's typed-data signing flow and observe that
nothing renders.

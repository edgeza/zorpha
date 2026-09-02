# Finding: the rebalance domain is non-standard, so managers sign blind

**Status:** **fixed.** Noticed 2026-09-02 while writing
`contracts/script/testnet-spot-drill.sh`, fixed the same day by adopting the
standard domain via OpenZeppelin's `EIP712`. See **Fix** below.
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

---

## Fix

`StrategyExecutor` now inherits OpenZeppelin's `EIP712`, constructed with
`("Zorpha Strategy Executor", "1")`. The hand-rolled separator is gone.

Adopting the library rather than just correcting the type string was the point.
The hand-rolled version was first rewritten to the standard four fields, and then
checked against `lib/openzeppelin-contracts/.../EIP712.sol` -- which turned out to
use the identical type string *and* the identical
`abi.encode(TYPE_HASH, nameHash, versionHash, chainid, address(this))` layout.
Having proved the two were byte-for-byte equivalent, keeping the local copy meant
maintaining hand-written cryptography with no remaining advantage over an audited
implementation. So it went.

What comes free with it:

- **ERC-5267 `eip712Domain()`.** Tooling can now read the domain off the chain
  instead of reconstructing it from a type string copied out of the source. Four
  drill scripts were doing exactly that, each one silent typo away from
  signatures rejected as `InvalidSignature` with no indication why.
- **Fork handling**, already present locally and now the library's problem.

`DOMAIN_SEPARATOR()` is kept as a public getter: it is the conventional name, and
the drill scripts read it to cross-check their own encoding.

### The four drills

All four rebuild the domain independently and compare against the chain, which is
worth keeping -- it catches an encoding mistake as a mismatch rather than an
opaque signature failure. Updated to the four-field form; `cast abi-encode` goes
from `f(bytes32,uint256,address)` to `f(bytes32,bytes32,bytes32,uint256,address)`.

Verified word by word rather than by inspection: the encoding is exactly five
32-byte words, and word 1 is the canonical typehash.

### Timing

Deliberately before mainnet. Changing the domain invalidates every signature
built against the old one, which costs nothing while the only such signatures
live in testnet drills, and would strand anything in flight afterwards.

### Five tests, because nothing pinned this

Worth recording why it survived. Every signing test in the suite reads
`DOMAIN_SEPARATOR()` off the executor and signs against whatever it returns.
That is right for testing the signature path, and it means **all eighteen passed
under the non-standard domain and would pass under a malformed one** -- the same
shape of gap as a fee assertion on a zero-fee vault.

`StrategyExecutorDomainTest` pins the domain itself:

- `test_Domain_TypehashMatchesThePublishedConstant` -- asserts the typehash
  equals `0x8b73c3c6...400f`, the published EIP-712 constant, which comes from
  outside this repository. **This is the only one that survives a typo copied
  into both the contract and the test**, which is the failure the other four
  cannot see.
- `test_Domain_IsTheStandardFourFieldDomain` -- rebuilds the separator from the
  literal type string.
- `test_Domain_IsNotTheOldNonStandardOne` -- without it, reverting the fix would
  leave the suite green.
- `test_Domain_IsDiscoverableViaErc5267` -- and that what 5267 reports actually
  rebuilds the separator it describes.
- `test_Domain_RebuildsOnAFork`.

199 tests pass.

## Open

- [x] Adopt the standard domain.
- [x] Pin it, with at least one assertion anchored outside the repository.
- [x] Update the drill scripts.
- [ ] Re-run the spot, rotation and lifecycle drills against a **redeployed**
      executor. The one on testnet 46630 still carries the old domain, so those
      scripts will now fail their own domain check -- correctly, and loudly,
      which is what that check exists for.
- [ ] Confirm in a wallet that a rebalance now renders as readable fields. The
      whole point is what a manager sees, and that cannot be asserted in Foundry.

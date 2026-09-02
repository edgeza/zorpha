#!/usr/bin/env bash
# Prove the signed-rebalance path on a live chain, including its refusals.
#
# Phase 3 of docs/LAUNCH-CHECKLIST.md, "Spot vault (zqHOOD)". This is the
# mechanism the whole protocol is marketed on: a manager cannot move the book
# by holding a key to the vault, only by signing an instruction that the vault
# will check. So the refusals matter as much as the success -- a signature that
# can be replayed, or that never expires, is the same as no signature.
#
# What is asserted:
#
#   success        a correctly signed rebalance executes, nonce advances,
#                  rebalanceCount increments, a receipt is emitted
#   replay         the SAME signature submitted again reverts on the nonce
#   expiry         a signature whose deadline has passed reverts
#   expiry cap     a deadline beyond MAX_SIGNAL_EXPIRY reverts
#   bad signer     a signature from a key that is not authorizedSigner reverts
#   weight         targetWeightBps > 10000 reverts
#   rate limit     one more than dailyLimit within 24h reverts
#
# Two accounts, and the separation is the point:
#
#   <signer>  signs the EIP-712 payload. Needs no gas and sends nothing.
#   <keeper>  submits it. Needs KEEPER_ROLE on the executor and gas.
#
# Submission is NOT permissionless -- executeRebalance is onlyRole(KEEPER_ROLE).
# The checklist claimed otherwise for a while, and that wrong belief is part of
# why KEEPER_ROLE went unseated and unnoticed.
#
# Usage:
#   ./script/testnet-spot-drill.sh zorpha-signer zorpha-gov
#                                  ^signer       ^keeper

set -euo pipefail

if ! command -v cast >/dev/null; then
  [[ -d "$HOME/.foundry/bin" ]] && { PATH="$HOME/.foundry/bin:$PATH"; export PATH; }
fi
command -v cast >/dev/null || { echo "ERROR: cast not found" >&2; exit 1; }
command -v node >/dev/null || { echo "ERROR: node not found" >&2; exit 1; }

SIGNER_ACCT="${1:-}"
KEEPER_ACCT="${2:-}"
[[ -n "$SIGNER_ACCT" && -n "$KEEPER_ACCT" ]] || {
  echo "usage: $0 <signer-keystore> <keeper-keystore>" >&2
  exit 1
}

RPC="${RH_TESTNET_RPC_URL:-https://rpc.testnet.chain.robinhood.com/rpc}"
CHAIN_ID=46630
WEB_ENV="../../zorpha-web/.env.local"
VAULTS="broadcast/DeployVaultsV1.s.sol/$CHAIN_ID/run-latest.json"

bold() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m+\033[0m %s\n' "$1"; }
info() { printf '    %s\n' "$1"; }
die()  { printf '\n  \033[31mx %s\033[0m\n\n' "$1" >&2; exit 1; }

bi()  { MSYS_NO_PATHCONV=1 node -e 'const [a,op,b]=process.argv.slice(1);const A=BigInt(a),B=BigInt(b);
  const f={add:()=>A+B,sub:()=>A-B,mul:()=>A*B,div:()=>A/B,min:()=>A<B?A:B,max:()=>A>B?A:B}[op];
  if(!f) throw new Error("unknown op: "+op);
  process.stdout.write(f().toString())' -- "$1" "$2" "$3"; }
eq()  { [[ "$1" == "$2" ]]; }

env_of() { grep -E "^$1=" "$WEB_ENV" | head -1 | cut -d= -f2-; }
num()    { awk '{print $1}'; }
call()   { cast call "$@" --rpc-url "$RPC" | num; }

[[ -f "$WEB_ENV" ]] || die "no $WEB_ENV"
[[ -f "$VAULTS" ]]  || die "no $VAULTS"

EXEC=$(env_of NEXT_PUBLIC_STRATEGY_EXECUTOR_ADDRESS)
SIGNER=$(cast wallet address --account "$SIGNER_ACCT")
KEEPER=$(cast wallet address --account "$KEEPER_ACCT")

# The spot vault is the CREATE2 child with a cashAsset, identified by behaviour
# rather than a hardcoded address that goes stale on the next deploy.
VAULT=$(MSYS_NO_PATHCONV=1 node -e '
  const j = require(process.argv[1]);
  const seen = new Set();
  for (const t of j.transactions || [])
    for (const x of t.additionalContracts || [])
      if (x.address && !seen.has(x.address)) { seen.add(x.address); console.log(x.address); }
' "./$VAULTS" | while read -r a; do
  cash=$(cast call "$a" 'cashAsset()(address)' --rpc-url "$RPC" 2>/dev/null | num || true)
  [[ -n "$cash" ]] && { echo "$a"; break; }
done)
[[ -n "$VAULT" ]] || die "could not find the spot vault in $VAULTS"

bold "Spot vault signed-rebalance drill"
info "executor  $EXEC"
info "vault     $VAULT"
info "signer    $SIGNER   (signs; no gas, sends nothing)"
info "keeper    $KEEPER   (submits; needs KEEPER_ROLE and gas)"

# ─── Preflight ──────────────────────────────────────────────────────────────
bold "Preflight"

ONCHAIN_SIGNER=$(call "$EXEC" 'authorizedSigner()(address)')
eq "${ONCHAIN_SIGNER,,}" "${SIGNER,,}" \
  || die "executor trusts $ONCHAIN_SIGNER, not $SIGNER.
     Rotate it: setAuthorizedSigner from governance."
ok "executor trusts this signer"

K_ROLE=$(call "$EXEC" 'KEEPER_ROLE()(bytes32)')
eq "$(call "$EXEC" 'hasRole(bytes32,address)(bool)' "$K_ROLE" "$KEEPER")" true \
  || die "$KEEPER lacks KEEPER_ROLE on the executor, so it cannot submit.
     executeRebalance is onlyRole(KEEPER_ROLE) -- submission is not permissionless."
ok "keeper holds KEEPER_ROLE"

eq "$(call "$EXEC" 'paused()(bool)')" false || die "the executor is paused"
ok "executor is not paused"

LIMIT=$(call "$EXEC" 'dailyLimit(address)(uint256)' "$VAULT")
[[ "$LIMIT" != "0" ]] || die "dailyLimit for this vault is 0, which DISABLES the
     rate limit (the executor reads 'if (limit > 0)'). Set one:
       cast send $EXEC 'setDailyLimit(address,uint256)' $VAULT 4 --account <gov>"
ok "rate limit is $LIMIT per rolling 24h"

# A funded vault, and a priced one.
#
# rebalanceTo opens with:
#   if (tvl == 0) { targetWeightBps = targetBps; return; }
# so on an empty vault every signature below is accepted, nothing trades,
# rebalanceCount stays put and no receipt is emitted. The drill would report
# the signature checks as passing while proving nothing about the thing they
# gate. That is exactly how the first run failed -- "rebalanceCount went
# 0 -> 0" -- and the drill's assumption was wrong, not the vault.
TVL=$(cast call "$VAULT" 'grossValue()(uint256)' --rpc-url "$RPC" 2>/dev/null | num || echo "")
[[ -n "$TVL" && "$TVL" != "0" ]] || die "the vault's grossValue is ${TVL:-reverting}.
     An empty or unpriced vault takes rebalanceTo's early return, so this drill
     would pass without trading anything. Run the setup first:
       ./script/testnet-spot-setup.sh <governance-keystore>"
ok "vault is funded and priced: grossValue $TVL"

MAX_EXPIRY=$(call "$EXEC" 'MAX_SIGNAL_EXPIRY()(uint256)')
NONCE0=$(call "$EXEC" 'nonces(address)(uint256)' "$VAULT")
COUNT0=$(call "$VAULT" 'rebalanceCount()(uint256)')
info "nonce $NONCE0, rebalanceCount $COUNT0, max expiry ${MAX_EXPIRY}s"

# ─── Signing ────────────────────────────────────────────────────────────────
# The domain is NOT the standard EIP712Domain. This executor uses
#   EIP712Domain(uint256 chainId,address executor)
# with no name and no version, so the usual typed-data tooling cannot produce
# this digest and `cast wallet sign --data` is no use. The digest is assembled
# by hand and the domain separator is read back off the contract and compared,
# so a mistake in the encoding fails here rather than as an opaque
# InvalidSignature revert.
#
# Worth noting beyond this drill: a non-standard domain means a wallet cannot
# render the payload as readable typed data. A manager signing in MetaMask sees
# an opaque 32-byte hash, not "rebalance vault X to Y bps". That is blind
# signing, and it is the failure mode this protocol's whole receipt story is
# meant to avoid. See docs/FINDINGS-EIP712-DOMAIN.md.
DOMAIN_TYPEHASH=$(cast keccak "EIP712Domain(uint256 chainId,address executor)")
DOMAIN=$(cast keccak "$(cast abi-encode 'f(bytes32,uint256,address)' "$DOMAIN_TYPEHASH" "$CHAIN_ID" "$EXEC")")
ONCHAIN_DOMAIN=$(call "$EXEC" 'DOMAIN_SEPARATOR()(bytes32)')
eq "$DOMAIN" "$ONCHAIN_DOMAIN" \
  || die "domain separator mismatch.
     computed  $DOMAIN
     on chain  $ONCHAIN_DOMAIN
     Every signature below would be rejected. Fix the encoding, not the chain."
ok "domain separator matches the contract"

REBALANCE_TYPEHASH=$(call "$EXEC" 'REBALANCE_TYPEHASH()(bytes32)')

# digest = keccak256(0x1901 || domainSeparator || structHash)
digest_for() {
  local weight=$1 nonce=$2 expiry=$3
  local sh
  sh=$(cast keccak "$(cast abi-encode 'f(bytes32,address,uint16,uint256,uint256)' \
        "$REBALANCE_TYPEHASH" "$VAULT" "$weight" "$nonce" "$expiry")")
  cast keccak "$(printf '0x1901%s%s' "${DOMAIN#0x}" "${sh#0x}")"
}

# --no-hash: the digest is already the 32 bytes to sign. Without it cast would
# apply the personal_sign prefix and produce a signature the contract rejects.
sign_for() {
  cast wallet sign --no-hash --account "$SIGNER_ACCT" "$(digest_for "$1" "$2" "$3")"
}

submit() {
  cast send "$EXEC" 'executeRebalance(address,uint16,uint256,uint256,bytes)' \
    "$VAULT" "$1" "$2" "$3" "$4" \
    --rpc-url "$RPC" --account "$KEEPER_ACCT" >/dev/null 2>"$ERRFILE"
}

ERRFILE=$(mktemp)
trap 'rm -f "$ERRFILE"' EXIT
reason() { grep -oE '[A-Z][A-Za-z]+\(' "$ERRFILE" | head -1 | tr -d '(' || echo "reverted"; }

NOW=$(cast block latest --field timestamp --rpc-url "$RPC")
GOOD_EXPIRY=$(bi "$NOW" add 3600)

# ─── 1. A correctly signed rebalance ────────────────────────────────────────
bold "1/7  A correctly signed rebalance executes"

# The target must differ from the current allocation by more than
# rebalanceThresholdBps of tvl, or rebalanceTo takes its OTHER early return:
#   if (diff * 10000 < rebalanceThresholdBps * tvl) { targetWeightBps = t; return; }
# which also trades nothing and emits nothing. A vault holding all of one leg
# moved to 5000 bps shifts half of tvl, far past a 200 bps threshold.
CUR_WEIGHT=$(call "$VAULT" 'targetWeightBps()(uint16)')
WEIGHT="${SPOT_TARGET_BPS:-5000}"
THRESH=$(call "$VAULT" 'rebalanceThresholdBps()(uint16)')
info "current target $CUR_WEIGHT bps -> $WEIGHT bps, threshold $THRESH bps of tvl"

N1=$(bi "$NONCE0" add 1)
SIG=$(sign_for "$WEIGHT" "$N1" "$GOOD_EXPIRY")
info "weight 5000 bps, nonce $N1, expiry $GOOD_EXPIRY"
submit "$WEIGHT" "$N1" "$GOOD_EXPIRY" "$SIG" || die "a valid rebalance was REJECTED: $(reason)
     $(tail -2 "$ERRFILE")"
ok "executed"

eq "$(call "$EXEC" 'nonces(address)(uint256)' "$VAULT")" "$N1" || die "nonce did not advance to $N1"
ok "nonce advanced to $N1"
COUNT1=$(call "$VAULT" 'rebalanceCount()(uint256)')
eq "$COUNT1" "$(bi "$COUNT0" add 1)" || die "rebalanceCount went $COUNT0 -> $COUNT1"
ok "vault rebalanceCount $COUNT0 -> $COUNT1"

# ─── 2. Replay ──────────────────────────────────────────────────────────────
# The same bytes again. If this succeeds, any observer can repeat a manager's
# instruction at a moment of their choosing.
bold "2/7  The same signature again must revert"
if submit "$WEIGHT" "$N1" "$GOOD_EXPIRY" "$SIG"; then
  die "REPLAY SUCCEEDED. A captured signature can be re-executed at will."
fi
ok "replay reverted: $(reason)"

# ─── 3. Expired ─────────────────────────────────────────────────────────────
bold "3/7  An expired signature must revert"
N2=$(bi "$N1" add 1)
PAST=$(bi "$NOW" sub 60)
SIG_OLD=$(sign_for "$WEIGHT" "$N2" "$PAST")
if submit "$WEIGHT" "$N2" "$PAST" "$SIG_OLD"; then
  die "an EXPIRED signature executed. Deadlines are not enforced."
fi
ok "expired reverted: $(reason)"

# ─── 4. Expiry too far ──────────────────────────────────────────────────────
# A signature good for a year is a standing authority, not an instruction.
bold "4/7  A deadline beyond the cap must revert"
TOO_FAR=$(bi "$(bi "$NOW" add "$MAX_EXPIRY")" add 86400)
SIG_FAR=$(sign_for "$WEIGHT" "$N2" "$TOO_FAR")
if submit "$WEIGHT" "$N2" "$TOO_FAR" "$SIG_FAR"; then
  die "a deadline $((86400 / 3600))h beyond MAX_SIGNAL_EXPIRY was accepted."
fi
ok "expiry cap enforced: $(reason)"

# ─── 5. Wrong signer ────────────────────────────────────────────────────────
# The keeper signs its own instruction. It has KEEPER_ROLE, so it may submit --
# but it is not the authorized signer, so it may not decide.
bold "5/7  A signature from the wrong key must revert"
DIGEST=$(digest_for "$WEIGHT" "$N2" "$GOOD_EXPIRY")
SIG_WRONG=$(cast wallet sign --no-hash --account "$KEEPER_ACCT" "$DIGEST")
if submit "$WEIGHT" "$N2" "$GOOD_EXPIRY" "$SIG_WRONG"; then
  die "the KEEPER signed its own rebalance and it EXECUTED. Submission
     authority and signing authority are not separated."
fi
ok "wrong signer reverted: $(reason)"

# ─── 6. Impossible weight ───────────────────────────────────────────────────
bold "6/7  A weight above 100% must revert"
SIG_BAD=$(sign_for 10001 "$N2" "$GOOD_EXPIRY")
if submit 10001 "$N2" "$GOOD_EXPIRY" "$SIG_BAD"; then
  die "targetWeightBps of 10001 was accepted."
fi
ok "weight bound enforced: $(reason)"

# ─── 7. Rate limit ──────────────────────────────────────────────────────────
# One rebalance is already spent from step 1, so fill the rest of the window
# and then try once more.
bold "7/7  The rolling rate limit must bite"
# Alternate the target so each submission is a real move past the threshold.
# Repeating one weight would pass the signature checks and then take the
# sub-threshold early return -- which still consumes a nonce and a rate-limit
# slot, so the limit would still be reached, but the drill would be asserting
# the limit against a sequence of no-ops.
RL_WEIGHT=$(bi 10000 sub "$WEIGHT")
info "rate-limit submissions use $RL_WEIGHT bps so each is a genuine move"
REMAINING=$(bi "$LIMIT" sub 1)
info "limit $LIMIT, one already used; submitting $REMAINING more, then one too many"
NEXT="$N1"
for ((i = 0; i < REMAINING; i++)); do
  NEXT=$(bi "$NEXT" add 1)
  S=$(sign_for "$RL_WEIGHT" "$NEXT" "$GOOD_EXPIRY")
  submit "$RL_WEIGHT" "$NEXT" "$GOOD_EXPIRY" "$S" \
    || die "rebalance $((i + 2)) of $LIMIT was rejected before the limit: $(reason)"
  info "  $((i + 2))/$LIMIT ok"
done

NEXT=$(bi "$NEXT" add 1)
S=$(sign_for "$RL_WEIGHT" "$NEXT" "$GOOD_EXPIRY")
if submit "$RL_WEIGHT" "$NEXT" "$GOOD_EXPIRY" "$S"; then
  die "rebalance $((LIMIT + 1)) succeeded against a limit of $LIMIT.
     The rate limit does not bite, so a compromised signer is unbounded."
fi
ok "rebalance $((LIMIT + 1)) reverted: $(reason)"

bold "Drill passed"
echo "  A signed instruction executes once, and only once, only from the"
echo "  authorized signer, only before its deadline, only within the weight"
echo "  bound, and only $LIMIT times a day. The keeper can submit and cannot"
echo "  decide."
echo

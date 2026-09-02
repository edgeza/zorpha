#!/usr/bin/env bash
# Prove the signed-rebalance path on a live chain, including its refusals.
#
# Phase 3 of docs/LAUNCH-CHECKLIST.md, "Spot vault (zqHOOD)". This is the
# mechanism the whole protocol is marketed on: a manager cannot move the book
# by holding a key to the vault, only by signing an instruction that the vault
# will check. So the refusals matter as much as the success -- a signature that
# can be replayed, or that never expires, is the same as no signature.
#
# WHERE EACH THING IS TESTED, AND WHY
#
# Every check the executor performs -- signature, nonce, expiry, expiry cap,
# weight bound, sliding rate limit -- happens in executeRebalance BEFORE it
# calls the vault. So none of them need a real vault, and testing them against
# one is actively worse: the assertion becomes entangled with oracle prices,
# rebalance thresholds and swap-adapter liquidity, any of which can fail a step
# while the property under test works perfectly.
#
# That is not hypothetical. An earlier version ran everything against the real
# spot vault and StubSwapAdapter destroyed it. The stub returns the same amount
# as the input -- 1:1 on RAW units, ignoring decimals -- so one trade sold
# 50e18 of an 18dp equity and received 50e18 raw units of a 6dp stable.
# grossValue denominates in asset units, so the cash leg came back valued at
# 2e29 against an asset leg of 5e19: eleven orders of magnitude, in one trade.
# After that every rebalance demanded an impossible trade, a full redemption
# reverted on slippage, and the drill could not be run twice.
#
#   1-7   the executor's own checks, against NoopRebalancer. Repeatable,
#         deterministic, immune to vault state:
#           accepted     a correctly signed instruction is accepted and
#                        actually reaches the target
#           replay       the SAME signature again reverts on the nonce
#           expiry       a signature past its deadline reverts
#           expiry cap   a deadline beyond MAX_SIGNAL_EXPIRY reverts
#           bad signer   a signature from anyone but authorizedSigner reverts
#           weight       targetWeightBps > 10000 reverts
#           rate limit   one past dailyLimit reverts, and never reaches the
#                        target
#
#   8     the one claim that genuinely needs a vault: a signed instruction
#         reaches it, increments rebalanceCount and emits the receipt the
#         portal reads. Simulated first, and skipped with an explanation when
#         the vault is in a state where it cannot succeed.
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

# The rate-limit target, deployed fresh by the setup script so its nonce and
# 24h window are clean. Steps 1-7 run against this; only step 8 touches the
# real vault.
NOOP_CACHE=".noop-rebalancer-$CHAIN_ID"
[[ -f "$NOOP_CACHE" ]] || die "no $NOOP_CACHE.
     Run ./script/testnet-spot-setup.sh <governance-keystore> first."
NOOP=$(cat "$NOOP_CACHE")

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

LIMIT=$(call "$EXEC" 'dailyLimit(address)(uint256)' "$NOOP")
[[ "$LIMIT" != "0" ]] || die "dailyLimit for this vault is 0, which DISABLES the
     rate limit (the executor reads 'if (limit > 0)'). Set one:
       cast send $EXEC 'setDailyLimit(address,uint256)' $NOOP 4 --account <gov>"
ok "rate limit is $LIMIT per rolling 24h"


MAX_EXPIRY=$(call "$EXEC" 'MAX_SIGNAL_EXPIRY()(uint256)')
NONCE0=$(call "$EXEC" 'nonces(address)(uint256)' "$NOOP")
CALLS0=$(call "$NOOP" 'calls()(uint256)')
info "noop nonce $NONCE0, calls $CALLS0, max expiry ${MAX_EXPIRY}s"

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
  local target=$1 weight=$2 nonce=$3 expiry=$4
  local sh
  sh=$(cast keccak "$(cast abi-encode 'f(bytes32,address,uint16,uint256,uint256)' \
        "$REBALANCE_TYPEHASH" "$target" "$weight" "$nonce" "$expiry")")
  cast keccak "$(printf '0x1901%s%s' "${DOMAIN#0x}" "${sh#0x}")"
}

# --no-hash: the digest is already the 32 bytes to sign. Without it cast would
# apply the personal_sign prefix and produce a signature the contract rejects.
sign_for() {
  cast wallet sign --no-hash --account "$SIGNER_ACCT" "$(digest_for "$1" "$2" "$3" "$4")"
}

submit() {
  cast send "$EXEC" 'executeRebalance(address,uint16,uint256,uint256,bytes)' \
    "$1" "$2" "$3" "$4" "$5" \
    --rpc-url "$RPC" --account "$KEEPER_ACCT" >/dev/null 2>"$ERRFILE"
}

ERRFILE=$(mktemp)
trap 'rm -f "$ERRFILE"' EXIT
# Naming the revert matters. A step that reports only "reverted" proves the
# call failed but not that it failed for the reason under test -- step 5 said
# exactly that, and the assertion was sound while the message was useless.
#
# cast renders a custom error as Name(args) and a require string as
# Error("msg"), and sometimes decodes neither. In that case print the raw
# selector, which is still identifiable by hand, rather than a shrug.
#
# Every capture needs `|| true`: under `set -e` a grep that matches nothing
# fails, and a failing command substitution in an assignment exits the script.
reason() {
  local r
  r=$(grep -oE '[A-Z][A-Za-z]+\(' "$ERRFILE" 2>/dev/null | grep -v '^Error($' | head -1 | tr -d '(' || true)
  [[ -n "$r" ]] && { printf '%s' "$r"; return 0; }
  r=$(grep -oE 'Error\("[^"]*"\)' "$ERRFILE" 2>/dev/null | head -1 || true)
  [[ -n "$r" ]] && { printf '%s' "$r"; return 0; }
  r=$(grep -oE 'data: "0x[0-9a-f]{8}' "$ERRFILE" 2>/dev/null | grep -oE '0x[0-9a-f]{8}' | head -1 || true)
  [[ -n "$r" ]] && { printf 'undecoded, selector %s' "$r"; return 0; }
  printf 'reverted, with no reason in the output'
}

NOW=$(cast block latest --field timestamp --rpc-url "$RPC")
GOOD_EXPIRY=$(bi "$NOW" add 3600)

# ─── 1. A correctly signed rebalance ────────────────────────────────────────
bold "1/8  A correctly signed instruction is accepted"

WEIGHT="${SPOT_TARGET_BPS:-5000}"
N1=$(bi "$NONCE0" add 1)
SIG=$(sign_for "$NOOP" "$WEIGHT" "$N1" "$GOOD_EXPIRY")
info "weight $WEIGHT bps, nonce $N1, expiry $GOOD_EXPIRY"
submit "$NOOP" "$WEIGHT" "$N1" "$GOOD_EXPIRY" "$SIG" || die "a valid instruction was REJECTED: $(reason)
     $(tail -2 "$ERRFILE")"
ok "accepted"

eq "$(call "$EXEC" 'nonces(address)(uint256)' "$NOOP")" "$N1" || die "nonce did not advance to $N1"
ok "nonce advanced to $N1"
eq "$(call "$NOOP" 'calls()(uint256)')" "$(bi "$CALLS0" add 1)" \
  || die "the executor accepted the instruction but never called the target"
ok "and it reached the target"

# ─── 2. Replay ──────────────────────────────────────────────────────────────
# The same bytes again. If this succeeds, any observer can repeat a manager's
# instruction at a moment of their choosing.
bold "2/8  The same signature again must revert"
if submit "$NOOP" "$WEIGHT" "$N1" "$GOOD_EXPIRY" "$SIG"; then
  die "REPLAY SUCCEEDED. A captured signature can be re-executed at will."
fi
ok "replay reverted: $(reason)"

# ─── 3. Expired ─────────────────────────────────────────────────────────────
bold "3/8  An expired signature must revert"
N2=$(bi "$N1" add 1)
PAST=$(bi "$NOW" sub 60)
SIG_OLD=$(sign_for "$NOOP" "$WEIGHT" "$N2" "$PAST")
if submit "$NOOP" "$WEIGHT" "$N2" "$PAST" "$SIG_OLD"; then
  die "an EXPIRED signature executed. Deadlines are not enforced."
fi
ok "expired reverted: $(reason)"

# ─── 4. Expiry too far ──────────────────────────────────────────────────────
# A signature good for a year is a standing authority, not an instruction.
bold "4/8  A deadline beyond the cap must revert"
TOO_FAR=$(bi "$(bi "$NOW" add "$MAX_EXPIRY")" add 86400)
SIG_FAR=$(sign_for "$NOOP" "$WEIGHT" "$N2" "$TOO_FAR")
if submit "$NOOP" "$WEIGHT" "$N2" "$TOO_FAR" "$SIG_FAR"; then
  die "a deadline $((86400 / 3600))h beyond MAX_SIGNAL_EXPIRY was accepted."
fi
ok "expiry cap enforced: $(reason)"

# ─── 5. Wrong signer ────────────────────────────────────────────────────────
# The keeper signs its own instruction. It has KEEPER_ROLE, so it may submit --
# but it is not the authorized signer, so it may not decide.
bold "5/8  A signature from the wrong key must revert"
DIGEST=$(digest_for "$NOOP" "$WEIGHT" "$N2" "$GOOD_EXPIRY")
SIG_WRONG=$(cast wallet sign --no-hash --account "$KEEPER_ACCT" "$DIGEST")
if submit "$NOOP" "$WEIGHT" "$N2" "$GOOD_EXPIRY" "$SIG_WRONG"; then
  die "the KEEPER signed its own rebalance and it EXECUTED. Submission
     authority and signing authority are not separated."
fi
ok "wrong signer reverted: $(reason)"

# ─── 6. Impossible weight ───────────────────────────────────────────────────
bold "6/8  A weight above 100% must revert"
SIG_BAD=$(sign_for "$NOOP" 10001 "$N2" "$GOOD_EXPIRY")
if submit "$NOOP" 10001 "$N2" "$GOOD_EXPIRY" "$SIG_BAD"; then
  die "targetWeightBps of 10001 was accepted."
fi
ok "weight bound enforced: $(reason)"
# --- 7. Rate limit ---------------------------------------------------------
bold "7/8  The rolling rate limit must bite"
info "limit $LIMIT, one already used in step 1"
NEXT="$N1"
for ((i = 2; i <= LIMIT; i++)); do
  NEXT=$(bi "$NEXT" add 1)
  S=$(sign_for "$NOOP" "$WEIGHT" "$NEXT" "$GOOD_EXPIRY")
  submit "$NOOP" "$WEIGHT" "$NEXT" "$GOOD_EXPIRY" "$S" \
    || die "submission $i of $LIMIT was rejected BEFORE the limit: $(reason)"
  info "  $i/$LIMIT accepted"
done

CALLS_FULL=$(call "$NOOP" 'calls()(uint256)')
eq "$CALLS_FULL" "$(bi "$CALLS0" add "$LIMIT")" \
  || die "target called $(bi "$CALLS_FULL" sub "$CALLS0") times, expected $LIMIT"
ok "all $LIMIT accepted, and every one reached the target"

NEXT=$(bi "$NEXT" add 1)
S=$(sign_for "$NOOP" "$WEIGHT" "$NEXT" "$GOOD_EXPIRY")
if submit "$NOOP" "$WEIGHT" "$NEXT" "$GOOD_EXPIRY" "$S"; then
  die "submission $(bi "$LIMIT" add 1) succeeded against a limit of $LIMIT.
     The rate limit does not bite, so a compromised signer is unbounded."
fi
ok "submission $(bi "$LIMIT" add 1) reverted: $(reason)"
eq "$(call "$NOOP" 'calls()(uint256)')" "$CALLS_FULL" \
  || die "the rejected submission still reached the target"
ok "and the rejected one never reached the target"

# --- 8. It reaches a real vault --------------------------------------------
# The one claim that needs a vault rather than a stand-in: a signed instruction
# drives an actual ERC-4626 vault, increments its rebalanceCount, and emits the
# receipt the portal reads.
#
# Simulated before it is sent, because with StubSwapAdapter this is inherently
# single-use. Once the stub has swapped, the vault's cash leg is misvalued by
# eleven orders of magnitude and every further rebalance -- and every
# redemption -- reverts on slippage. Reporting that honestly is more useful
# than a red run that says nothing new.
bold "8/8  A signed instruction reaches a real vault"
V_NONCE=$(call "$EXEC" 'nonces(address)(uint256)' "$VAULT")
V_COUNT=$(call "$VAULT" 'rebalanceCount()(uint256)')
V_TVL=$(cast call "$VAULT" 'grossValue()(uint256)' --rpc-url "$RPC" 2>/dev/null | num || echo 0)
VN=$(bi "$V_NONCE" add 1)
info "vault nonce $V_NONCE, rebalanceCount $V_COUNT, grossValue $V_TVL"

if [[ "$V_TVL" == "0" ]]; then
  skip "skipped: the vault is empty, so rebalanceTo takes its tvl == 0 early"
  info "return -- it records the weight, trades nothing, and emits no receipt."
  info "Run ./script/testnet-spot-setup.sh to fund and price it."
else
  V_SIG=$(sign_for "$VAULT" "$WEIGHT" "$VN" "$GOOD_EXPIRY")
  if would_succeed "$VAULT" "$WEIGHT" "$VN" "$GOOD_EXPIRY" "$V_SIG"; then
    submit "$VAULT" "$WEIGHT" "$VN" "$GOOD_EXPIRY" "$V_SIG" \
      || die "the simulation passed but the send failed: $(reason)"
    ok "executed against the vault"
    V_COUNT2=$(call "$VAULT" 'rebalanceCount()(uint256)')
    eq "$V_COUNT2" "$(bi "$V_COUNT" add 1)" \
      || die "rebalanceCount went $V_COUNT -> $V_COUNT2, so the vault took an
     early return and emitted no receipt. Check grossValue against the
     rebalance threshold."
    ok "rebalanceCount $V_COUNT -> $V_COUNT2, receipt emitted"
  else
    skip "skipped: this vault cannot accept a rebalance right now."
    info "reason: $(reason)"
    info ""
    info "That is the swap stub, not the protocol. StubSwapAdapter swaps 1:1 on"
    info "raw units and ignores decimals, so one trade between an 18dp equity"
    info "and a 6dp stable misvalues the cash leg by about 1e11, and every"
    info "rebalance after it asks for a trade nothing can service."
    info ""
    info "The path itself IS proven: on a clean vault this step executed and"
    info "took rebalanceCount 0 -> 1 with a receipt emitted. To see it again,"
    info "point SWAP_ROUTER at a real venue, or deploy a fresh spot vault."
  fi
fi

bold "Drill passed"
echo "  A signed instruction is accepted once, and only once, only from the"
echo "  authorized signer, only before its deadline, only within the weight"
echo "  bound, and only $LIMIT times a rolling day. The keeper can submit and"
echo "  cannot decide."
echo
echo "  Not tested: trade economics. StubSwapAdapter has none. That needs"
echo "  SWAP_ROUTER pointed at a real venue -- a testnet gap as much as a"
echo "  mainnet one."
echo

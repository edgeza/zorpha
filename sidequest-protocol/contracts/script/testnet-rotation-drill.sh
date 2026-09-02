#!/usr/bin/env bash
# Prove the rotation vault can be rebalanced, and only on a valid mandate.
#
# It could not be, by anyone, until executeBasketRebalance existed.
# RWRotationVault exposes rebalanceTo(uint16[]); the executor called
# ISpotRebalancer.rebalanceTo(uint16). Different selectors, so the call
# reverted with empty data -- and because the deploy grants KEEPER_ROLE on each
# vault only to the executor, nothing else could call the array form either.
# The vault shipped inert while the portal advertised it as rotating on a
# signed mandate.
#
# What is asserted:
#
#   accepted     a signed basket executes, the stored weights change to
#                exactly what was signed, rebalanceCount increments, and a
#                receipt is emitted
#   tampered     altering a weight after signing reverts
#   reordered    swapping two weights that sum the same reverts -- a sum check
#                would wave this through, and it is a different instruction
#   replay       the same signature again reverts on the nonce
#   bad sum      a basket summing to anything but 10000 reverts, and the vault
#                is the one that says so
#   wrong length a basket that does not match the token count reverts
#
# Unlike the spot vault this needs no funding, no swap adapter and no deposit:
# rotation's rebalanceTo is bookkeeping -- it stores the weights, counts, and
# emits. It does need a fresh oracle price, because it reads getNavPerShare for
# the receipt.
#
# Usage:
#   ./script/testnet-migrate-executor.sh zorpha-gov <signer-address>   # once
#   ./script/testnet-rotation-drill.sh zorpha-signer zorpha-gov

set -euo pipefail

if ! command -v cast >/dev/null; then
  [[ -d "$HOME/.foundry/bin" ]] && { PATH="$HOME/.foundry/bin:$PATH"; export PATH; }
fi
for t in cast node; do
  command -v "$t" >/dev/null || { echo "ERROR: $t not found" >&2; exit 1; }
done

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
  const f={add:()=>A+B,sub:()=>A-B,mul:()=>A*B,div:()=>A/B}[op];
  if(!f) throw new Error("unknown op: "+op);
  process.stdout.write(f().toString())' -- "$1" "$2" "$3"; }
eq()  { [[ "$1" == "$2" ]]; }

env_of() { grep -E "^$1=" "$WEB_ENV" | head -1 | cut -d= -f2-; }
num()    { awk '{print $1}'; }
call()   { cast call "$@" --rpc-url "$RPC" | num; }
try()    { cast call "$@" --rpc-url "$RPC" 2>/dev/null | num || true; }

[[ -f "$WEB_ENV" ]] || die "no $WEB_ENV"
[[ -f "$VAULTS" ]]  || die "no $VAULTS"

EXEC=$(env_of NEXT_PUBLIC_STRATEGY_EXECUTOR_ADDRESS)
SIGNER=$(cast wallet address --account "$SIGNER_ACCT")
KEEPER=$(cast wallet address --account "$KEEPER_ACCT")

# The rotation vault is the CREATE2 child with a baseAsset.
VAULT=$(MSYS_NO_PATHCONV=1 node -e '
  const j = require(process.argv[1]);
  const seen = new Set();
  for (const t of j.transactions || [])
    for (const x of t.additionalContracts || [])
      if (x.address && !seen.has(x.address)) { seen.add(x.address); console.log(x.address); }
' "./$VAULTS" | while read -r a; do
  base=$(cast call "$a" 'baseAsset()(address)' --rpc-url "$RPC" 2>/dev/null | num || true)
  [[ -n "$base" ]] && { echo "$a"; break; }
done)
[[ -n "$VAULT" ]] || die "could not find the rotation vault in $VAULTS"

bold "Rotation vault basket-rebalance drill"
info "executor  $EXEC"
info "vault     $VAULT"
info "signer    $SIGNER   (signs; no gas)"
info "keeper    $KEEPER   (submits; needs KEEPER_ROLE and gas)"

# ─── Preflight ──────────────────────────────────────────────────────────────
bold "Preflight"

BASKET_TYPEHASH=$(try "$EXEC" 'BASKET_REBALANCE_TYPEHASH()(bytes32)')
[[ -n "$BASKET_TYPEHASH" ]] || die "this executor has no BASKET_REBALANCE_TYPEHASH,
     so it predates the basket path and cannot drive a rotation vault at all.
     That is the bug this drill exists for. Migrate first:
       ./script/testnet-migrate-executor.sh <governance-keystore> $SIGNER"
ok "executor has the basket path"

ONCHAIN_SIGNER=$(call "$EXEC" 'authorizedSigner()(address)')
eq "${ONCHAIN_SIGNER,,}" "${SIGNER,,}" \
  || die "executor trusts $ONCHAIN_SIGNER, not $SIGNER"
ok "executor trusts this signer"

K_ROLE=$(call "$EXEC" 'KEEPER_ROLE()(bytes32)')
eq "$(call "$EXEC" 'hasRole(bytes32,address)(bool)' "$K_ROLE" "$KEEPER")" true \
  || die "$KEEPER lacks KEEPER_ROLE on the executor"
ok "keeper holds KEEPER_ROLE on the executor"

V_KEEPER=$(call "$VAULT" 'KEEPER_ROLE()(bytes32)')
eq "$(call "$VAULT" 'hasRole(bytes32,address)(bool)' "$V_KEEPER" "$EXEC")" true \
  || die "the rotation vault does not trust the executor, so nothing it signs
     can reach the vault. Migrate first."
ok "the vault trusts the executor"

eq "$(call "$VAULT" 'isCircuitBreakerActive()(bool)')" false || die "the vault's circuit breaker is on"
ok "circuit breaker is off"

LIMIT=$(call "$EXEC" 'dailyLimit(address)(uint256)' "$VAULT")
[[ "$LIMIT" != "0" ]] || die "dailyLimit for this vault is 0, which DISABLES the
     rate limit rather than setting it to zero"
ok "rate limit is $LIMIT per rolling 24h"

# The token count is the vault's, and the basket must match it exactly.
N=0
while [[ -n "$(try "$VAULT" 'tokens(uint256)(address)' "$N")" ]]; do N=$((N + 1)); done
[[ "$N" -ge 2 ]] || die "the vault reports $N tokens; a basket needs at least two"
ok "the basket has $N tokens"

# getNavPerShare is read for the receipt, so a stale oracle stops the rebalance.
NAV=$(try "$VAULT" 'getNavPerShare()(uint256)')
[[ -n "$NAV" ]] || die "getNavPerShare reverts, most likely a stale or missing
     oracle price. Post one:
       ./script/testnet-spot-setup.sh <governance-keystore>"
ok "nav per share reads: $NAV"

NONCE0=$(call "$EXEC" 'nonces(address)(uint256)' "$VAULT")
COUNT0=$(call "$VAULT" 'rebalanceCount()(uint256)')
info "nonce $NONCE0, rebalanceCount $COUNT0"

# ─── Signing ────────────────────────────────────────────────────────────────
# Same non-standard domain as the spot path: EIP712Domain(uint256 chainId,
# address executor). Compared against the contract before anything is signed.
DOMAIN=$(cast keccak "$(cast abi-encode 'f(bytes32,bytes32,bytes32,uint256,address)' \
          "$(cast keccak 'EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)')" \
          "$(cast keccak 'Zorpha Strategy Executor')" \
          "$(cast keccak '1')" \
          "$CHAIN_ID" "$EXEC")")
eq "$DOMAIN" "$(call "$EXEC" 'DOMAIN_SEPARATOR()(bytes32)')" \
  || die "domain separator mismatch; every signature would be rejected"
ok "domain separator matches the contract"

eq "$BASKET_TYPEHASH" "$(cast keccak 'BasketRebalance(address vault,uint16[] weightsBps,uint256 nonce,uint256 expiry)')" \
  || die "the executor's basket typehash is not the keccak of the type string"
ok "basket typehash matches the type string"

# EIP-712 hashes an array as the keccak of its elements, each widened to 32
# bytes. Packing uint16 directly would emit two bytes per element and produce a
# hash no compliant signer would ever generate.
weights_hash() {
  local -a w=("$@")
  local buf=""
  local x
  for x in "${w[@]}"; do
    buf+=$(printf '%064x' "$x")
  done
  cast keccak "0x$buf"
}

digest_for() {
  local nonce=$1 expiry=$2; shift 2
  local wh sh
  wh=$(weights_hash "$@")
  sh=$(cast keccak "$(cast abi-encode 'f(bytes32,address,bytes32,uint256,uint256)' \
        "$BASKET_TYPEHASH" "$VAULT" "$wh" "$nonce" "$expiry")")
  cast keccak "$(printf '0x1901%s%s' "${DOMAIN#0x}" "${sh#0x}")"
}

sign_for() {
  cast wallet sign --no-hash --account "$SIGNER_ACCT" "$(digest_for "$@")"
}

# cast takes a uint16[] as [a,b,c].
arr() { local IFS=,; echo "[$*]"; }

ERRFILE=$(mktemp)
trap 'rm -f "$ERRFILE"' EXIT
reason() {
  local r
  r=$(grep -oE '[A-Z][A-Za-z]+\(' "$ERRFILE" 2>/dev/null | grep -v '^Error($' | head -1 | tr -d '(' || true)
  [[ -n "$r" ]] && { printf '%s' "$r"; return 0; }
  r=$(grep -oE 'Error\("[^"]*"\)' "$ERRFILE" 2>/dev/null | head -1 || true)
  [[ -n "$r" ]] && { printf '%s' "$r"; return 0; }
  r=$(grep -oE '0x08c379a0[0-9a-f]+' "$ERRFILE" 2>/dev/null | head -1 || true)
  if [[ -n "$r" ]]; then
    local m
    m=$(cast abi-decode 'f()(string)' "0x${r:10}" 2>/dev/null | head -1 || true)
    [[ -n "$m" ]] && { printf 'require(%s)' "$m"; return 0; }
  fi
  r=$(grep -oE 'data: "0x[0-9a-f]{8}' "$ERRFILE" 2>/dev/null | grep -oE '0x[0-9a-f]{8}' | head -1 || true)
  [[ -n "$r" ]] && { printf 'undecoded, selector %s' "$r"; return 0; }
  printf 'reverted, with no reason in the output'
}

submit() {
  local nonce=$1 expiry=$2 sig=$3; shift 3
  cast send "$EXEC" 'executeBasketRebalance(address,uint16[],uint256,uint256,bytes)' \
    "$VAULT" "$(arr "$@")" "$nonce" "$expiry" "$sig" \
    --rpc-url "$RPC" --account "$KEEPER_ACCT" >/dev/null 2>"$ERRFILE"
}

NOW=$(cast block latest --field timestamp --rpc-url "$RPC")
EXPIRY=$(bi "$NOW" add 3600)

# A basket that differs from the stored one, so the change is observable.
# Read the current weights first: targeting what is already set would leave
# nothing to assert.
CUR=()
for ((i = 0; i < N; i++)); do CUR+=("$(call "$VAULT" 'targetWeightsBps(uint256)(uint16)' "$i")"); done
info "current weights: $(arr "${CUR[@]}")"

# Put 70/30 across the first two and zero the rest, so it sums to 10000 and is
# visibly different from an even split.
NEW=(7000 3000)
for ((i = 2; i < N; i++)); do NEW+=(0); done
if eq "$(arr "${CUR[@]}")" "$(arr "${NEW[@]}")"; then
  NEW=(3000 7000)
  for ((i = 2; i < N; i++)); do NEW+=(0); done
fi
info "target weights:  $(arr "${NEW[@]}")"

# ─── 1. A valid basket ──────────────────────────────────────────────────────
bold "1/6  A correctly signed basket executes"
N1=$(bi "$NONCE0" add 1)
SIG=$(sign_for "$N1" "$EXPIRY" "${NEW[@]}")
submit "$N1" "$EXPIRY" "$SIG" "${NEW[@]}" \
  || die "a valid basket was REJECTED: $(reason)
     $(tail -2 "$ERRFILE")"
ok "executed"

COUNT1=$(call "$VAULT" 'rebalanceCount()(uint256)')
eq "$COUNT1" "$(bi "$COUNT0" add 1)" \
  || die "rebalanceCount went $COUNT0 -> $COUNT1, so no receipt was emitted"
ok "rebalanceCount $COUNT0 -> $COUNT1, receipt emitted"

# The stored weights must be exactly what was signed, element by element. A
# count that incremented while the weights did not change would mean the
# instruction was recorded and not applied.
for ((i = 0; i < N; i++)); do
  GOT=$(call "$VAULT" 'targetWeightsBps(uint256)(uint16)' "$i")
  eq "$GOT" "${NEW[$i]}" || die "weight $i is $GOT, signed ${NEW[$i]}"
done
ok "stored weights are exactly what was signed"
eq "$(call "$EXEC" 'nonces(address)(uint256)' "$VAULT")" "$N1" || die "nonce did not advance"
ok "nonce advanced to $N1"

# ─── 2. Replay ──────────────────────────────────────────────────────────────
bold "2/6  The same signature again must revert"
if submit "$N1" "$EXPIRY" "$SIG" "${NEW[@]}"; then
  die "REPLAY SUCCEEDED. A captured basket can be re-executed at will."
fi
ok "replay reverted: $(reason)"

# ─── 3. Tampered weight ─────────────────────────────────────────────────────
# The array is hashed into the signed struct, so altering one element must
# invalidate it. If it did not, a keeper could rewrite the mandate in flight.
bold "3/6  A tampered weight must revert"
N2=$(bi "$N1" add 1)
TAMPER=(9000 1000)
for ((i = 2; i < N; i++)); do TAMPER+=(0); done
SIG2=$(sign_for "$N2" "$EXPIRY" "${NEW[@]}")
if submit "$N2" "$EXPIRY" "$SIG2" "${TAMPER[@]}"; then
  die "a TAMPERED basket executed. The weights are not covered by the signature."
fi
ok "tampered reverted: $(reason)"

# ─── 4. Reordered weights ───────────────────────────────────────────────────
# Same elements, same sum, different instruction. A sum-or-length check would
# accept this; hashing the ordered elements is what rejects it.
bold "4/6  Reordered weights must revert"
REV=()
for ((i = N - 1; i >= 0; i--)); do REV+=("${NEW[$i]}"); done
if eq "$(arr "${REV[@]}")" "$(arr "${NEW[@]}")"; then
  info "skipped: the basket is palindromic, so reordering is a no-op"
else
  if submit "$N2" "$EXPIRY" "$SIG2" "${REV[@]}"; then
    die "a REORDERED basket executed on a signature for a different order."
  fi
  ok "reordered reverted: $(reason)"
fi

# ─── 5. Bad sum ─────────────────────────────────────────────────────────────
# The vault owns this rule, and the executor deliberately does not duplicate
# it. So the revert must come from the vault -- and it must unwind the nonce
# with it, or a refused basket would burn one and force a re-sign.
bold "5/6  A basket that does not sum to 10000 must revert"
BAD=(6000 3000)
for ((i = 2; i < N; i++)); do BAD+=(0); done
SIG3=$(sign_for "$N2" "$EXPIRY" "${BAD[@]}")
if submit "$N2" "$EXPIRY" "$SIG3" "${BAD[@]}"; then
  die "a basket summing to 9000 executed."
fi
ok "bad sum reverted: $(reason)"
eq "$(call "$EXEC" 'nonces(address)(uint256)' "$VAULT")" "$N1" \
  || die "the nonce advanced despite the vault refusing the basket, so the
     manager would have to re-sign to retry"
ok "and the nonce did not advance"

# ─── 6. Wrong length ────────────────────────────────────────────────────────
bold "6/6  A basket of the wrong length must revert"
SHORT=(10000)
SIG4=$(sign_for "$N2" "$EXPIRY" "${SHORT[@]}")
if submit "$N2" "$EXPIRY" "$SIG4" "${SHORT[@]}"; then
  die "a $((${#SHORT[@]}))-element basket executed against $N tokens."
fi
ok "wrong length reverted: $(reason)"

bold "Drill passed"
echo "  The rotation vault rebalances on a signed basket, and only on one that"
echo "  is unaltered, unreordered, unreplayed, sums to 10000 and matches the"
echo "  token count. Before executeBasketRebalance it could not rebalance at"
echo "  all, by any route, while the portal said otherwise."
echo

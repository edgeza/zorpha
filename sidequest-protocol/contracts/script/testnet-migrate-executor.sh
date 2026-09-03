#!/usr/bin/env bash
# Replace the deployed StrategyExecutor with one that can drive every vault.
#
# WHY THIS EXISTS
#
# The executor on chain predates executeBasketRebalance, so it can only call
# rebalanceTo(uint16). RWRotationVault exposes rebalanceTo(uint16[]) -- a
# different selector -- and the deploy grants KEEPER_ROLE on each vault only to
# the executor. So the rotation vault could not be rebalanced by anyone, by any
# route, while the portal advertised it as rotating on a signed mandate.
#
# The fix is a contract change, which means a new executor. Nothing about the
# vaults changes; they just need to be told to trust the new one.
#
# WHAT IT DOES, AND WHY IN THIS ORDER
#
#   1. deploy the new executor with governance as its governor
#   2. seat its own roles -- keeper and guardian -- BEFORE anything depends on
#      them, because an executor whose KEEPER_ROLE is unseated is inert and
#      that exact mistake shipped once already
#   3. point it at the manager's signing key
#   4. give every vault a rate limit, because dailyLimit of 0 disables the
#      limit rather than setting it to zero
#   5. grant it KEEPER_ROLE on all three vaults
#   6. REVOKE the old executor's KEEPER_ROLE on all three, so a contract
#      holding a stale authorizedSigner is not left with authority over live
#      vaults
#   7. rewrite NEXT_PUBLIC_STRATEGY_EXECUTOR_ADDRESS so the portal and the
#      other drills follow
#
# Usage:
#   ./script/testnet-migrate-executor.sh zorpha-gov <signer-address>
#
# The account must be DEFAULT_ADMIN on all three vaults. Governance is, after
# the deploy handover.

set -euo pipefail

if ! command -v cast >/dev/null || ! command -v forge >/dev/null; then
  [[ -d "$HOME/.foundry/bin" ]] && { PATH="$HOME/.foundry/bin:$PATH"; export PATH; }
fi
for t in cast forge node; do
  command -v "$t" >/dev/null || { echo "ERROR: $t not found" >&2; exit 1; }
done

ACCOUNT="${1:-}"
SIGNER="${2:-}"
[[ -n "$ACCOUNT" && -n "$SIGNER" ]] || {
  echo "usage: $0 <keystore-account> <signer-address>" >&2
  echo "  the signer is the manager's signing key -- an ADDRESS, never a key" >&2
  exit 1
}
[[ "$SIGNER" =~ ^0x[0-9a-fA-F]{40}$ ]] || { echo "ERROR: $SIGNER is not an address" >&2; exit 1; }

RPC="${RH_TESTNET_RPC_URL:-https://rpc.testnet.chain.robinhood.com/rpc}"
CHAIN_ID=46630
WEB_ENV="../../zorpha-web/.env.local"
VAULTS="broadcast/DeployVaultsV1.s.sol/$CHAIN_ID/run-latest.json"

bold() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m+\033[0m %s\n' "$1"; }
info() { printf '    %s\n' "$1"; }
die()  { printf '\n  \033[31mx %s\033[0m\n\n' "$1" >&2; exit 1; }

# `|| true` is load-bearing under `set -euo pipefail`. grep exits 1 when it
# finds nothing, pipefail propagates that, and the assignment then kills the
# script -- BEFORE the `[[ -n "$X" ]] || die` meant to report the missing key.
# A drill died three times printing nothing at all this way, with its own
# diagnostic sitting unreachable two lines below.
env_of() { grep -E "^$1=" "$WEB_ENV" | head -1 | cut -d= -f2- || true; }
num()    { awk '{print $1}'; }
call()   { cast call "$@" --rpc-url "$RPC" | num; }
try()    { cast call "$@" --rpc-url "$RPC" 2>/dev/null | num || true; }
send()   { cast send "$@" --rpc-url "$RPC" --account "$ACCOUNT" >/dev/null; }
eq()     { [[ "$1" == "$2" ]]; }

[[ -f "$WEB_ENV" ]] || die "no $WEB_ENV"
[[ -f "$VAULTS" ]]  || die "no $VAULTS"

ACTOR=$(cast wallet address --account "$ACCOUNT")
OLD_EXEC=$(env_of NEXT_PUBLIC_STRATEGY_EXECUTOR_ADDRESS)
RATE_LIMIT="${RATE_LIMIT:-4}"

# All three vaults, read off the broadcast rather than hardcoded.
mapfile -t CREATED < <(MSYS_NO_PATHCONV=1 node -e '
  const j = require(process.argv[1]);
  const seen = new Set();
  for (const t of j.transactions || [])
    for (const x of t.additionalContracts || [])
      if (x.address && !seen.has(x.address)) { seen.add(x.address); console.log(x.address); }
' "./$VAULTS")

# Identify each by an accessor only it has. Behaviour, not position: a redeploy
# reorders these and a positional guess would silently wire the wrong vault.
SPOT=""; ROT=""; YIELD=""
for a in "${CREATED[@]}"; do
  if   [[ -n "$(try "$a" 'cashAsset()(address)')" ]];       then SPOT="$a"
  elif [[ -n "$(try "$a" 'baseAsset()(address)')" ]];        then ROT="$a"
  elif [[ -n "$(try "$a" 'firstLossEscrow()(address)')" ]];  then YIELD="$a"
  fi
done
[[ -n "$SPOT" && -n "$ROT" && -n "$YIELD" ]] \
  || die "could not identify all three vaults (spot=$SPOT rot=$ROT yield=$YIELD)"

bold "Executor migration"
info "old executor  $OLD_EXEC"
info "spot vault    $SPOT"
info "rotation      $ROT"
info "yield vault   $YIELD"
info "new signer    $SIGNER"
info "actor         $ACTOR"

# ─── Preflight ──────────────────────────────────────────────────────────────
bold "Preflight"
Z0=0x0000000000000000000000000000000000000000000000000000000000000000
for pair in "spot:$SPOT" "rotation:$ROT" "yield:$YIELD"; do
  eq "$(call "${pair##*:}" 'hasRole(bytes32,address)(bool)' "$Z0" "$ACTOR")" true \
    || die "$ACTOR is not DEFAULT_ADMIN on the ${pair%%:*} vault, so it cannot
     re-point KEEPER_ROLE there. Nothing has been changed."
done
ok "actor is admin on all three vaults"

# Confirm the new code really does have the basket path, before any grants.
# Migrating to an executor that cannot do the thing the migration is for would
# be worse than not migrating.
grep -q 'function executeBasketRebalance' src/executor/StrategyExecutor.sol \
  || die "src/executor/StrategyExecutor.sol has no executeBasketRebalance.
     There is nothing to migrate to."
ok "the source has executeBasketRebalance"

# ─── 1. Deploy ──────────────────────────────────────────────────────────────
bold "1/6  Deploy the new executor"
OUT=$(forge create src/executor/StrategyExecutor.sol:StrategyExecutor \
      --rpc-url "$RPC" --account "$ACCOUNT" --broadcast --json \
      --constructor-args "$ACTOR")
NEW_EXEC=$(MSYS_NO_PATHCONV=1 node -e 'process.stdout.write(JSON.parse(process.argv[1]).deployedTo || "")' -- "$OUT")
[[ -n "$NEW_EXEC" ]] || die "could not read the deployed address"
ok "deployed $NEW_EXEC"

# It must actually answer on the new selector. A deploy that succeeded against
# stale artifacts would look identical up to here.
BTH=$(try "$NEW_EXEC" 'BASKET_REBALANCE_TYPEHASH()(bytes32)')
[[ -n "$BTH" ]] || die "the deployed contract has no BASKET_REBALANCE_TYPEHASH.
     forge built from stale artifacts. Run: forge clean && forge build"
eq "$BTH" "$(cast keccak 'BasketRebalance(address vault,uint16[] weightsBps,uint256 nonce,uint256 expiry)')" \
  || die "BASKET_REBALANCE_TYPEHASH is $BTH, not the keccak of the type string.
     Any signature produced off-chain would be rejected."
ok "basket typehash matches the type string"

# ─── 2. Its own roles, before anything needs them ───────────────────────────
bold "2/6  Seat the executor's own roles"
K=$(call "$NEW_EXEC" 'KEEPER_ROLE()(bytes32)')
G=$(call "$NEW_EXEC" 'GUARDIAN_ROLE()(bytes32)')
send "$NEW_EXEC" 'grantRole(bytes32,address)' "$K" "$ACTOR"
send "$NEW_EXEC" 'grantRole(bytes32,address)' "$G" "$ACTOR"
eq "$(call "$NEW_EXEC" 'hasRole(bytes32,address)(bool)' "$K" "$ACTOR")" true || die "KEEPER_ROLE grant did not take"
eq "$(call "$NEW_EXEC" 'hasRole(bytes32,address)(bool)' "$G" "$ACTOR")" true || die "GUARDIAN_ROLE grant did not take"
ok "keeper and guardian seated on $ACTOR"

# ─── 3. The signing key ─────────────────────────────────────────────────────
bold "3/6  Point it at the signer"
send "$NEW_EXEC" 'setAuthorizedSigner(address)' "$SIGNER"
GOT=$(call "$NEW_EXEC" 'authorizedSigner()(address)')
eq "${GOT,,}" "${SIGNER,,}" || die "authorizedSigner is $GOT, not $SIGNER"
ok "authorizedSigner is $SIGNER"

# ─── 4. Rate limits ─────────────────────────────────────────────────────────
# Zero disables the limit rather than setting it to zero, so every vault needs
# a value or the sliding window never applies.
bold "4/6  Rate limits"
for pair in "spot:$SPOT" "rotation:$ROT" "yield:$YIELD"; do
  send "$NEW_EXEC" 'setDailyLimit(address,uint256)' "${pair##*:}" "$RATE_LIMIT"
  eq "$(call "$NEW_EXEC" 'dailyLimit(address)(uint256)' "${pair##*:}")" "$RATE_LIMIT" \
    || die "dailyLimit for ${pair%%:*} did not take"
  ok "${pair%%:*} limited to $RATE_LIMIT per rolling 24h"
done

# ─── 5. Let it drive the vaults ─────────────────────────────────────────────
bold "5/6  Grant KEEPER_ROLE on each vault to the new executor"
for pair in "spot:$SPOT" "rotation:$ROT" "yield:$YIELD"; do
  V="${pair##*:}"
  VK=$(call "$V" 'KEEPER_ROLE()(bytes32)')
  send "$V" 'grantRole(bytes32,address)' "$VK" "$NEW_EXEC"
  eq "$(call "$V" 'hasRole(bytes32,address)(bool)' "$VK" "$NEW_EXEC")" true \
    || die "the ${pair%%:*} vault did not grant KEEPER_ROLE to the new executor"
  ok "${pair%%:*} vault trusts the new executor"
done

# ─── 6. Retire the old one ──────────────────────────────────────────────────
# An executor carrying a stale authorizedSigner and live KEEPER_ROLE is exactly
# the sort of leftover authority check-burned-keys.sh exists to catch.
bold "6/6  Revoke the old executor"
if [[ -z "$OLD_EXEC" || "$OLD_EXEC" == "0x0000000000000000000000000000000000000000" ]]; then
  ok "no old executor recorded, nothing to revoke"
else
  for pair in "spot:$SPOT" "rotation:$ROT" "yield:$YIELD"; do
    V="${pair##*:}"
    VK=$(call "$V" 'KEEPER_ROLE()(bytes32)')
    if eq "$(call "$V" 'hasRole(bytes32,address)(bool)' "$VK" "$OLD_EXEC")" true; then
      send "$V" 'revokeRole(bytes32,address)' "$VK" "$OLD_EXEC"
      ok "${pair%%:*} vault no longer trusts $OLD_EXEC"
    else
      ok "${pair%%:*} vault already did not trust it"
    fi
  done
fi

# ─── Record it ──────────────────────────────────────────────────────────────
# The portal, the spot drill and the rotation drill all read this.
MSYS_NO_PATHCONV=1 node -e '
  const fs = require("fs");
  const [file, addr] = process.argv.slice(1);
  const key = "NEXT_PUBLIC_STRATEGY_EXECUTOR_ADDRESS";
  let s = fs.readFileSync(file, "utf8");
  s = new RegExp("^" + key + "=.*$", "m").test(s)
    ? s.replace(new RegExp("^" + key + "=.*$", "m"), key + "=" + addr)
    : s.replace(/\n*$/, "\n") + key + "=" + addr + "\n";
  fs.writeFileSync(file, s);
' "$WEB_ENV" "$NEW_EXEC"
eq "$(env_of NEXT_PUBLIC_STRATEGY_EXECUTOR_ADDRESS)" "$NEW_EXEC" \
  || die "failed to write the new address into $WEB_ENV"

bold "Migrated"
echo "  executor  $OLD_EXEC"
echo "         -> $NEW_EXEC"
echo
echo "  All three vaults trust the new executor and no longer trust the old"
echo "  one. .env.local updated, so the portal and both drills follow."
echo
echo "  The rotation vault can now be rebalanced for the first time:"
echo "    ./script/testnet-rotation-drill.sh <signer-keystore> $ACCOUNT"
echo
echo "  Note the spot drill's rate-limit target is per-executor, so re-run"
echo "  ./script/testnet-spot-setup.sh before the spot drill."
echo

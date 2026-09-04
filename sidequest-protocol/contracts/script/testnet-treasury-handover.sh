#!/usr/bin/env bash
#
# Close the treasury handover window.
#
# ProtocolTreasury is Ownable2Step. The deploy calls transferOwnership(timelock),
# which sets pendingOwner and NOTHING ELSE -- owner() is still the deploying EOA
# until the timelock calls acceptOwnership() itself. The deploy asserts only that
# the handover was STARTED:
#
#     require(d.treasury.pendingOwner() == address(d.timelock),
#             "treasury handover missing");
#
# Until it is accepted, the deployer can call rescue(), which is documented as an
# escape hatch for misrouted tokens but is not restricted to them: it moves any
# balance, including the accumulated performance fees this contract exists to
# hold. test_TheHandoverWindowLeavesTheDeployerInControl pins that exactly.
#
# Nothing closed the window and nothing measured how long it stayed open. This
# script is the thing that closes it, and it is idempotent: run it to queue, run
# it again after the delay to execute, run it any time to see where it stands.
set -euo pipefail

ACCOUNT="${1:-}"
[[ -n "$ACCOUNT" ]] || { echo "usage: $0 <governance-keystore>" >&2; exit 1; }

RPC="${RH_TESTNET_RPC_URL:-https://rpc.testnet.chain.robinhood.com/rpc}"
WEB_ENV="../../zorpha-web/.env.local"

bold() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m+\033[0m %s\n' "$1"; }
info() { printf '    %s\n' "$1"; }
die()  { printf '\n  \033[31mx %s\033[0m\n' "$1" >&2; exit 1; }

PW=()
[[ -n "${ZORPHA_PASSWORD_FILE:-}" ]] && {
  [[ -r "$ZORPHA_PASSWORD_FILE" ]] || { echo "ERROR: cannot read $ZORPHA_PASSWORD_FILE" >&2; exit 1; }
  [[ -s "$ZORPHA_PASSWORD_FILE" ]] || { echo "ERROR: $ZORPHA_PASSWORD_FILE is empty." >&2; exit 1; }
  PW=(--password-file "$ZORPHA_PASSWORD_FILE")
}

num()  { awk '{print $1}'; }
call() { cast call "$@" --rpc-url "$RPC" | num; }
send() { cast send "$@" --rpc-url "$RPC" --account "$ACCOUNT" "${PW[@]}" >/dev/null; }
# `|| true` is load-bearing under pipefail: grep exits 1 on no match, which would
# kill the script before the diagnostic below could report the missing key.
env_of() { grep -E "^$1=" "$WEB_ENV" | head -1 | cut -d= -f2- || true; }

[[ -f "$WEB_ENV" ]] || die "no $WEB_ENV"

TREASURY=$(env_of NEXT_PUBLIC_TREASURY_ADDRESS)
[[ -n "$TREASURY" ]] || TREASURY=$(env_of NEXT_PUBLIC_PROTOCOL_TREASURY_ADDRESS)
TIMELOCK=$(env_of NEXT_PUBLIC_TIMELOCK_ADDRESS)
[[ -n "$TREASURY" ]] || die "no treasury address in $WEB_ENV"
[[ -n "$TIMELOCK" ]] || die "no timelock address in $WEB_ENV"

ACTOR=$(cast wallet address --account "$ACCOUNT" "${PW[@]}")
ZERO=0x0000000000000000000000000000000000000000000000000000000000000000
DATA=$(cast calldata 'acceptOwnership()')
SALT=$(cast keccak "zorpha-treasury-acceptOwnership")

bold "Treasury handover"
info "treasury $TREASURY"
info "timelock $TIMELOCK"
info "actor    $ACTOR"

OWNER=$(call "$TREASURY" 'owner()(address)')
PENDING=$(call "$TREASURY" 'pendingOwner()(address)')

if [[ "${OWNER,,}" == "${TIMELOCK,,}" ]]; then
  ok "already done: the timelock owns the treasury"
  info "rescue() is now a 48h queued operation rather than one EOA transaction"
  exit 0
fi

info "owner        $OWNER"
info "pendingOwner $PENDING"
[[ "${PENDING,,}" == "${TIMELOCK,,}" ]] \
  || die "pendingOwner is $PENDING, not the timelock. transferOwnership has not
     been called toward the timelock, so there is nothing to accept. Fix that
     first -- accepting is the second half of a two-step handover."

printf '  \033[33m~\033[0m %s\n' "the window is OPEN: $OWNER can still call rescue() on every fee collected"

ID=$(call "$TIMELOCK" 'hashOperation(address,uint256,bytes,bytes32,bytes32)(bytes32)' "$TREASURY" 0 "$DATA" "$ZERO" "$SALT")
info "operation $ID"

if [[ "$(call "$TIMELOCK" 'isOperationDone(bytes32)(bool)' "$ID")" == "true" ]]; then
  die "the timelock says this operation is DONE, but owner() is still $OWNER.
     Something accepted and then transferred away again -- do not queue another
     one until that is understood."
fi

if [[ "$(call "$TIMELOCK" 'isOperation(bytes32)(bool)' "$ID")" != "true" ]]; then
  DELAY=$(call "$TIMELOCK" 'getMinDelay()(uint256)')
  bold "Queueing"
  send "$TIMELOCK" 'schedule(address,uint256,bytes,bytes32,bytes32,uint256)' "$TREASURY" 0 "$DATA" "$ZERO" "$SALT" "$DELAY"
  ETA=$(call "$TIMELOCK" 'getTimestamp(bytes32)(uint256)' "$ID")
  ok "queued, executable at $ETA -- $(date -u -d "@$ETA" '+%Y-%m-%d %H:%M UTC')"
  info "re-run this script then to execute it. Until it executes the window is"
  info "still open: queueing starts the clock, it does not close anything."
  exit 0
fi

if [[ "$(call "$TIMELOCK" 'isOperationReady(bytes32)(bool)' "$ID")" != "true" ]]; then
  ETA=$(call "$TIMELOCK" 'getTimestamp(bytes32)(uint256)' "$ID")
  NOW=$(cast block latest --field timestamp --rpc-url "$RPC")
  ok "already queued, executable at $ETA -- $(date -u -d "@$ETA" '+%Y-%m-%d %H:%M UTC')"
  info "$(( (ETA - NOW) / 3600 ))h $(( ((ETA - NOW) % 3600) / 60 ))m remaining"
  exit 0
fi

bold "Executing"
send "$TIMELOCK" 'execute(address,uint256,bytes,bytes32,bytes32)' "$TREASURY" 0 "$DATA" "$ZERO" "$SALT"
NEW=$(call "$TREASURY" 'owner()(address)')
[[ "${NEW,,}" == "${TIMELOCK,,}" ]] || die "execute ran but owner() is $NEW"
ok "the timelock owns the treasury"
ok "pendingOwner cleared to $(call "$TREASURY" 'pendingOwner()(address)')"
info "rescue() is now a 48h queued operation. sweep() is unaffected: it is"
info "permissionless by design and its destinations are immutable, so fee"
info "routing never depended on ownership."

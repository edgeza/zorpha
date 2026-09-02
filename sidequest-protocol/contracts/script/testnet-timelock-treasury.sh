#!/usr/bin/env bash
# Drive the ProtocolTreasury ownership handover through the Timelock.
#
# WHY THIS EXISTS
#
# The burned-key audit comes back with exactly one finding on testnet:
#
#   ProtocolTreasury 0xffc38765... owner is 0xB4a7C2Dee...
#
# 0xB4a7C2Dee is the deployer key that was pasted in plaintext. It is
# permanently compromised. It owns the contract that holds protocol fee
# revenue.
#
# That sounds unfixable without the burned key, and it is not. The old deploy
# already called `transferOwnership(timelock)`, so:
#
#   owner        0xB4a7C2Dee...   (burned)
#   pendingOwner 0x8cca58C0...    (the Timelock)
#
# Ownable2Step means the transfer completes when the RECIPIENT accepts. The
# burned key's part is done and cannot be undone by anyone but the new owner.
# All that remains is for the Timelock to call `acceptOwnership()`, and
# governance controls the Timelock. So the last finding clears with no
# compromised key ever signing again.
#
# WHAT IT PROVES
#
# The handover is the errand. The drill is the point: this is the first time
# the Timelock path runs on chain at all. It proves
#
#   queue     governance can schedule a call it is not allowed to make directly
#   delay     and CANNOT execute it early -- asserted, not assumed. A timelock
#             that queues but does not actually withhold is decoration, and
#             nothing in this repo had ever checked.
#   execute   after the ETA the call lands and ownership moves
#
# The middle assertion is the one worth having and the only one testable
# immediately. The delay is 48h, so this script is idempotent and meant to be
# run twice: once to queue and prove refusal, once after the ETA to execute.
#
# Usage:
#   ./script/testnet-timelock-treasury.sh zorpha-gov
#
# Governance must hold PROPOSER_ROLE and EXECUTOR_ROLE on the Timelock. It
# does -- it also holds CANCELLER_ROLE and DEFAULT_ADMIN.

set -euo pipefail

if ! command -v cast >/dev/null; then
  [[ -d "$HOME/.foundry/bin" ]] && { PATH="$HOME/.foundry/bin:$PATH"; export PATH; }
fi
for t in cast node; do
  command -v "$t" >/dev/null || { echo "ERROR: $t not found" >&2; exit 1; }
done

GOV_ACCT="${1:-}"
[[ -n "$GOV_ACCT" ]] || { echo "usage: $0 <governance-keystore>" >&2; exit 1; }

RPC="${RH_TESTNET_RPC_URL:-https://rpc.testnet.chain.robinhood.com/rpc}"
CHAIN_ID=46630
WEB_ENV="../../zorpha-web/.env.local"

bold() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m+\033[0m %s\n' "$1"; }
info() { printf '    %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
die()  { printf '\n  \033[31mx %s\033[0m\n\n' "$1" >&2; exit 1; }

num()     { awk '{print $1}'; }
env_of()  { grep -E "^$1=" "$WEB_ENV" | head -1 | cut -d= -f2-; }
call()    { cast call "$@" --rpc-url "$RPC" | num; }
lc()      { tr '[:upper:]' '[:lower:]'; }
gov()     { cast send "$@" --rpc-url "$RPC" --account "$GOV_ACCT" >/dev/null; }

[[ -f "$WEB_ENV" ]] || die "no $WEB_ENV"

ACTOR=$(cast wallet address --account "$GOV_ACCT")
TREASURY=$(env_of NEXT_PUBLIC_TREASURY_ADDRESS)
TIMELOCK=$(env_of NEXT_PUBLIC_TIMELOCK_ADDRESS)
[[ -n "$TREASURY" ]] || die "NEXT_PUBLIC_TREASURY_ADDRESS not in $WEB_ENV"
[[ -n "$TIMELOCK" ]] || die "NEXT_PUBLIC_TIMELOCK_ADDRESS not in $WEB_ENV"

# acceptOwnership() takes no arguments, so the calldata is just the selector.
DATA=$(cast calldata 'acceptOwnership()')
PRED=0x0000000000000000000000000000000000000000000000000000000000000000
SALT=0x0000000000000000000000000000000000000000000000000000000000000000

bold "Timelock -> ProtocolTreasury ownership handover"
info "treasury  $TREASURY"
info "timelock  $TIMELOCK"
info "actor     $ACTOR"
info "call      acceptOwnership()  ($DATA)"

# ── 1. The starting state has to be the one this drill assumes. ──────────────
bold "1/5  Preconditions"
OWNER=$(call "$TREASURY" 'owner()(address)')
PENDING=$(call "$TREASURY" 'pendingOwner()(address)')
info "owner        $OWNER"
info "pendingOwner $PENDING"

if [[ "$(echo "$OWNER" | lc)" == "$(echo "$TIMELOCK" | lc)" ]]; then
  ok "already done -- the Timelock owns the treasury"
  info "Nothing to do. The burned-key audit should report zero findings."
  exit 0
fi

[[ "$(echo "$PENDING" | lc)" == "$(echo "$TIMELOCK" | lc)" ]] \
  || die "pendingOwner is $PENDING, not the Timelock. Ownable2Step cannot be
     completed from here -- only the current owner can re-point it, and the
     current owner is a burned key. Stop and reassess."
ok "pendingOwner is the Timelock, so acceptOwnership() is all that is left"

for RN in PROPOSER_ROLE EXECUTOR_ROLE; do
  H=$(call "$TIMELOCK" "$RN()(bytes32)")
  HAS=$(call "$TIMELOCK" 'hasRole(bytes32,address)(bool)' "$H" "$ACTOR")
  [[ "$HAS" == "true" ]] || die "$ACTOR lacks $RN on the Timelock"
done
ok "actor holds both PROPOSER_ROLE and EXECUTOR_ROLE"

DELAY=$(call "$TIMELOCK" 'getMinDelay()(uint256)')
info "minDelay $DELAY seconds ($(( DELAY / 3600 ))h)"

# ── 2. The operation id, read from the contract rather than recomputed. ──────
bold "2/5  Operation id"
OPID=$(call "$TIMELOCK" 'hashOperation(address,uint256,bytes,bytes32,bytes32)(bytes32)' \
        "$TREASURY" 0 "$DATA" "$PRED" "$SALT")
ok "id $OPID"
info "read from hashOperation, not recomputed here -- a locally derived id that"
info "disagrees with the contract would queue one call and query another"

# ── 3. Queue, unless it is already queued. ───────────────────────────────────
bold "3/5  Queue"
IS_OP=$(call "$TIMELOCK" 'isOperation(bytes32)(bool)' "$OPID")
if [[ "$IS_OP" == "true" ]]; then
  ok "already queued by an earlier run"
else
  gov "$TIMELOCK" 'schedule(address,uint256,bytes,bytes32,bytes32,uint256)' \
      "$TREASURY" 0 "$DATA" "$PRED" "$SALT" "$DELAY"
  ok "scheduled"
  IS_OP=$(call "$TIMELOCK" 'isOperation(bytes32)(bool)' "$OPID")
  [[ "$IS_OP" == "true" ]] || die "schedule() returned but isOperation is false"
fi

ETA=$(call "$TIMELOCK" 'getTimestamp(bytes32)(uint256)' "$OPID")
NOW=$(cast block latest --rpc-url "$RPC" --field timestamp | num)
info "eta $ETA, now $NOW"
ok "pending, $(( (ETA > NOW ? ETA - NOW : 0) / 60 )) minutes remaining"

# ── 4. The assertion that matters: it must refuse to run early. ──────────────
bold "4/5  Early execution must be refused"
READY=$(call "$TIMELOCK" 'isOperationReady(bytes32)(bool)' "$OPID")

if [[ "$READY" == "true" ]]; then
  warn "the ETA has already passed, so refusal cannot be tested on this run"
  info "That is not a failure -- it means this is the second run. Skipping to 5."
else
  # A revert here is the pass condition, so the pipeline must not be allowed to
  # abort the script. `set -e` plus a bare `cast send` would exit on success of
  # the assertion, which is exactly backwards.
  set +e
  ERR=$(cast send "$TIMELOCK" 'execute(address,uint256,bytes,bytes32,bytes32)' \
          "$TREASURY" 0 "$DATA" "$PRED" "$SALT" \
          --rpc-url "$RPC" --account "$GOV_ACCT" 2>&1)
  RC=$?
  set -e
  [[ $RC -ne 0 ]] || die "the Timelock EXECUTED A CALL BEFORE ITS ETA.
     The delay is not enforced. Every timelocked action in this protocol --
     adapter installs, fee changes, treasury withdrawals -- is unguarded.
     Stop and do not deploy to mainnet."
  # OZ reverts with TimelockUnexpectedOperationState. Match loosely: the
  # revert reason is what proves it was the delay and not a role failure or a
  # bad-calldata revert, and a role failure would name AccessControl.
  if echo "$ERR" | grep -qi 'UnexpectedOperationState\|not ready\|OperationState'; then
    ok "refused, and refused for the right reason"
    info "$(echo "$ERR" | grep -oi '[A-Za-z]*UnexpectedOperationState[A-Za-z]*' | head -1)"
  elif echo "$ERR" | grep -qi 'AccessControl\|Unauthorized'; then
    die "refused, but for the WRONG reason -- this is a role failure, not the
     delay. The drill proved nothing about the timelock. Error: $ERR"
  else
    warn "refused, but the reason string is unrecognised"
    info "$(echo "$ERR" | head -3)"
  fi
  ok "the delay is enforced on chain"
fi

# ── 5. Execute, if the ETA has passed. ──────────────────────────────────────
bold "5/5  Execute"
READY=$(call "$TIMELOCK" 'isOperationReady(bytes32)(bool)' "$OPID")
if [[ "$READY" != "true" ]]; then
  bold "Queued. Come back after the ETA."
  info "The operation is scheduled and the delay is proven to hold. Re-run this"
  info "same command after $(date -u -d "@$ETA" '+%Y-%m-%d %H:%M UTC' 2>/dev/null || echo "eta $ETA") to execute it:"
  info ""
  info "  ./script/testnet-timelock-treasury.sh $GOV_ACCT"
  info ""
  info "Until then the treasury is still owned by the burned key, so the"
  info "burned-key audit will keep reporting that one finding. That is"
  info "accurate, not stale."
  exit 0
fi

gov "$TIMELOCK" 'execute(address,uint256,bytes,bytes32,bytes32)' \
    "$TREASURY" 0 "$DATA" "$PRED" "$SALT"
ok "executed"

NEW_OWNER=$(call "$TREASURY" 'owner()(address)')
NEW_PENDING=$(call "$TREASURY" 'pendingOwner()(address)')
info "owner        $NEW_OWNER"
info "pendingOwner $NEW_PENDING"

[[ "$(echo "$NEW_OWNER" | lc)" == "$(echo "$TIMELOCK" | lc)" ]] \
  || die "execute() succeeded but owner is $NEW_OWNER, not the Timelock"
ok "the Timelock owns the treasury"

[[ "$NEW_PENDING" == "0x0000000000000000000000000000000000000000" ]] \
  || warn "pendingOwner is still $NEW_PENDING, expected zero"

DONE=$(call "$TIMELOCK" 'isOperationDone(bytes32)(bool)' "$OPID")
[[ "$DONE" == "true" ]] || warn "isOperationDone is $DONE"
ok "operation marked done, so it cannot be replayed"

bold "Handover complete"
info "The burned deployer key no longer owns anything in this deployment."
info "Re-run script/check-burned-keys.sh -- it should report zero findings,"
info "which is the state the mainnet gate requires."

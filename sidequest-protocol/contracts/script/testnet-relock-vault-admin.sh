#!/usr/bin/env bash
# Move DEFAULT_ADMIN_ROLE on the three factory vaults from governance to the
# Timelock, closing the escalation path in docs/FINDINGS-ROLE-ESCALATION.md.
#
# WHY
#
# `setAdapter` is gated on ADAPTER_SETTER_ROLE, held by the Timelock, so
# repointing where depositor funds live reads as a 48h action. It is not:
# AccessControl makes DEFAULT_ADMIN_ROLE the admin of every role, governance
# holds DEFAULT_ADMIN_ROLE, and so governance can grant itself
# ADAPTER_SETTER_ROLE and repoint the adapter in the next transaction.
# Simulated against the live yield vault -- the grant succeeds.
#
# No redeploy is needed. The handover is repeatable from governance while it is
# still admin.
#
# ORDER MATTERS AND IS NOT NEGOTIABLE
#
#   1. grant DEFAULT_ADMIN_ROLE to the Timelock
#   2. verify the Timelock holds it, by reading it back
#   3. grant gov KEEPER_ROLE if it lacks it, so routine work survives
#   4. only then revoke DEFAULT_ADMIN_ROLE from gov
#
# Revoking first, or revoking without confirming step 1 landed, permanently
# strips every admin from the vault: claimFees, setFeeRecipient,
# setSwapAdapter and setFirstLossEscrow become uncallable by anyone, forever,
# with depositor funds inside. So each revoke is gated on a fresh read of the
# chain rather than on the assumption that the previous transaction worked.
#
# WHAT GOVERNANCE LOSES
#
# claimFees, setFeeRecipient, setSwapAdapter, setFirstLossEscrow and
# writeDownAccruedFees become queued Timelock actions. It KEEPS
# RISK_COUNCIL_ROLE, so the circuit breaker is still pullable in one block --
# a delay on the emergency stop would be worse than the bug being fixed.
#
# After this runs, testnet-yield-drill.sh step 6 (claimFees) needs the Timelock.
#
# Usage:
#   ./script/testnet-relock-vault-admin.sh zorpha-gov
#   DRY_RUN=1 ./script/testnet-relock-vault-admin.sh zorpha-gov   # report only

set -euo pipefail

if ! command -v cast >/dev/null; then
  [[ -d "$HOME/.foundry/bin" ]] && { PATH="$HOME/.foundry/bin:$PATH"; export PATH; }
fi
command -v cast >/dev/null || { echo "ERROR: cast not found" >&2; exit 1; }

GOV_ACCT="${1:-}"
[[ -n "$GOV_ACCT" ]] || { echo "usage: $0 <governance-keystore>" >&2; exit 1; }

RPC="${RH_TESTNET_RPC_URL:-https://rpc.testnet.chain.robinhood.com/rpc}"
WEB_ENV="../../zorpha-web/.env.local"
DRY="${DRY_RUN:-0}"

bold() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m+\033[0m %s\n' "$1"; }
info() { printf '    %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
die()  { printf '\n  \033[31mx %s\033[0m\n\n' "$1" >&2; exit 1; }

num()    { awk '{print $1}'; }
env_of() { grep -E "^$1=" "$WEB_ENV" | head -1 | cut -d= -f2-; }
call()   { cast call "$@" --rpc-url "$RPC" | num; }
send()   { cast send "$@" --rpc-url "$RPC" --account "$GOV_ACCT" >/dev/null; }

[[ -f "$WEB_ENV" ]] || die "no $WEB_ENV"

ACTOR=$(cast wallet address --account "$GOV_ACCT")
TIMELOCK=$(env_of NEXT_PUBLIC_TIMELOCK_ADDRESS)
[[ -n "$TIMELOCK" ]] || die "NEXT_PUBLIC_TIMELOCK_ADDRESS not in $WEB_ENV"

ADMIN=0x0000000000000000000000000000000000000000000000000000000000000000
KEEPER=$(cast keccak "KEEPER_ROLE")
RISK=$(cast keccak "RISK_COUNCIL_ROLE")
SETTER=$(cast keccak "ADAPTER_SETTER_ROLE")

bold "Relock vault admin onto the Timelock"
info "timelock $TIMELOCK"
info "gov      $ACTOR"
[[ "$DRY" == "1" ]] && warn "DRY_RUN: reporting only, nothing will be sent"

# The Timelock must be a contract. Handing admin to an EOA typo, then revoking
# gov, is unrecoverable -- and the address comes from a file.
CODE=$(cast code "$TIMELOCK" --rpc-url "$RPC")
[[ ${#CODE} -gt 2 ]] || die "$TIMELOCK has no code. Refusing to hand vault admin
     to something that cannot act. Check NEXT_PUBLIC_TIMELOCK_ADDRESS."
ok "the timelock address holds code"

# And it must actually be a timelock, not just any contract.
MD=$(call "$TIMELOCK" 'getMinDelay()(uint256)' 2>/dev/null || echo "")
[[ -n "$MD" && "$MD" != "0" ]] || die "$TIMELOCK does not answer getMinDelay(), or its
     delay is zero. Either it is not a TimelockController or it enforces no
     delay, and handing it admin would achieve nothing."
ok "it is a timelock with a $MD second delay ($(( MD / 3600 ))h)"

VAULTS=""
for k in NEXT_PUBLIC_SPOT_VAULT_ADDRESS NEXT_PUBLIC_ROTATION_VAULT_ADDRESS NEXT_PUBLIC_YIELD_VAULT_ADDRESS; do
  V=$(env_of "$k")
  [[ -n "$V" ]] || { warn "$k not set, skipping"; continue; }
  VAULTS="$VAULTS $V:${k#NEXT_PUBLIC_}"
done
[[ -n "$VAULTS" ]] || die "no vault addresses found in $WEB_ENV"

CHANGED=0
for entry in $VAULTS; do
  V="${entry%%:*}"; LABEL="${entry##*:}"
  bold "$LABEL"
  info "$V"

  GOV_ADMIN=$(call "$V" 'hasRole(bytes32,address)(bool)' "$ADMIN" "$ACTOR")
  TL_ADMIN=$(call "$V" 'hasRole(bytes32,address)(bool)' "$ADMIN" "$TIMELOCK")
  info "gov admin $GOV_ADMIN, timelock admin $TL_ADMIN"

  if [[ "$GOV_ADMIN" != "true" ]]; then
    if [[ "$TL_ADMIN" == "true" ]]; then
      ok "already relocked; nothing to do"
    else
      warn "neither gov nor the timelock is admin here -- leaving it alone"
      info "This vault has some other admin arrangement. Investigate before"
      info "touching it; a blind grant could be the wrong call."
    fi
    continue
  fi

  # Demonstrate the escalation is real on THIS vault before changing anything,
  # so the script is never just asserting a fix for a problem it did not verify.
  if cast call "$V" 'grantRole(bytes32,address)' "$SETTER" "$ACTOR" \
       --from "$ACTOR" --rpc-url "$RPC" >/dev/null 2>&1; then
    warn "gov CAN currently grant itself ADAPTER_SETTER_ROLE (simulated)"
  else
    info "note: the self-grant simulation did not succeed on this vault"
  fi

  if [[ "$DRY" == "1" ]]; then
    info "would: grantRole(admin, timelock); grantRole(KEEPER, gov); revokeRole(admin, gov)"
    continue
  fi

  # 1. Grant admin to the timelock.
  if [[ "$TL_ADMIN" != "true" ]]; then
    send "$V" 'grantRole(bytes32,address)' "$ADMIN" "$TIMELOCK"
    ok "granted DEFAULT_ADMIN to the timelock"
  fi

  # 2. Read it back from the chain. Not from the send's exit code -- this is the
  #    condition the irreversible step depends on.
  TL_ADMIN=$(call "$V" 'hasRole(bytes32,address)(bool)' "$ADMIN" "$TIMELOCK")
  [[ "$TL_ADMIN" == "true" ]] || die "the timelock is still not admin after the grant.
     REFUSING to revoke gov -- doing so now would leave this vault with no
     admin at all, permanently, with depositor funds in it."
  ok "confirmed on chain: the timelock is admin"

  # 3. Keep governance able to do routine work.
  if [[ "$(call "$V" 'hasRole(bytes32,address)(bool)' "$KEEPER" "$ACTOR")" != "true" ]]; then
    send "$V" 'grantRole(bytes32,address)' "$KEEPER" "$ACTOR"
    ok "granted gov KEEPER_ROLE"
  fi
  if [[ "$(call "$V" 'hasRole(bytes32,address)(bool)' "$RISK" "$ACTOR")" != "true" ]]; then
    send "$V" 'grantRole(bytes32,address)' "$RISK" "$ACTOR"
    ok "granted gov RISK_COUNCIL_ROLE"
  fi
  ok "gov keeps KEEPER and RISK_COUNCIL, so the circuit breaker stays immediate"

  # 4. Now, and only now.
  send "$V" 'revokeRole(bytes32,address)' "$ADMIN" "$ACTOR"
  GOV_ADMIN=$(call "$V" 'hasRole(bytes32,address)(bool)' "$ADMIN" "$ACTOR")
  [[ "$GOV_ADMIN" == "false" ]] || die "revoke returned but gov is still admin"
  ok "revoked gov's DEFAULT_ADMIN"

  # And the escalation must now be closed, tested rather than assumed.
  if cast call "$V" 'grantRole(bytes32,address)' "$SETTER" "$ACTOR" \
       --from "$ACTOR" --rpc-url "$RPC" >/dev/null 2>&1; then
    die "gov can STILL grant itself ADAPTER_SETTER_ROLE. The escalation is open
     and this vault is not fixed. Do not report it as such."
  fi
  ok "gov can no longer grant itself ADAPTER_SETTER_ROLE"
  CHANGED=$((CHANGED + 1))
done

bold "Done"
if [[ "$DRY" == "1" ]]; then
  info "Dry run. Re-run without DRY_RUN=1 to apply."
else
  info "$CHANGED vault(s) relocked."
  info ""
  info "Governance now reaches claimFees, setFeeRecipient, setSwapAdapter and"
  info "setFirstLossEscrow only through the Timelock. The circuit breaker is"
  info "unchanged and still immediate."
  info ""
  info "testnet-yield-drill.sh step 6 calls claimFees, so it will now need a"
  info "queued action. That is the delay working, not a regression."
fi

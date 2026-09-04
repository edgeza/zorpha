#!/usr/bin/env bash
# Run a drill that needs a KEYSTORE signer, then put the executor back.
#
# WHY THIS EXISTS
#
# StrategyExecutor.authorizedSigner is a single `address`, not a set. So the
# executor can trust the manager's browser wallet OR a keystore key that `cast`
# can sign with -- never both. Three drills need the latter:
#
#     testnet-spot-lifecycle.sh   testnet-spot-drill.sh   testnet-rotation-drill.sh
#
# and each dies in preflight with
#
#     x executor trusts 0x65a35Fd2...83485, not 0x5EC41DBe...4cB5F6
#
# unless the signer is switched first. Doing that by hand is three commands
# whose ORDER is the whole point, and the order is easy to get wrong: switch,
# restore, drill leaves the drill failing on the same error it started with,
# having spent two governance transactions to end up exactly where it began.
# That happened.
#
# Worse is the other way. If the drill crashes, is interrupted, or the machine
# goes to sleep between switch and restore, the executor is left trusting a
# key the portal does not hold -- so every rebalance signed in the Terminal
# reverts with InvalidSignature, and nothing in the UI explains why. A manual
# step that must run after a step that can fail is not a step, it is a bet.
#
# So: read the current signer off-chain, switch, run, and restore on the way
# out no matter how the exit happens -- success, failure, or Ctrl-C.
#
# The restore target is READ FROM THE CHAIN, never hardcoded. Hardcoding it
# would silently clobber whatever the signer had been changed to in between.
#
# Usage:
#   ./script/with-keystore-signer.sh <signer-keystore> <gov-keystore> -- <cmd...>
#
# Example:
#   ./script/with-keystore-signer.sh zorpha-signer zorpha-gov -- \
#       ./script/testnet-spot-lifecycle.sh zorpha-signer zorpha-gov
#
# Expect FOUR password prompts: gov to switch, whatever the drill asks for,
# then gov again to restore.

set -euo pipefail

if ! command -v cast >/dev/null; then
  [[ -d "$HOME/.foundry/bin" ]] && { PATH="$HOME/.foundry/bin:$PATH"; export PATH; }
fi
command -v cast >/dev/null || { echo "ERROR: cast not found" >&2; exit 1; }

SIGNER_ACCT="${1:-}"; GOV_ACCT="${2:-}"; SEP="${3:-}"
[[ -n "$SIGNER_ACCT" && -n "$GOV_ACCT" && "$SEP" == "--" ]] || {
  echo "usage: $0 <signer-keystore> <gov-keystore> -- <command...>" >&2
  exit 2
}
shift 3
[[ $# -gt 0 ]] || { echo "ERROR: no command given after --" >&2; exit 2; }

# Optional non-interactive signing.
#
# This drill unlocks a keystore ~14 times -- once per governance send, plus the
# two address lookups and one signature per rebalance -- and every one of them
# prompts. A single mistyped password aborts the run partway through, which
# happened at step 3/9 with two contracts already deployed.
#
# ETH_PASSWORD is NOT the fix, despite being cast's own env var for this. Set
# it and clap marks --password-file as supplied for EVERY subcommand, so plain
# reads start failing:
#
#     cast call ... -> error: the following required arguments were not
#                      provided: --keystore <PATH>
#
# because --password-file "is used with --keystore" and cast call has neither.
# Passing the flag explicitly, only where a keystore is actually opened, has no
# such effect. --account and --password-file are a legal pair.
#
# Opt-in and empty by default, so nothing changes unless it is set:
#     ZORPHA_PASSWORD_FILE=/path/to/pw ./script/...
PW=()
[[ -n "${ZORPHA_PASSWORD_FILE:-}" ]] && {
  [[ -r "$ZORPHA_PASSWORD_FILE" ]] || { echo "ERROR: cannot read $ZORPHA_PASSWORD_FILE" >&2; exit 1; }
  [[ -s "$ZORPHA_PASSWORD_FILE" ]] || { echo "ERROR: $ZORPHA_PASSWORD_FILE is empty. A shell that captures a
       passphrase without echoing it will happily write a zero-byte file, and
       cast then reports an unhelpful decryption failure instead." >&2; exit 1; }
  PW=(--password-file "$ZORPHA_PASSWORD_FILE")
}

RPC="${RH_TESTNET_RPC_URL:-https://rpc.testnet.chain.robinhood.com/rpc}"
WEB_ENV="${WEB_ENV:-../../zorpha-web/.env.local}"

bold() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m+\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
die()  { printf '\n  \033[31mx %s\033[0m\n\n' "$1" >&2; exit 1; }

# `|| true` because grep exits 1 on no match and pipefail would kill the script
# before the diagnostic below could report the missing key.
env_of() { grep -E "^$1=" "$WEB_ENV" | head -1 | cut -d= -f2- | tr -d '\r' || true; }

[[ -f "$WEB_ENV" ]] || die "no $WEB_ENV"
EXEC=$(env_of NEXT_PUBLIC_STRATEGY_EXECUTOR_ADDRESS)
[[ -n "$EXEC" ]] || die "NEXT_PUBLIC_STRATEGY_EXECUTOR_ADDRESS not set in $WEB_ENV"

WANT=$(cast wallet address --account "$SIGNER_ACCT" "${PW[@]}")
PREV=$(cast call "$EXEC" 'authorizedSigner()(address)' --rpc-url "$RPC" | awk '{print $1}')

bold "Signer swap"
printf '    executor  %s\n    current   %s\n    drill     %s\n' "$EXEC" "$PREV" "$WANT"

if [[ "${PREV,,}" == "${WANT,,}" ]]; then
  ok "already the drill signer, nothing to swap"
  exec "$@"
fi

# Armed BEFORE the switch, so an interrupt during the switch itself still tries
# to restore. Restoring to what was actually there, read above.
restore() {
  local rc=$?
  bold "Restoring signer"
  if cast send "$EXEC" 'setAuthorizedSigner(address)' "$PREV" \
       --rpc-url "$RPC" --account "$GOV_ACCT" "${PW[@]}" >/dev/null 2>&1; then
    local now
    now=$(cast call "$EXEC" 'authorizedSigner()(address)' --rpc-url "$RPC" | awk '{print $1}')
    if [[ "${now,,}" == "${PREV,,}" ]]; then
      ok "executor trusts $PREV again"
    else
      warn "restore sent but executor now trusts $now -- expected $PREV"
    fi
  else
    # Loud, and repeated, because the consequence is invisible in the UI: the
    # portal's Terminal will revert every signed rebalance until this is undone.
    printf '\n\033[31m  RESTORE FAILED. The executor still trusts %s.\n' "$WANT"
    printf '  The portal cannot sign rebalances until you run:\n\n'
    printf '    cast send %s '\''setAuthorizedSigner(address)'\'' %s \\n' "$EXEC" "$PREV"
    printf '      --rpc-url %s --account %s\033[0m\n\n' "$RPC" "$GOV_ACCT"
  fi
  exit $rc
}
trap restore EXIT INT TERM

cast send "$EXEC" 'setAuthorizedSigner(address)' "$WANT" \
  --rpc-url "$RPC" --account "$GOV_ACCT" "${PW[@]}" >/dev/null
ok "executor now trusts $WANT"

bold "Running: $*"
"$@"

#!/usr/bin/env bash
#
# Close the equity vaults for a market holiday.
#
# The weekly trading window knows about Saturdays. It knows nothing about
# Thanksgiving, and on a holiday the oracle carries yesterday close while the
# window says the market is open -- exactly the state _checkTradingWindow exists
# to prevent, on one of the nine days a year it is most likely to matter.
#
# closedUntil IS A SINGLE TIMESTAMP PER VAULT. It cannot hold a calendar, so
# this cannot be run once and forgotten: each closure has to be set on or before
# the day it applies to. That is a property of the contract, not a shortcoming of
# this script, and it is the reason this is written to be run from cron every
# morning rather than by hand twice a year.
#
#   0 6 * * *  cd .../contracts && ZORPHA_PASSWORD_FILE=... ./script/market-holiday.sh <gov>
#
# On an ordinary day it does nothing and says so. On the morning of a holiday it
# sets closedUntil past the end of it.
set -euo pipefail

ACCOUNT="${1:-}"
[[ -n "$ACCOUNT" ]] || { echo "usage: $0 <governance-keystore> [YYYY-MM-DD]" >&2; exit 1; }
ON_DATE="${2:-}"

RPC="${RH_TESTNET_RPC_URL:-https://rpc.testnet.chain.robinhood.com/rpc}"
WEB_ENV="../../zorpha-web/.env.local"
CAL="${MARKET_HOLIDAYS:-script/market-holidays.txt}"
LOOKAHEAD="${LOOKAHEAD_DAYS:-14}"

bold() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m+\033[0m %s\n' "$1"; }
info() { printf '    %s\n' "$1"; }
warn() { printf '  \033[33m~\033[0m %s\n' "$1"; }
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
env_of() { grep -E "^$1=" "$WEB_ENV" | head -1 | cut -d= -f2- || true; }

[[ -f "$WEB_ENV" ]] || die "no $WEB_ENV"
[[ -f "$CAL" ]] || die "no holiday calendar at $CAL"

EXEC=$(env_of NEXT_PUBLIC_STRATEGY_EXECUTOR_ADDRESS)
[[ -n "$EXEC" ]] || die "no executor address in $WEB_ENV"
ACTOR=$(cast wallet address --account "$ACCOUNT" "${PW[@]}")

NOW=$(cast block latest --field timestamp --rpc-url "$RPC")
TODAY="${ON_DATE:-$(date -u -d "@$NOW" +%Y-%m-%d)}"

bold "Market holidays"
info "executor $EXEC"
info "calendar $CAL"
info "date     $TODAY$( [[ -n "$ON_DATE" ]] && echo '  (overridden)' )"

# --- The calendar --------------------------------------------------------
DATES=$(grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}' "$CAL" | awk '{print $1}' | sort)
COUNT=$(printf '%s\n' "$DATES" | grep -c . || true)
LAST=$(printf '%s\n' "$DATES" | tail -1)
[[ "$COUNT" -gt 0 ]] || die "the calendar has no entries. Nothing would ever be closed,
     which is indistinguishable from there being no holidays."

# An exhausted calendar is the failure mode that matters: it looks exactly like
# a quiet year. Say so loudly and keep saying it.
DAYS_LEFT=$(( ( $(date -u -d "$LAST" +%s) - NOW ) / 86400 ))
if [[ "$DAYS_LEFT" -lt 0 ]]; then
  die "the calendar RAN OUT on $LAST. Every day now looks like a trading day to
     this script, and it will keep reporting nothing to do while real closures
     pass. Extend $CAL."
elif [[ "$DAYS_LEFT" -lt 60 ]]; then
  warn "the calendar ends on $LAST, in $DAYS_LEFT days. Extend it before it runs out:
     an exhausted calendar reports nothing to do, exactly like a quiet month."
else
  ok "$COUNT entries, through $LAST"
fi

# --- Upcoming, so a human reading the cron output can see what is coming ---
bold "Next $LOOKAHEAD days"
UPCOMING=0
while read -r d; do
  [[ -n "$d" ]] || continue
  delta=$(( ( $(date -u -d "$d" +%s) - $(date -u -d "$TODAY" +%s) ) / 86400 ))
  if [[ "$delta" -ge 0 && "$delta" -le "$LOOKAHEAD" ]]; then
    name=$(grep -E "^$d" "$CAL" | head -1 | cut -d' ' -f2- | sed 's/^ *//')
    if [[ "$delta" -eq 0 ]]; then info "TODAY  $d  $name"; else info "+${delta}d    $d  $name"; fi
    UPCOMING=$((UPCOMING + 1))
  fi
done <<<"$DATES"
[[ "$UPCOMING" -gt 0 ]] || info "none"

# --- Is today one? --------------------------------------------------------
if ! grep -qE "^$TODAY" "$CAL"; then
  bold "Nothing to do"
  echo "  $TODAY is not a market holiday. The weekly window governs today."
  exit 0
fi

NAME=$(grep -E "^$TODAY" "$CAL" | head -1 | cut -d' ' -f2- | sed 's/^ *//')
bold "Today is $NAME"

# Consecutive closures are one closure. Walk forward while the next day is
# either another holiday or a weekend, and close until the market reopens --
# otherwise a Thursday-and-Friday pair would need two runs and a Friday closure
# would reopen into a Saturday the mask already covers.
REOPEN="$TODAY"
for _ in $(seq 1 10); do
  NEXT=$(date -u -d "$REOPEN + 1 day" +%Y-%m-%d)
  DOW=$(date -u -d "$NEXT" +%u)          # 1=Mon .. 7=Sun
  if grep -qE "^$NEXT" "$CAL" || [[ "$DOW" -ge 6 ]]; then REOPEN="$NEXT"; else break; fi
done
UNTIL=$(date -u -d "$REOPEN 23:59:59" +%s)
info "closed through $REOPEN, reopening the next trading day"
info "closedUntil $UNTIL -- $(date -u -d "@$UNTIL" '+%Y-%m-%d %H:%M UTC')"

# closedUntil HALTS FROM NOW, not on the day.
#
# The check is `if (block.timestamp < until) revert MarketHalted`, so setting it
# for Christmas in September does not schedule a closure in December -- it shuts
# the vaults for three months starting immediately. That is the obvious way to
# use this function and it is catastrophically wrong, which is why it is refused
# here rather than documented somewhere.
LEAD_DAYS=$(( ( UNTIL - NOW ) / 86400 ))
MAX_LEAD="${MAX_LEAD_DAYS:-4}"
if [[ "$LEAD_DAYS" -gt "$MAX_LEAD" ]]; then
  die "$TODAY is $LEAD_DAYS days away, and closedUntil halts from NOW until the
     timestamp -- it does not schedule anything. Setting it would stop
     rebalancing for $LEAD_DAYS days starting immediately.

     Run this on or shortly before the day (MAX_LEAD_DAYS raises the bound,
     which you want only when queueing through a timelock whose delay is longer
     than the lead)."
fi

if [[ -n "${DRY_RUN:-}" ]]; then
  bold "Dry run"
  echo "  Would set closedUntil to $UNTIL on every vault with a window enforced."
  echo "  Nothing was sent."
  exit 0
fi

# --- Apply, to the vaults that actually enforce a window -------------------
#
# A vault with enforced=false is 24/7 by choice -- the yield vault, whose venue
# is a money market that does not close. Setting a holiday on it would halt a
# stablecoin position for a reason that does not apply to it.
bold "Applying"
ADMIN_ROLE=0x0000000000000000000000000000000000000000000000000000000000000000
IS_ADMIN=$(call "$EXEC" 'hasRole(bytes32,address)(bool)' "$ADMIN_ROLE" "$ACTOR")

TOUCHED=0
for key in NEXT_PUBLIC_SPOT_VAULT_ADDRESS NEXT_PUBLIC_ROTATION_VAULT_ADDRESS NEXT_PUBLIC_YIELD_VAULT_ADDRESS; do
  V=$(env_of "$key"); [[ -n "$V" ]] || continue
  LABEL=$(echo "$key" | sed -E 's/NEXT_PUBLIC_(.*)_VAULT_ADDRESS/\1/' | tr 'A-Z' 'a-z')

  read -r _o _c _m ENFORCED <<<"$(cast call "$EXEC" 'tradingWindow(address)(uint16,uint16,uint8,bool)' "$V" --rpc-url "$RPC" | tr '\n' ' ')"
  if [[ "$ENFORCED" != "true" ]]; then
    info "$LABEL skipped -- no window enforced, so it is 24/7 by choice"
    continue
  fi

  CUR=$(call "$EXEC" 'closedUntil(address)(uint64)' "$V")
  if [[ "$CUR" -ge "$UNTIL" ]]; then
    ok "$LABEL already closed to $CUR, at or past this holiday"
    continue
  fi

  if [[ "$IS_ADMIN" != "true" ]]; then
    warn "$LABEL needs governance -- $ACTOR does not hold DEFAULT_ADMIN"
    info "queue: $(cast calldata 'setClosedUntil(address,uint64)' "$V" "$UNTIL")"
    continue
  fi

  send "$EXEC" 'setClosedUntil(address,uint64)' "$V" "$UNTIL"
  GOT=$(call "$EXEC" 'closedUntil(address)(uint64)' "$V")
  [[ "$GOT" == "$UNTIL" ]] || die "$LABEL closedUntil is $GOT, expected $UNTIL"
  ok "$LABEL closed until $UNTIL"
  TOUCHED=$((TOUCHED + 1))
done

bold "Done"
if [[ "$IS_ADMIN" != "true" ]]; then
  echo "  Nothing was sent: this address does not admin the executor, which is"
  echo "  the correct state on mainnet. The calldata above goes through the"
  echo "  timelock -- and a 48h delay means a holiday has to be queued two days"
  echo "  ahead, so run this from cron with LOOKAHEAD_DAYS and queue on the"
  echo "  first warning rather than on the morning itself."
else
  echo "  $TOUCHED vault(s) closed for $NAME, through $REOPEN."
  echo "  Rebalances on them now revert MarketHalted, which outranks an open"
  echo "  weekly schedule. Deposits and redemptions are unaffected."
fi

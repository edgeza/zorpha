#!/usr/bin/env bash
#
# Set the trading windows to the reference market's real hours.
#
# The vaults hold tokenised US equities. Their oracle prices those equities, and
# outside the session that price is Friday's close -- so a rebalance executed at
# 03:00 on a Sunday trades against a number that stopped being true two days
# ago. StrategyExecutor._checkTradingWindow exists to refuse that, and until this
# script is run every vault has enforced=false, which is 24/7.
#
# DST IS THE WHOLE DIFFICULTY, and the contract deliberately does not handle it:
#
#     US equities run 13:30-20:00 UTC in summer and 14:30-21:00 in winter.
#     Governance must reset the window at each transition -- two transactions a
#     year, explicit and auditable through TradingWindowSet.
#
# So the schedule has to come from a real calendar, and this script takes it from
# node's ICU timezone database rather than hand-coding "second Sunday in March".
# Hand-coded DST is wrong for every market that is not the one it was written
# for, and wrong again the next time a legislature moves the dates -- which is
# the same argument that kept it off chain. Asking a maintained tz database what
# 09:30 in New York is in UTC today has neither failure mode.
#
# Re-run at every transition. The script prints the date of the next one.
set -euo pipefail

ACCOUNT="${1:-}"
[[ -n "$ACCOUNT" ]] || { echo "usage: $0 <governance-keystore>" >&2; exit 1; }

RPC="${RH_TESTNET_RPC_URL:-https://rpc.testnet.chain.robinhood.com/rpc}"
WEB_ENV="../../zorpha-web/.env.local"
MARKET_TZ="${MARKET_TZ:-America/New_York}"
OPEN_LOCAL="${OPEN_LOCAL:-09:30}"
CLOSE_LOCAL="${CLOSE_LOCAL:-16:00}"
WEEKDAY_MASK=0x3E                      # Mon-Fri. bit 0 is Sunday.

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
EXEC=$(env_of NEXT_PUBLIC_STRATEGY_EXECUTOR_ADDRESS)
[[ -n "$EXEC" ]] || die "no executor address in $WEB_ENV"
ACTOR=$(cast wallet address --account "$ACCOUNT" "${PW[@]}")
NOW=$(cast block latest --field timestamp --rpc-url "$RPC")

# The calendar, asked rather than assumed.
read -r OPEN_MIN CLOSE_MIN TZNAME NEXT_SHIFT <<<"$(MSYS_NO_PATHCONV=1 node -e '
  const [ts, tz, openL, closeL] = process.argv.slice(1);
  const at = Number(ts) * 1000;

  const partsIn = (d) => {
    const p = new Intl.DateTimeFormat("en-US", { timeZone: tz, hour: "2-digit", minute: "2-digit", hour12: false }).formatToParts(new Date(d));
    return [+p.find(x => x.type === "hour").value, +p.find(x => x.type === "minute").value];
  };
  const offsetMinutes = (d) => {
    const [H, M] = partsIn(d);
    const u = new Date(d);
    let diff = (H * 60 + M) - (u.getUTCHours() * 60 + u.getUTCMinutes());
    if (diff > 720) diff -= 1440;
    if (diff < -720) diff += 1440;
    return diff;
  };

  // local minute -> UTC minute on the day `at` falls in, via the live offset.
  const off = offsetMinutes(at);
  const toUtc = (hhmm) => {
    const [h, m] = hhmm.split(":").map(Number);
    return ((h * 60 + m) - off + 1440) % 1440;
  };

  const zone = new Intl.DateTimeFormat("en-US", { timeZone: tz, timeZoneName: "short" })
    .formatToParts(new Date(at)).find(x => x.type === "timeZoneName").value;

  // Walk forward a day at a time until the offset changes: the next transition.
  let shift = "none within a year";
  for (let d = 1; d <= 400; d++) {
    const t = at + d * 86400000;
    if (offsetMinutes(t) !== off) {
      shift = new Date(t).toISOString().slice(0, 10);
      break;
    }
  }
  process.stdout.write([toUtc(openL), toUtc(closeL), zone, shift].join(" "));
' -- "$NOW" "$MARKET_TZ" "$OPEN_LOCAL" "$CLOSE_LOCAL")"

bold "Trading hours"
info "executor $EXEC"
info "market   $MARKET_TZ, $OPEN_LOCAL-$CLOSE_LOCAL local, currently $TZNAME"
info "which is UTC minutes $OPEN_MIN-$CLOSE_MIN today"
info "     i.e. $(printf '%02d:%02d' $((OPEN_MIN/60)) $((OPEN_MIN%60)))-$(printf '%02d:%02d' $((CLOSE_MIN/60)) $((CLOSE_MIN%60))) UTC, Mon-Fri"
warn "next DST transition: $NEXT_SHIFT -- re-run this script on that date"

# Which vaults get a window, and which do not.
#
# spot and rotation both price real-world assets through the oracle and both
# have discretion over when to trade, so both take the reference market's hours.
#
# The yield vault does not. Its asset is a stablecoin, its venue is an ERC-4626
# money market that does not close, and its only keeper action is rebalanceTo()
# with NO arguments -- there is no discretion to constrain and no stale equity
# price to trade against. Giving it market hours would stop deposits being routed
# to a venue overnight for no gain. Left at 24/7 on purpose, and said out loud
# because an unset window and a deliberately-open one look identical on chain.
SPOT=$(env_of NEXT_PUBLIC_SPOT_VAULT_ADDRESS)
ROTATION=$(env_of NEXT_PUBLIC_ROTATION_VAULT_ADDRESS)
YIELD=$(env_of NEXT_PUBLIC_YIELD_VAULT_ADDRESS)
[[ -n "$SPOT" && -n "$ROTATION" ]] || die "could not read the vault addresses from $WEB_ENV"

show() {   # show <label> <vault>
  local w
  w=$(cast call "$EXEC" 'tradingWindow(address)(uint16,uint16,uint8,bool)' "$2" --rpc-url "$RPC" | tr '\n' ' ')
  read -r o c m e <<<"$w"
  if [[ "$e" == "true" ]]; then
    printf '    %-9s %s  open %s-%s UTC, mask %s\n' "$1" "${2:0:10}" "$o" "$c" "$m"
  else
    printf '    %-9s %s  no window enforced (24/7)\n' "$1" "${2:0:10}"
  fi
}

bold "Before"
show spot "$SPOT"; show rotation "$ROTATION"; show yield "$YIELD"

# On a correctly handed-over mainnet the admin is the timelock, and this script
# cannot send. Rather than failing at the first revert, print what governance
# needs to queue. The calldata is the same either way.
ADMIN_ROLE=0x0000000000000000000000000000000000000000000000000000000000000000
if [[ "$(call "$EXEC" 'hasRole(bytes32,address)(bool)' "$ADMIN_ROLE" "$ACTOR")" != "true" ]]; then
  bold "Not admin -- queue these instead"
  warn "$ACTOR does not hold DEFAULT_ADMIN on the executor."
  info "That is the correct state on mainnet, where it is the timelock. Queue:"
  for pair in "spot:$SPOT" "rotation:$ROTATION"; do
    echo
    info "# ${pair%%:*}"
    info "cast calldata 'setTradingWindow(address,uint16,uint16,uint8)' ${pair##*:} $OPEN_MIN $CLOSE_MIN $WEEKDAY_MASK"
    info "  -> $(cast calldata 'setTradingWindow(address,uint16,uint16,uint8)' "${pair##*:}" "$OPEN_MIN" "$CLOSE_MIN" "$WEEKDAY_MASK")"
  done
  echo
  info "Schedule each against the executor through the timelock, then re-run this"
  info "script to verify what actually landed."
  exit 0
fi

bold "Setting"
for pair in "spot:$SPOT" "rotation:$ROTATION"; do
  name=${pair%%:*}; addr=${pair##*:}
  send "$EXEC" 'setTradingWindow(address,uint16,uint16,uint8)' "$addr" "$OPEN_MIN" "$CLOSE_MIN" "$WEEKDAY_MASK"
  ok "$name set to $OPEN_MIN-$CLOSE_MIN UTC, Mon-Fri"
done

bold "After"
verify() {   # verify <label> <vault>
  read -r o c m e <<<"$(cast call "$EXEC" 'tradingWindow(address)(uint16,uint16,uint8,bool)' "$2" --rpc-url "$RPC" | tr '\n' ' ')"
  [[ "$e" == "true" ]]      || die "$1 still reports enforced=false after being set"
  [[ "$o" == "$OPEN_MIN" ]] || die "$1 open is $o, expected $OPEN_MIN"
  [[ "$c" == "$CLOSE_MIN" ]]|| die "$1 close is $c, expected $CLOSE_MIN"
  [[ "$m" == "62" ]]        || die "$1 weekday mask is $m, expected 62 (0x3E, Mon-Fri)"
  ok "$1 verified on chain"
}
verify spot "$SPOT"; verify rotation "$ROTATION"
show yield "$YIELD"

# Is the market open right now? Useful because the very next thing an operator
# does is wonder why a rebalance was refused.
DOW=$(( (NOW / 86400 + 4) % 7 ))
MIN=$(( (NOW % 86400) / 60 ))
bold "Right now"
info "$(date -u -d "@$NOW" '+%A %H:%M UTC') -- day $DOW, minute $MIN"
if [[ $DOW -lt 1 || $DOW -gt 5 ]]; then
  warn "the market is CLOSED (weekend). Rebalances on spot and rotation will"
  info "revert MarketClosed until Monday. That is the point of this change."
elif [[ $MIN -lt $OPEN_MIN || $MIN -ge $CLOSE_MIN ]]; then
  warn "the market is CLOSED (outside $OPEN_MIN-$CLOSE_MIN). Rebalances will revert"
  info "MarketClosed until it opens. That is the point of this change."
else
  ok "the market is OPEN; rebalances are permitted for another $(( CLOSE_MIN - MIN )) minutes"
fi

bold "Done"
echo "  spot and rotation now refuse rebalances outside $OPEN_LOCAL-$CLOSE_LOCAL"
echo "  $MARKET_TZ, Monday to Friday. The yield vault stays 24/7, deliberately."
echo
echo "  Two things this does NOT do:"
echo "  - Holidays. $MARKET_TZ closes about nine days a year that this weekly"
echo "    schedule knows nothing about. Use setClosedUntil for each one; the"
echo "    trading-window drill proves it outranks an open schedule."
echo "  - DST. Re-run on $NEXT_SHIFT or the window is an hour wrong for months."

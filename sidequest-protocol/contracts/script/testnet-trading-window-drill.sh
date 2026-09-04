#!/usr/bin/env bash
#
# Trading windows, on chain.
#
# StrategyExecutor._checkTradingWindow is the only thing standing between a
# manager and a rebalance executed at 03:00 on a Sunday against an equity price
# frozen since Friday's close. It is covered in Solidity and had never been run
# against a real chain, which matters more here than usual, for two reasons.
#
# First, the schedule is derived from block.timestamp by arithmetic:
#
#     dayOfWeek = ((block.timestamp / 1 days) + 4) % 7      // 0 = Sunday
#     minuteUTC = (block.timestamp % 1 days) / 60
#
# A unit test that builds its expectation from those same two expressions agrees
# with itself no matter what they say. An off-by-one in the +4 shifts the whole
# week -- a Monday enforced as a Sunday -- and every such test still passes. So
# step 2 takes the day and minute the CONTRACT reports, out of its own revert
# data, and checks them against GNU date for the same timestamp: two independent
# implementations of the Gregorian calendar, one of which is not ours.
#
# Second, the open/close comparison has two branches -- a normal window and one
# that wraps midnight -- and the wrapping branch is the one a US market session
# needs once expressed in UTC. Both are exercised.
#
# Everything runs against an executor and a target this script deploys, for the
# reason the other drills own their fixtures: the live executor's schedule belongs
# to governance, and a drill that rewrote it would be changing production in
# order to observe production.
set -euo pipefail

ACCOUNT="${1:-}"
[[ -n "$ACCOUNT" ]] || { echo "usage: $0 <governance-keystore>" >&2; exit 1; }

RPC="${RH_TESTNET_RPC_URL:-https://rpc.testnet.chain.robinhood.com/rpc}"

bold() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m+\033[0m %s\n' "$1"; }
info() { printf '    %s\n' "$1"; }
die()  { printf '\n  \033[31mx %s\033[0m\n' "$1" >&2; exit 1; }

PW=()
[[ -n "${ZORPHA_PASSWORD_FILE:-}" ]] && {
  [[ -r "$ZORPHA_PASSWORD_FILE" ]] || { echo "ERROR: cannot read $ZORPHA_PASSWORD_FILE" >&2; exit 1; }
  [[ -s "$ZORPHA_PASSWORD_FILE" ]] || { echo "ERROR: $ZORPHA_PASSWORD_FILE is empty. A shell that captures a
       passphrase without echoing it will happily write a zero-byte file, and
       cast then reports an unhelpful decryption failure instead." >&2; exit 1; }
  PW=(--password-file "$ZORPHA_PASSWORD_FILE")
}

num()  { awk '{print $1}'; }
call() { cast call "$@" --rpc-url "$RPC" | num; }
send() { cast send "$@" --rpc-url "$RPC" --account "$ACCOUNT" "${PW[@]}" >/dev/null; }
now()  { cast block latest --field timestamp --rpc-url "$RPC"; }
deployed_to() { MSYS_NO_PATHCONV=1 node -e 'process.stdout.write(JSON.parse(process.argv[1]).deployedTo || "")' -- "$1"; }

ERRFILE=$(mktemp)
trap 'rm -f "$ERRFILE"' EXIT

ACTOR=$(cast wallet address --account "$ACCOUNT" "${PW[@]}")

bold "Trading window drill"
info "actor  $ACTOR"

# --- 0. Fixtures -----------------------------------------------------------
#
# A fresh executor, not the live one. Beyond not rewriting production's schedule:
# setTradingWindow is onlyRole(DEFAULT_ADMIN_ROLE), and on a correctly
# handed-over deployment that admin is the timelock, so every step below would
# be a 48h queue-and-execute. Owning the fixture is what makes the drill
# runnable. It is deliberately NOT cached -- today's lesson is that a fixture
# keyed to anything but the run it belongs to comes back to bite.
bold "0/9  Fixtures"

OUT=$(forge create src/executor/StrategyExecutor.sol:StrategyExecutor --rpc-url "$RPC" --account "$ACCOUNT" "${PW[@]}" --broadcast --json --constructor-args "$ACTOR")
EXEC=$(deployed_to "$OUT")
[[ -n "$EXEC" ]] || die "could not deploy the drill executor"
ok "executor $EXEC"

OUT=$(forge create src/testnet/TestnetFixtures.sol:NoopRebalancer --rpc-url "$RPC" --account "$ACCOUNT" "${PW[@]}" --broadcast --json)
NOOP=$(deployed_to "$OUT")
[[ -n "$NOOP" ]] || die "could not deploy the rebalance target"
ok "target   $NOOP"

KR=$(call "$EXEC" 'KEEPER_ROLE()(bytes32)')
send "$EXEC" 'grantRole(bytes32,address)' "$KR" "$ACTOR"
# Deliberately generous. The rate limit is another drill's subject, and one
# reached mid-run here would revert DailyLimitExceeded and read as a window
# fault.
send "$EXEC" 'setDailyLimit(address,uint256)' "$NOOP" 50
ok "actor holds KEEPER_ROLE; rate limit 50, so it cannot interfere"

SIGNER=$(call "$EXEC" 'signerFor(address)(address)' "$NOOP")
[[ "${SIGNER,,}" == "${ACTOR,,}" ]] || die "the fresh executor trusts $SIGNER, not $ACTOR"

DOMAIN=$(call "$EXEC" 'DOMAIN_SEPARATOR()(bytes32)')
TYPEHASH=$(call "$EXEC" 'REBALANCE_TYPEHASH()(bytes32)')

digest_for() {
  local sh
  sh=$(cast keccak "$(cast abi-encode 'f(bytes32,address,uint16,uint256,uint256)' "$TYPEHASH" "$1" "$2" "$3" "$4")")
  cast keccak "$(printf '0x1901%s%s' "${DOMAIN#0x}" "${sh#0x}")"
}

NONCE=$(call "$EXEC" 'nonces(address)(uint256)' "$NOOP")

# 0 if the rebalance landed. On failure the revert is left in ERRFILE.
attempt() {
  local n=$((NONCE + 1)) exp sig
  exp=$(( $(now) + 3600 ))
  sig=$(cast wallet sign --no-hash --account "$ACCOUNT" "${PW[@]}" "$(digest_for "$NOOP" 5000 "$n" "$exp")")
  if cast send "$EXEC" 'executeRebalance(address,uint16,uint256,uint256,bytes)' "$NOOP" 5000 "$n" "$exp" "$sig" --rpc-url "$RPC" --account "$ACCOUNT" "${PW[@]}" >/dev/null 2>"$ERRFILE"; then
    NONCE=$n
    return 0
  fi
  return 1
}

revert_data() { grep -oE 'data: "0x[0-9a-f]+"' "$ERRFILE" 2>/dev/null | head -1 | grep -oE '0x[0-9a-f]+' || true; }
# Falls back to the raw first line rather than returning empty. A die() that
# interpolates an empty reason reads as "the call failed: " and sends the reader
# looking for a contract bug that may not exist -- the real answer the first time
# was that the schedule had drifted shut.
revert_name() {
  local r
  r=$(grep -oE '[A-Z][A-Za-z]+\(' "$ERRFILE" 2>/dev/null | grep -v '^Error($' | head -1 | tr -d '(' || true)
  [[ -n "$r" ]] && { printf '%s' "$r"; return 0; }
  r=$(grep -oE '0x[0-9a-f]{8}' "$ERRFILE" 2>/dev/null | head -1 || true)
  [[ -n "$r" ]] && { printf 'undecoded, selector %s' "$r"; return 0; }
  r=$(head -2 "$ERRFILE" 2>/dev/null | tr '
' ' ' | cut -c1-160 || true)
  printf '%s' "${r:-no output at all}"
}

expect_refusal() {
  if attempt; then die "$2 was ACCEPTED. The window did not bite."; fi
  local got; got=$(revert_name)
  [[ "$got" == "$1" ]] || die "$2 was refused with '$got', expected $1"
}

# --- 1. Baseline -----------------------------------------------------------
bold "1/9  With no window set, a rebalance lands"
attempt || die "the baseline rebalance failed: $(revert_name). Nothing below would be meaningful."
ok "accepted, nonce now $NONCE"
info "enforced=false means 24/7 -- the state every live vault is in today"

# --- 2. The calendar -------------------------------------------------------
bold "2/9  The contract's calendar agrees with one we did not write"

TS=$(now)
EXP_DOW=$(date -u -d "@$TS" +%w)
EXP_MIN=$(( 10#$(date -u -d "@$TS" +%H) * 60 + 10#$(date -u -d "@$TS" +%M) ))
info "chain time $TS -- $(date -u -d "@$TS" '+%A %H:%M UTC')"

MASK_WITHOUT_TODAY=$(( 0x7F & ~(1 << EXP_DOW) ))
send "$EXEC" 'setTradingWindow(address,uint16,uint16,uint8)' "$NOOP" 0 1439 "$MASK_WITHOUT_TODAY"

if attempt; then die "a day excluded by the weekday mask still executed"; fi
DATA=$(revert_data)
[[ -n "$DATA" ]] || die "MarketClosed carried no decodable revert data"
read -r _V GOT_MIN GOT_DOW <<<"$(cast abi-decode 'f()(address,uint256,uint256)' "0x${DATA:10}" | num | tr '\n' ' ')"

[[ "$GOT_DOW" == "$EXP_DOW" ]] || die "the contract thinks today is day $GOT_DOW; date says $EXP_DOW.
     ((timestamp / 1 days) + 4) % 7 is wrong, and every weekday mask in the
     protocol is shifted with it -- a Mon-Fri schedule would enforce Sun-Thu.
     No Solidity test can catch this: it would build its expectation from the
     same expression."
ok "dayOfWeek $GOT_DOW matches date's $(date -u -d "@$TS" '+%A')"

DELTA=$(( GOT_MIN > EXP_MIN ? GOT_MIN - EXP_MIN : EXP_MIN - GOT_MIN ))
[[ "$DELTA" -le 2 ]] || die "the contract reports minute $GOT_MIN, date says $EXP_MIN"
ok "minuteUTC $GOT_MIN matches date $EXP_MIN"

# --- 3. The weekend case ---------------------------------------------------
bold "3/9  A day outside the mask is refused"
ok "refused with MarketClosed, and the nonce is still $NONCE"
info "this IS the weekend refusal: today's bit is cleared from the mask, which is"
info "the state a Saturday is in under the Mon-Fri mask 0x3E"

# --- 4. Right day, wrong hour ----------------------------------------------
bold "4/9  The right day at the wrong hour is refused"
OPEN=$(( (EXP_MIN + 60) % 1440 ))
CLOSE=$(( (OPEN + 1) % 1440 ))
send "$EXEC" 'setTradingWindow(address,uint16,uint16,uint8)' "$NOOP" "$OPEN" "$CLOSE" 0x7F
expect_refusal MarketClosed "a rebalance an hour before the window opens"
ok "refused at minute $EXP_MIN against a window of $OPEN-$CLOSE"

# Recomputed per step rather than reused from step 2. Each of these steps is
# several transactions and the clock keeps moving; a window pinned to the minute
# step 2 observed drifts shut underneath the later ones, which is how step 7
# came to fail with no revert reason at all -- the schedule had simply closed.
now_minute() { local t; t=$(now); echo $(( (t % 86400) / 60 )); }

# --- 5. Inside the window --------------------------------------------------
bold "5/9  Inside the window it executes"
M=$(now_minute)
OPEN=$(( M > 5 ? M - 5 : 0 ))
CLOSE=$(( M + 60 > 1439 ? 1439 : M + 60 ))
send "$EXEC" 'setTradingWindow(address,uint16,uint16,uint8)' "$NOOP" "$OPEN" "$CLOSE" 0x7F
attempt || die "a rebalance inside $OPEN-$CLOSE was refused: $(revert_name)"
ok "accepted inside $OPEN-$CLOSE, nonce now $NONCE"

# --- 6. The wrapping branch ------------------------------------------------
#
# _checkTradingWindow has two comparisons, and only one of them runs for a given
# schedule:
#
#     open < close  ->  minute >= open && minute < close
#     otherwise     ->  minute >= open || minute < close
#
# The second is what a 09:30-16:00 New York session becomes once written in UTC
# across a date line, so it is the branch that matters most in production, and
# it is the one an inverted comparison would break silently.
#
# The first version of this step computed open and close from an offset that
# happened not to wrap at the hour it ran: open 785, close 875. That is the
# NORMAL branch. The step passed, said "the wrapping branch is not inverted",
# and had not executed a line of it. Hence the assertion below -- the drill now
# refuses to claim this unless the schedule it built is genuinely a wrapping one.
bold "6/9  A window that wraps midnight"
M=$(now_minute)
if [[ "$M" -ge 90 ]]; then
  OPEN=$(( M - 30 ))          # opened half an hour ago
  CLOSE=$(( M - 60 ))         # closes an hour ago TOMORROW: close < open
else
  OPEN=$(( M + 1380 ))        # late yesterday evening
  CLOSE=$(( M + 30 ))         # early this morning, still ahead of now
fi
[[ "$CLOSE" -lt "$OPEN" ]] || die "this step built open $OPEN, close $CLOSE, which does
     not wrap midnight -- it would exercise the normal branch while claiming to
     test the wrapping one. That is the bug this assertion exists for."
send "$EXEC" 'setTradingWindow(address,uint16,uint16,uint8)' "$NOOP" "$OPEN" "$CLOSE" 0x7F
info "open $OPEN, close $CLOSE at minute $M -- close < open, so this wraps"
attempt || die "a rebalance inside the wrapping window $OPEN-$CLOSE was refused: $(revert_name)"
ok "accepted, so the wrapping branch is not inverted"

# --- 7. The holiday override -----------------------------------------------
#
# The schedule is set wide open first, so the only thing that can refuse is
# closedUntil. Sharing step 6's window here would leave two possible reasons for
# a refusal and no way to tell them apart.
bold "7/9  closedUntil outranks an open schedule"
send "$EXEC" 'setTradingWindow(address,uint16,uint16,uint8)' "$NOOP" 0 1439 0x7F
UNTIL=$(( $(now) + 300 ))
send "$EXEC" 'setClosedUntil(address,uint64)' "$NOOP" "$UNTIL"
expect_refusal MarketHalted "a rebalance during a holiday closure"
ok "refused with MarketHalted although the weekly schedule says open"

send "$EXEC" 'setClosedUntil(address,uint64)' "$NOOP" 0
attempt || die "lifting closedUntil did not restore trading: $(revert_name)"
ok "and lifting it restores trading, so the closure is reversible"

# --- 8. Clearing -----------------------------------------------------------
bold "8/9  clearTradingWindow returns the target to 24/7"
send "$EXEC" 'setTradingWindow(address,uint16,uint16,uint8)' "$NOOP" 0 1439 "$MASK_WITHOUT_TODAY"
expect_refusal MarketClosed "a rebalance on an excluded day"
send "$EXEC" 'clearTradingWindow(address)' "$NOOP"
attempt || die "clearTradingWindow did not lift the restriction: $(revert_name)"
ok "cleared, and the same rebalance now lands"


# --- 9. Schedules that could never open ------------------------------------
bold "9/9  A schedule that can never match is refused at the setter"
# Matched on the SELECTOR, not the name.
#
# BadTradingWindow() takes no arguments, so its revert data is four bytes and
# nothing else. cast has no ABI to resolve that against here and prints the bare
# selector, so a check looking for the word "BadTradingWindow" fails against a
# contract that is behaving perfectly -- which is what it did on the first run.
# cast sig computes the same four bytes from the signature, so this compares
# like with like and still fails if the setter starts reverting for a different
# reason.
BAD_WINDOW_SIG=$(cast sig 'BadTradingWindow()')

refuse_config() {
  if cast send "$EXEC" 'setTradingWindow(address,uint16,uint16,uint8)' "$NOOP" "$2" "$3" "$4" --rpc-url "$RPC" --account "$ACCOUNT" "${PW[@]}" >/dev/null 2>"$ERRFILE"; then
    die "$1 was ACCEPTED, and would leave the target permanently shut"
  fi
  if grep -q 'BadTradingWindow' "$ERRFILE" || grep -qi "${BAD_WINDOW_SIG#0x}" "$ERRFILE"; then
    ok "$1 refused with BadTradingWindow"
  else
    die "$1 was refused with '$(revert_name)', expected BadTradingWindow ($BAD_WINDOW_SIG)"
  fi
}
refuse_config "an empty weekday mask" 540 960 0
refuse_config "a zero-length window" 540 540 0x7F
refuse_config "a minute past the end of a day" 540 1440 0x7F

bold "Drill passed"
echo "  A rebalance is refused outside its trading day, refused outside its"
echo "  hours, refused during a holiday closure, and accepted inside a window"
echo "  whether or not that window wraps midnight. The schedule can be lifted,"
echo "  and one that could never open cannot be set."
echo
echo "  The day and minute were checked against GNU date rather than against"
echo "  the arithmetic under test, so a shifted week would have failed here"
echo "  instead of passing everywhere."
echo
echo "  NOT shown: that any of this is switched on. Every vault on this"
echo "  deployment has enforced=false, which is 24/7. This proves the mechanism"
echo "  works, not that it is guarding anything."

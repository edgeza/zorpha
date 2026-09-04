#!/usr/bin/env bash
#
# Vesting: the cliff, the linear release, and revocation.
#
# ZorphaVesting will hold team and investor allocations. Step 4 of the token
# drill has always reported "nothing vests before a schedule exists" and stopped
# there, because the live contract has no funded schedule and inventing one would
# mean writing real people addresses and amounts into a drill. So the cliff and
# the linear release -- the two things the contract exists to enforce -- have
# never been executed on a chain.
#
# This drill funds its OWN vesting contract instead, and reaches the interesting
# moments by BACKDATING rather than by waiting. fund() permits a startTime up to
# MAX_BACKDATE (90 days) in the past, so "half way through a two-year vest" is a
# schedule created now with a start two days ago and a four-day duration. The
# arithmetic under test is identical; only the scale changes.
#
# The expected numbers are computed here from the schedule, not read back from
# the contract, so a wrong formula fails instead of agreeing with itself:
#
#     before start + cliff       -> 0
#     after                      -> total * elapsed / vestDuration   (linear FROM START)
#     elapsed >= vestDuration    -> total
#
# Note the middle line. The cliff does not restart the clock -- it gates it. A
# schedule with a 1-year cliff on a 4-year vest pays out a quarter of the
# allocation the instant the cliff passes. That is the intended design and it is
# asserted below, because reading "cliff" as "vesting begins here" is the natural
# misreading and would quietly quarter every early payout.
set -euo pipefail

ACCOUNT="${1:-}"
[[ -n "$ACCOUNT" ]] || { echo "usage: $0 <governance-keystore>" >&2; exit 1; }

RPC="${RH_TESTNET_RPC_URL:-https://rpc.testnet.chain.robinhood.com/rpc}"
WEB_ENV="../../zorpha-web/.env.local"

bold() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m+\033[0m %s\n' "$1"; }
info() { printf '    %s\n' "$1"; }
skip() { printf '  \033[33m~\033[0m %s\n' "$1"; }
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
now()  { cast block latest --field timestamp --rpc-url "$RPC"; }
env_of() { grep -E "^$1=" "$WEB_ENV" | head -1 | cut -d= -f2- || true; }
deployed_to() { MSYS_NO_PATHCONV=1 node -e 'process.stdout.write(JSON.parse(process.argv[1]).deployedTo || "")' -- "$1"; }

# 128-bit amounts overflow bash arithmetic, so every number below goes through
# BigInt. A drill that silently wrapped at 2^63 would compare two wrong numbers
# and call them equal.
bi() { MSYS_NO_PATHCONV=1 node -e 'const [a,op,b]=process.argv.slice(1);const A=BigInt(a),B=BigInt(b);
  const f={add:()=>A+B,sub:()=>A-B,mul:()=>A*B,div:()=>A/B}[op];
  process.stdout.write(f().toString())' -- "$1" "$2" "$3"; }
eq()  { [[ "$1" == "$2" ]]; }

ERRFILE=$(mktemp)
trap 'rm -f "$ERRFILE"' EXIT

[[ -f "$WEB_ENV" ]] || die "no $WEB_ENV"
ZOR=$(env_of NEXT_PUBLIC_ZOR_ADDRESS)
[[ -n "$ZOR" ]] || ZOR=$(env_of NEXT_PUBLIC_ZOR_TOKEN_ADDRESS)
[[ -n "$ZOR" ]] || die "no ZOR address in $WEB_ENV"

ACTOR=$(cast wallet address --account "$ACCOUNT" "${PW[@]}")

bold "Vesting drill"
info "ZOR    $ZOR"
info "actor  $ACTOR"

# --- 0. Fixtures -----------------------------------------------------------
#
# Two contracts, because claim() reads msg.sender and one beneficiary may hold
# only one schedule per contract (ScheduleExists). The actor has to be mid-vest
# in one of them to claim, and pre-cliff in another to be refused.
bold "0/6  Fixtures"

TOTAL=1000000000000000000000          # 1000 ZOR per schedule
BACKDATE=172800                       # start two days ago
CLIFF=86400                           # one day  -> already passed
VEST=345600                           # four days -> so elapsed/vest = 1/2

PRE_CLIFF=432000                      # five days -> NOT yet reached
PRE_VEST=864000
SHORT_CLIFF=60
SHORT_VEST=3600                       # long since elapsed -> fully vested

DUMMY_PRE=0x00000000000000000000000000000000000000C1
DUMMY_FULL=0x00000000000000000000000000000000000000F0
DUMMY_REV=0x00000000000000000000000000000000000000E0
DUMMY_NOREV=0x00000000000000000000000000000000000000A0

deploy_vesting() {
  local out
  out=$(forge create src/ZorphaVesting.sol:ZorphaVesting --rpc-url "$RPC" --account "$ACCOUNT" "${PW[@]}" --broadcast --json --constructor-args "$ZOR" "$ACTOR")
  deployed_to "$out"
}

V1=$(deploy_vesting); [[ -n "$V1" ]] || die "could not deploy the main vesting fixture"
V2=$(deploy_vesting); [[ -n "$V2" ]] || die "could not deploy the pre-cliff vesting fixture"
ok "vesting  $V1  (mid-vest, revocation)"
ok "vesting  $V2  (pre-cliff)"

BAL=$(call "$ZOR" 'balanceOf(address)(uint256)' "$ACTOR")
NEED=$(bi "$TOTAL" mul 6)
node -e 'process.exit(BigInt(process.argv[1]) >= BigInt(process.argv[2]) ? 0 : 1)' "$BAL" "$NEED" \
  || die "actor holds $BAL ZOR, needs $NEED to fund these schedules"
send "$ZOR" 'approve(address,uint256)' "$V1" "$NEED"
send "$ZOR" 'approve(address,uint256)' "$V2" "$NEED"
ok "approved $(bi "$NEED" div 1000000000000000000) ZOR across both"

START=$(bi "$(now)" sub "$BACKDATE")
info "startTime $START -- $BACKDATE seconds ago, well inside MAX_BACKDATE"

# --- 1. Schedules the setter must refuse -----------------------------------
bold "1/6  A schedule that cannot be honoured is refused"

SIGS_LENGTH=$(cast sig 'LengthMismatch()')
SIGS_ZEROADDR=$(cast sig 'ZeroAddressInput()')
SIGS_ZEROAMT=$(cast sig 'ZeroAmount()')
SIGS_ZERODUR=$(cast sig 'ZeroDuration()')
SIGS_CLIFF=$(cast sig 'CliffExceedsVest()')
SIGS_EARLY=$(cast sig 'StartTimeTooEarly()')

# Matched on the selector: every one of these errors takes no arguments, so its
# revert data is four bytes with nothing for cast to decode it against, and a
# check looking for the name would pass on any failure at all.
refuse_fund() {   # refuse_fund <desc> <selector> <bens> <amts> <cliffs> <vests> <revs> <start>
  if cast send "$V1" 'fund(address[],uint256[],uint64[],uint64[],bool[],uint64)' "$3" "$4" "$5" "$6" "$7" "$8" \
       --rpc-url "$RPC" --account "$ACCOUNT" "${PW[@]}" >/dev/null 2>"$ERRFILE"; then
    die "$1 was ACCEPTED"
  fi
  grep -qi "${2#0x}" "$ERRFILE" || die "$1 was refused, but not with the expected error ($2):
     $(head -2 "$ERRFILE" | tr '\n' ' ' | cut -c1-160)"
  ok "$1 refused"
}

refuse_fund "mismatched array lengths" "$SIGS_LENGTH" \
  "[$DUMMY_PRE,$DUMMY_FULL]" "[$TOTAL]" "[$CLIFF]" "[$VEST]" "[false]" "$START"
refuse_fund "a zero beneficiary" "$SIGS_ZEROADDR" \
  "[0x0000000000000000000000000000000000000000]" "[$TOTAL]" "[$CLIFF]" "[$VEST]" "[false]" "$START"
refuse_fund "a zero amount" "$SIGS_ZEROAMT" \
  "[$DUMMY_PRE]" "[0]" "[$CLIFF]" "[$VEST]" "[false]" "$START"
refuse_fund "a zero vest duration" "$SIGS_ZERODUR" \
  "[$DUMMY_PRE]" "[$TOTAL]" "[0]" "[0]" "[false]" "$START"
refuse_fund "a cliff longer than the vest" "$SIGS_CLIFF" \
  "[$DUMMY_PRE]" "[$TOTAL]" "[$VEST]" "[$CLIFF]" "[false]" "$START"
refuse_fund "a start backdated past MAX_BACKDATE" "$SIGS_EARLY" \
  "[$DUMMY_PRE]" "[$TOTAL]" "[$CLIFF]" "[$VEST]" "[false]" "$(bi "$(now)" sub 7862400)"
info "each of these would create a schedule that can never pay out correctly,"
info "or one already fully vested on the day it was written"

# --- 2. Fund ----------------------------------------------------------------
bold "2/6  Fund five schedules in one transaction"

send "$V1" 'fund(address[],uint256[],uint64[],uint64[],bool[],uint64)' \
  "[$ACTOR,$DUMMY_PRE,$DUMMY_FULL,$DUMMY_REV,$DUMMY_NOREV]" \
  "[$TOTAL,$TOTAL,$TOTAL,$TOTAL,$TOTAL]" \
  "[$CLIFF,$PRE_CLIFF,$SHORT_CLIFF,$CLIFF,$CLIFF]" \
  "[$VEST,$PRE_VEST,$SHORT_VEST,$VEST,$VEST]" \
  "[false,false,false,true,false]" "$START"
eq "$(call "$V1" 'beneficiaryCount()(uint256)')" 5 || die "beneficiaryCount is not 5 after funding"
ok "five schedules created, and the contract pulled $(bi "$(bi "$TOTAL" mul 5)" div 1000000000000000000) ZOR in the same call"

send "$V2" 'fund(address[],uint256[],uint64[],uint64[],bool[],uint64)' \
  "[$ACTOR]" "[$TOTAL]" "[$PRE_CLIFF]" "[$PRE_VEST]" "[false]" "$START"
ok "and one pre-cliff schedule for the actor on the second contract"

send "$V1" 'fund(address[],uint256[],uint64[],uint64[],bool[],uint64)' \
  "[$DUMMY_PRE]" "[$TOTAL]" "[$CLIFF]" "[$VEST]" "[false]" "$START" 2>"$ERRFILE" && \
  die "a SECOND schedule for the same beneficiary was accepted, which would overwrite the first" || true
grep -qi "$(cast sig 'ScheduleExists(address)' | cut -c3-)" "$ERRFILE" \
  || die "the duplicate schedule was refused, but not with ScheduleExists"
ok "a second schedule for the same beneficiary is refused with ScheduleExists"

# --- 3. The cliff -----------------------------------------------------------
bold "3/6  Before the cliff, nothing"

eq "$(call "$V1" 'claimable(address)(uint256)' "$DUMMY_PRE")" 0 \
  || die "a schedule $(bi "$PRE_CLIFF" sub "$BACKDATE") seconds short of its cliff reports something claimable"
eq "$(call "$V1" 'vestedTotal(address)(uint256)' "$DUMMY_PRE")" 0 \
  || die "vestedTotal is non-zero before the cliff"
ok "claimable and vestedTotal are both 0 with the cliff still ahead"

if cast send "$V2" 'claim()' --rpc-url "$RPC" --account "$ACCOUNT" "${PW[@]}" >/dev/null 2>"$ERRFILE"; then
  die "claim() SUCCEEDED before the cliff"
fi
grep -qi "$(cast sig 'NothingToClaim()' | cut -c3-)" "$ERRFILE" \
  || die "the pre-cliff claim was refused, but not with NothingToClaim:
     $(head -2 "$ERRFILE" | tr '\n' ' ' | cut -c1-160)"
ok "and claim() itself reverts NothingToClaim, not just a zero transfer"

# --- 4. The linear release --------------------------------------------------
bold "4/6  After the cliff, linear FROM THE START"

T=$(now)
ELAPSED=$(bi "$T" sub "$START")
CLAIMABLE=$(call "$V1" 'claimable(address)(uint256)' "$ACTOR")

# A band, not a point: the read above and the block that answers it are seconds
# apart, and this schedule accrues about $(bi "$TOTAL" div "$VEST") wei a second.
LOW=$(bi "$(bi "$TOTAL" mul "$(bi "$ELAPSED" sub 30)")" div "$VEST")
HIGH=$(bi "$(bi "$TOTAL" mul "$(bi "$ELAPSED" add 30)")" div "$VEST")
node -e 'const [v,l,h]=process.argv.slice(1).map(BigInt);process.exit(v>=l&&v<=h?0:1)' "$CLAIMABLE" "$LOW" "$HIGH" \
  || die "claimable is $CLAIMABLE, expected total*elapsed/vest which is between $LOW and $HIGH.
     elapsed $ELAPSED, vestDuration $VEST, total $TOTAL."
ok "claimable $CLAIMABLE matches total*elapsed/vest to within a block"

# The misreading this excludes. If the cliff RESTARTED the clock -- vesting from
# the cliff over the remaining duration -- the same schedule would read
# total*(elapsed-cliff)/(vest-cliff), which is a materially smaller number. The
# two are far enough apart that observing one rules out the other.
WRONG=$(bi "$(bi "$TOTAL" mul "$(bi "$ELAPSED" sub "$CLIFF")")" div "$(bi "$VEST" sub "$CLIFF")")
node -e 'const [v,w]=process.argv.slice(1).map(BigInt);const d=v>w?v-w:w-v;process.exit(d*100n>v?0:1)' "$CLAIMABLE" "$WRONG" \
  || die "claimable is indistinguishable from total*(elapsed-cliff)/(vest-cliff).
     This drill cannot tell the two readings apart with these parameters."
info "a cliff that restarted the clock would read $WRONG here -- it does not"
ok "the cliff gates the release, it does not delay its start"

# --- 5. Claim ---------------------------------------------------------------
bold "5/6  Claiming moves exactly what vested"

B0=$(call "$ZOR" 'balanceOf(address)(uint256)' "$ACTOR")
T0=$(now)
send "$V1" 'claim()'
B1=$(call "$ZOR" 'balanceOf(address)(uint256)' "$ACTOR")
GOT=$(bi "$B1" sub "$B0")

E0=$(bi "$T0" sub "$START")
LOW=$(bi "$(bi "$TOTAL" mul "$(bi "$E0" sub 30)")" div "$VEST")
HIGH=$(bi "$(bi "$TOTAL" mul "$(bi "$E0" add 60)")" div "$VEST")
node -e 'const [v,l,h]=process.argv.slice(1).map(BigInt);process.exit(v>=l&&v<=h?0:1)' "$GOT" "$LOW" "$HIGH" \
  || die "received $GOT, expected between $LOW and $HIGH"
ok "received $GOT wei, the vested amount and not the whole allocation"

# The bracket strip is load-bearing. cast annotates large numbers -- it prints
# "1000000000000000000000 [1e21]" -- so a positional read takes the annotation of
# the FIRST field as the value of the second, and then compares two unrelated
# numbers. That is how this step first reported "the schedule records [1e21]
# claimed".
sched() { cast call "$V1" 'schedules(address)(uint128,uint128,uint64,uint64,uint64,bool,bool)' "$1" --rpc-url "$RPC" | sed -E 's/\[[^]]*\]//g' | tr '\n' ' '; }
read -r S_TOTAL S_CLAIMED _REST <<<"$(sched "$ACTOR")"
eq "$S_CLAIMED" "$GOT" || die "the schedule records $S_CLAIMED claimed but $GOT was transferred"
eq "$S_TOTAL" "$TOTAL" || die "claiming changed totalAmount from $TOTAL to $S_TOTAL"
ok "claimed is $S_CLAIMED and totalAmount is untouched, so the rest still vests"

# Claimable does not go to zero and stay there -- it keeps accruing. What must
# hold is that it is now small, having just been drained.
AFTER=$(call "$V1" 'claimable(address)(uint256)' "$ACTOR")
node -e 'const [a,t,v]=process.argv.slice(1).map(BigInt);process.exit(a < (t*300n)/v ? 0 : 1)' "$AFTER" "$TOTAL" "$VEST" \
  || die "claimable is still $AFTER immediately after claiming it"
ok "claimable fell to $AFTER, which is a few seconds of fresh accrual"

# The fully vested schedule pays the lot and no more.
eq "$(call "$V1" 'claimable(address)(uint256)' "$DUMMY_FULL")" "$TOTAL" \
  || die "a schedule past its vestDuration does not report the full allocation"
eq "$(call "$V1" 'vestedTotal(address)(uint256)' "$DUMMY_FULL")" "$TOTAL" \
  || die "vestedTotal exceeds or falls short of the allocation after full vesting"
ok "a fully elapsed schedule reports exactly its allocation, never more"

# --- 6. Revocation ----------------------------------------------------------
bold "6/6  Revocation keeps what vested and returns the rest"

VESTED_BEFORE=$(call "$V1" 'vestedTotal(address)(uint256)' "$DUMMY_REV")
ADMIN0=$(call "$ZOR" 'balanceOf(address)(uint256)' "$ACTOR")
send "$V1" 'revoke(address)' "$DUMMY_REV"
ADMIN1=$(call "$ZOR" 'balanceOf(address)(uint256)' "$ACTOR")
RETURNED=$(bi "$ADMIN1" sub "$ADMIN0")

read -r R_TOTAL _R_CLAIMED _R3 _R4 _R5 _R6 R_REVOKED <<<"$(sched "$DUMMY_REV")"
eq "$R_REVOKED" true || die "the schedule is not marked revoked"

# The conservation that matters: nothing is created or destroyed. What the
# beneficiary keeps plus what the admin got back is the original allocation.
SUM=$(bi "$R_TOTAL" add "$RETURNED")
eq "$SUM" "$TOTAL" || die "the beneficiary keeps $R_TOTAL and the admin got $RETURNED,
     which is $SUM against an allocation of $TOTAL. Revocation is not conserving."
ok "beneficiary keeps $R_TOTAL, admin recovered $RETURNED, and they sum to the allocation"

node -e 'const [a,b]=process.argv.slice(1).map(BigInt);process.exit(a>=b?0:1)' "$R_TOTAL" "$VESTED_BEFORE" \
  || die "the frozen amount $R_TOTAL is below what had vested ($VESTED_BEFORE)"
ok "and what it keeps is what had already vested, not less"

if cast send "$V1" 'revoke(address)' "$DUMMY_REV" --rpc-url "$RPC" --account "$ACCOUNT" "${PW[@]}" >/dev/null 2>"$ERRFILE"; then
  die "a schedule was revoked TWICE, which would return the remainder again"
fi
grep -qi "$(cast sig 'AlreadyRevoked()' | cut -c3-)" "$ERRFILE" \
  || die "the second revoke was refused, but not with AlreadyRevoked"
ok "a second revoke is refused with AlreadyRevoked"

if cast send "$V1" 'revoke(address)' "$DUMMY_NOREV" --rpc-url "$RPC" --account "$ACCOUNT" "${PW[@]}" >/dev/null 2>"$ERRFILE"; then
  die "a NON-revocable schedule was revoked. The promise it encodes is worthless."
fi
grep -qi "$(cast sig 'NotRevocable()' | cut -c3-)" "$ERRFILE" \
  || die "revoking a non-revocable schedule was refused, but not with NotRevocable"
ok "a non-revocable schedule cannot be revoked at all"

bold "Drill passed"
echo "  A schedule pays nothing before its cliff and refuses claim() outright."
echo "  After the cliff it releases linearly FROM THE START, so the cliff is a"
echo "  gate rather than a delayed beginning -- checked against the number a"
echo "  restarted clock would have produced, which is materially different."
echo "  Claiming moves the vested amount and leaves the rest vesting. A fully"
echo "  elapsed schedule pays its allocation and no more. Revocation freezes"
echo "  what vested, returns the remainder, conserves the total, cannot be"
echo "  repeated, and cannot touch a schedule that was promised irrevocable."
echo
echo "  Run against fixtures this script deploys, on a compressed timescale"
echo "  reached by backdating rather than waiting. The live vesting contract"
echo "  still has no funded schedule: that is a governance action with real"
echo "  addresses and amounts, and this proves the machinery it will run on."

#!/usr/bin/env bash
#
# Oracle health: who is posting, how stale, and how close to going dark.
#
# A median oracle at quorum 1 is not a median -- any single updater sets the
# price alone. Raising the quorum fixes that and buys an operational obligation
# that is easy to under-appreciate, because of one line in latestRoundData:
#
#     if (r.timestamp != 0 && block.timestamp - r.timestamp <= maxStaleness) {
#         ... contributes, and updatedAt takes the OLDEST such timestamp
#
# The reported age is the age of the OLDEST contributing report, not the newest.
# So at quorum 2 the oracle is exactly as fresh as its second-slowest updater,
# and one stalled poster drags every vault to StaleOracle even though a current
# price is sitting right there. Measured on 46630: one updater at 157s, another
# at 541s, latestRoundData reporting 541s.
#
# This script is the thing you look at before that happens. It reports each
# updater individually, because the aggregate hides precisely the updater that
# is about to take the oracle down.
set -euo pipefail

RPC="${RH_TESTNET_RPC_URL:-https://rpc.testnet.chain.robinhood.com/rpc}"
WEB_ENV="../../zorpha-web/.env.local"
WARN_FRACTION="${WARN_FRACTION:-70}"    # warn once a report is this % through the window

bold() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m+\033[0m %s\n' "$1"; }
info() { printf '    %s\n' "$1"; }
warn() { printf '  \033[33m~\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31mx\033[0m %s\n' "$1"; }
die()  { printf '\n  \033[31mx %s\033[0m\n' "$1" >&2; exit 1; }

num()  { awk '{print $1}'; }
call() { cast call "$@" --rpc-url "$RPC" | num; }
env_of() { grep -E "^$1=" "$WEB_ENV" | head -1 | cut -d= -f2- || true; }

[[ -f "$WEB_ENV" ]] || die "no $WEB_ENV"
ORACLE="${1:-$(env_of NEXT_PUBLIC_ORACLE_ADDRESS)}"
[[ -n "$ORACLE" ]] || die "no oracle address given and none in $WEB_ENV"

NOW=$(cast block latest --field timestamp --rpc-url "$RPC")
QUORUM=$(call "$ORACLE" 'minQuorum()(uint256)')
COUNT=$(call "$ORACLE" 'updaterCount()(uint256)')
WINDOW=$(call "$ORACLE" 'maxStaleness()(uint256)')

bold "Oracle health"
info "oracle   $ORACLE"
info "quorum   $QUORUM of $COUNT updaters, staleness window ${WINDOW}s"

bold "Updaters"
FRESH=0
OLDEST=0
for (( i = 0; i < COUNT; i++ )); do
  U=$(call "$ORACLE" 'updaters(uint256)(address)' "$i")
  read -r _PRICE TS <<<"$(cast call "$ORACLE" 'reports(address)(int256,uint256)' "$U" --rpc-url "$RPC" | sed -E 's/\[[^]]*\]//g' | tr '\n' ' ')"
  if [[ "$TS" == "0" ]]; then
    bad "$U has never reported"
    continue
  fi
  AGE=$(( NOW - TS ))
  PCT=$(( AGE * 100 / WINDOW ))
  if (( AGE > WINDOW )); then
    bad "$U  ${AGE}s old -- OUTSIDE the ${WINDOW}s window, not contributing"
  else
    FRESH=$(( FRESH + 1 ))
    (( AGE > OLDEST )) && OLDEST=$AGE
    if (( PCT >= WARN_FRACTION )); then
      warn "$U  ${AGE}s old (${PCT}% through the window)"
    else
      ok "$U  ${AGE}s old (${PCT}%)"
    fi
  fi
done

bold "What the vaults see"
info "$FRESH fresh report(s) against a quorum of $QUORUM"
if (( FRESH < QUORUM )); then
  bad "BELOW QUORUM: latestRoundData reverts InsufficientFreshReports right now."
  info "Every priced operation on every vault reading this oracle is halted --"
  info "grossValue, previewRedeem, deposit and rebalanceTo alike."
  exit 1
fi

# The reported age is the oldest CONTRIBUTING report, which is what the vault
# compares against its own window. Read it rather than infer it.
if OUT=$(cast call "$ORACLE" 'latestRoundData()(uint80,int256,uint256,uint256,uint80)' --rpc-url "$RPC" 2>/dev/null); then
  read -r _RID ANSWER _START UPDATED _AIR <<<"$(printf '%s' "$OUT" | sed -E 's/\[[^]]*\]//g' | tr '\n' ' ')"
  REPORTED=$(( NOW - UPDATED ))
  ok "serving: answer $ANSWER, reported age ${REPORTED}s"
  if (( FRESH > QUORUM )); then
    info "note the reported age is the oldest CONTRIBUTING report, not the newest."
    info "It is ${REPORTED}s while the freshest updater is well inside that."
  fi
  HEADROOM=$(( WINDOW - OLDEST ))
  if (( HEADROOM < WINDOW / 4 )); then
    warn "only ${HEADROOM}s of headroom before the oldest contributor ages out"
  else
    ok "${HEADROOM}s of headroom before the oldest contributor ages out"
  fi
else
  bad "latestRoundData reverted despite $FRESH fresh reports -- investigate"
  exit 1
fi

bold "Structural"
if (( QUORUM < 2 )); then
  warn "quorum is $QUORUM: any single updater sets the price alone, so the"
  info "median is decorative. Mainnet deploys are refused below 2."
else
  ok "quorum $QUORUM: no single updater can move the price alone"
fi

if (( COUNT <= QUORUM )); then
  bad "updaters ($COUNT) do not exceed quorum ($QUORUM)."
  info "removeUpdater refuses while updaters == minQuorum, and minQuorum is"
  info "IMMUTABLE -- so a compromised updater key cannot be evicted at all"
  info "without redeploying this oracle and repointing every vault reading it."
else
  ok "$COUNT updaters against quorum $QUORUM, so one can be removed if a key is lost"
fi

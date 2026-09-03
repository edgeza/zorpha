#!/usr/bin/env bash
# Keep the MedianOracle fresh.
#
# WHY THIS EXISTS
#
# The oracle went stale and stayed stale, and nothing noticed. Measured on
# testnet 46630:
#
#     last report   $250.00 at ts 1788414847
#     now           1788450188          -> age 35,341s (9.8 hours)
#     maxStaleness  3600s               -> 1 hour
#     minQuorum     1     updaters      1
#
#     cast call $ORACLE 'latestRoundData()(...)'
#       -> execution reverted: InsufficientFreshReports(0, 1)
#
# `SpotVaultMinimal._oraclePrice` is deliberately fail-closed: it reverts with
# StaleOracle rather than trading on a price it cannot vouch for. That is the
# right design. The consequence is that a price nobody is posting halts the
# protocol -- every rebalance on the spot and rotation vaults reverts, and once
# a vault holds anything, so does every NAV read that depends on it.
#
# There was no reporter. Prices had been posted by hand, from drills, and the
# last drill was hours ago. That is fine for a demo and is not a protocol you
# can leave running.
#
# WHAT IT DOES
#
# Posts a price if the current one is older than REFRESH_AFTER. Designed to be
# run from cron every few minutes; it is a no-op when the price is fresh, so
# running it often costs nothing but a read.
#
# THE PRICE SOURCE IS THE OPEN QUESTION
#
# This posts PRICE_USD, which defaults to a constant. That is honest for a
# testnet whose tAAPL is a mock token nobody trades. It is NOT acceptable on
# mainnet: a self-reported constant is not an oracle, it is a number the
# operator chose, and every depositor's NAV would derive from it. Before
# mainnet this must read a real feed, and minQuorum must exceed 1 with
# independent updater keys, or the "median of independent reports" in
# MedianOracle's own documentation is describing something that does not exist.
#
# Usage:
#   ./script/oracle-keeper.sh              # post only if stale-ish
#   ./script/oracle-keeper.sh --force      # post regardless
#   ./script/oracle-keeper.sh --check      # report age and exit, never sends
#
# Cron (every 5 minutes):
#   */5 * * * * cd /path/to/contracts && ./script/oracle-keeper.sh >> /var/log/zorpha-oracle.log 2>&1

set -euo pipefail

RPC="${RH_TESTNET_RPC_URL:-https://rpc.testnet.chain.robinhood.com/rpc}"
WEB_ENV="${WEB_ENV:-../../zorpha-web/.env.local}"
GOV_ACCT="${GOV_ACCT:-zorpha-gov}"

# Post when the price is older than this. Deliberately well inside
# maxStaleness so a single failed run does not take the protocol down: at 3600s
# staleness and a 900s refresh, three consecutive failures are survivable.
REFRESH_AFTER="${REFRESH_AFTER:-900}"

# The price to post, in whole USD. Read from a real feed before mainnet.
PRICE_USD="${PRICE_USD:-250}"

MODE="post"
case "${1:-}" in
  --force) MODE="force" ;;
  --check) MODE="check" ;;
  "") ;;
  *) echo "unknown argument: $1" >&2; exit 2 ;;
esac

env_of() { grep -E "^$1=" "$WEB_ENV" | head -1 | cut -d= -f2- | tr -d '\r' || true; }
num()    { grep -oE '^-?[0-9]+' | head -1; }

ORACLE="${ORACLE_ADDRESS:-$(env_of NEXT_PUBLIC_ORACLE_ADDRESS)}"
[ -n "$ORACLE" ] || { echo "ERROR: no oracle address (set ORACLE_ADDRESS or NEXT_PUBLIC_ORACLE_ADDRESS in $WEB_ENV)" >&2; exit 1; }

STALENESS=$(cast call "$ORACLE" 'maxStaleness()(uint256)' --rpc-url "$RPC" | num)
QUORUM=$(cast call "$ORACLE" 'minQuorum()(uint256)' --rpc-url "$RPC" | num)
MINA=$(cast call "$ORACLE" 'minAnswer()(int256)' --rpc-url "$RPC" | num)
MAXA=$(cast call "$ORACLE" 'maxAnswer()(int256)' --rpc-url "$RPC" | num)
NOW=$(cast block latest --rpc-url "$RPC" --field timestamp | num)

# The newest report across all updaters. `latestRoundData` cannot be used for
# this: it REVERTS when the quorum is not fresh, which is exactly the state
# this script exists to detect and repair.
UPDATERS=$(cast call "$ORACLE" 'updaterCount()(uint256)' --rpc-url "$RPC" | num)
NEWEST=0
for ((i = 0; i < UPDATERS; i++)); do
  U=$(cast call "$ORACLE" 'updaters(uint256)(address)' "$i" --rpc-url "$RPC" | head -1)
  TS=$(cast call "$ORACLE" 'reports(address)(int256,uint64)' "$U" --rpc-url "$RPC" | sed -n 2p | num || echo 0)
  [ "${TS:-0}" -gt "$NEWEST" ] && NEWEST=$TS
done

AGE=$(( NOW - NEWEST ))
[ "$NEWEST" -eq 0 ] && AGE=-1

printf 'oracle %s  updaters=%s quorum=%s  window=%ss  age=%ss  %s\n' \
  "$ORACLE" "$UPDATERS" "$QUORUM" "$STALENESS" \
  "$([ "$AGE" -lt 0 ] && echo 'never-reported' || echo "$AGE")" \
  "$([ "$AGE" -lt 0 ] || [ "$AGE" -ge "$STALENESS" ] && echo 'STALE' || echo 'fresh')"

# A single updater against a quorum of one means one failure is an outage.
# Worth saying every run rather than only on the day it matters.
if [ "$UPDATERS" -le 1 ]; then
  echo "  warn: one updater, quorum $QUORUM -- there is no redundancy and no median to take"
fi

# The updater on testnet is the GOVERNANCE key. That is fine for posting a
# price by hand and wrong for a job that runs every five minutes: automating it
# means leaving governance's password or key readable by cron, so a routine
# task holds the credential that controls the protocol.
#
# The fix is a dedicated updater key holding ONLY UPDATER_ROLE -- worth nothing
# if stolen beyond the ability to post a price, which the quorum should be
# guarding anyway. Do this before mainnet, not after.
if [ "${WARN_GOV_UPDATER:-1}" = "1" ] && [ "$UPDATERS" -ge 1 ]; then
  U0=$(cast call "$ORACLE" 'updaters(uint256)(address)' 0 --rpc-url "$RPC" | head -1)
  echo "  note: updater 0 is $U0 -- if that is the governance key, give the keeper its own"
fi

if [ "$MODE" = "check" ]; then
  [ "$AGE" -lt 0 ] || [ "$AGE" -ge "$STALENESS" ] && exit 1
  exit 0
fi

if [ "$MODE" != "force" ] && [ "$AGE" -ge 0 ] && [ "$AGE" -lt "$REFRESH_AFTER" ]; then
  echo "  fresh enough (${AGE}s < ${REFRESH_AFTER}s), nothing to do"
  exit 0
fi

# 8 decimals, matching the oracle's own `decimals()`.
PRICE=$(( PRICE_USD * 100000000 ))
if [ "$PRICE" -lt "$MINA" ] || [ "$PRICE" -gt "$MAXA" ]; then
  echo "ERROR: price $PRICE outside the oracle's bounds [$MINA, $MAXA]" >&2
  exit 1
fi

# Signing. Three ways in, in order of preference for an unattended keeper.
#
# A keystore alone CANNOT run on cron: `cast send --account` prompts on a
# terminal that is not there. It also prompted twice per run, because
# `cast wallet address --account` is its own unlock -- so the address is no
# longer looked up here.
#
#   ORACLE_KEEPER_PASSWORD_FILE  keystore + a password file (chmod 600)
#   ORACLE_KEEPER_PRIVATE_KEY    a raw key for a dedicated updater
#   (neither)                    interactive keystore, for manual runs
echo "  posting \$${PRICE_USD}.00 ($PRICE)"
if [ -n "${ORACLE_KEEPER_PRIVATE_KEY:-}" ]; then
  cast send "$ORACLE" 'report(int256)' "$PRICE"     --rpc-url "$RPC" --private-key "$ORACLE_KEEPER_PRIVATE_KEY" >/dev/null
elif [ -n "${ORACLE_KEEPER_PASSWORD_FILE:-}" ]; then
  [ -r "$ORACLE_KEEPER_PASSWORD_FILE" ] || { echo "ERROR: cannot read $ORACLE_KEEPER_PASSWORD_FILE" >&2; exit 1; }
  cast send "$ORACLE" 'report(int256)' "$PRICE"     --rpc-url "$RPC" --account "$GOV_ACCT"     --password-file "$ORACLE_KEEPER_PASSWORD_FILE" >/dev/null
else
  [ -t 0 ] || { echo "ERROR: no terminal to prompt on, and neither ORACLE_KEEPER_PASSWORD_FILE nor ORACLE_KEEPER_PRIVATE_KEY is set. A keystore cannot be unlocked from cron." >&2; exit 1; }
  cast send "$ORACLE" 'report(int256)' "$PRICE" --rpc-url "$RPC" --account "$GOV_ACCT" >/dev/null
fi

# Prove it took, rather than trusting the send. `latestRoundData` reverting
# here would mean the report landed but the quorum still is not met.
if OUT=$(cast call "$ORACLE" 'latestRoundData()(uint80,int256,uint256,uint256,uint80)' --rpc-url "$RPC" 2>&1); then
  echo "  ok: latestRoundData answers, updatedAt=$(echo "$OUT" | sed -n 4p | num)"
else
  echo "ERROR: still not answering after the report -- $OUT" >&2
  exit 1
fi

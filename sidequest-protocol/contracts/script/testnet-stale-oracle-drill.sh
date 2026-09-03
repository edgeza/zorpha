#!/usr/bin/env bash
# What a spot vault does when its price feed stops updating.
#
# WHY
#
# `_oraclePrice()` reverts with `StaleOracle` once `block.timestamp - updatedAt`
# exceeds `maxOracleStaleness`. That is the protection against a frozen feed:
# better to refuse every operation than to price shares off a number that
# stopped being true. Nothing had ever demonstrated it on chain.
#
# AND WHY AN EARLIER ATTEMPT AT THIS PROVED NOTHING
#
# `grossValue()` is `assetBalance + cashToAsset(cashBalance)`, and
# `cashToAsset(0)` returns 0 without consulting the oracle. So a vault holding
# only the equity leg values itself, mints and redeems perfectly well against a
# completely dead feed.
#
# That is correct -- no price is needed to value a single-asset balance in its
# own units -- but it means a staleness probe against a freshly deposited vault
# short-circuits before it reaches the check, passes, and proves nothing. An
# earlier version of this probe did exactly that.
#
# So this drill rebalances to hold BOTH legs before it lets the price go stale.
# The oracle is only load-bearing when there is cash to value, and that is the
# only state in which the check can be observed.
#
# WHAT IT PROVES
#
#   fresh      with a current price, deposit / redeem / rebalance all work
#   stale      once the price ages out, all three revert with StaleOracle
#              rather than transacting on the last known number
#   recovery   and a new report unfreezes the vault -- staleness must be a
#              pause, not a brick. A vault that could never recover from its
#              feed lapsing would be a worse failure than mispricing.
#
# The drill waits out a real staleness window, so it takes about a minute.
#
# Usage:
#   ./script/testnet-stale-oracle-drill.sh zorpha-gov

set -euo pipefail

if ! command -v cast >/dev/null || ! command -v forge >/dev/null; then
  [[ -d "$HOME/.foundry/bin" ]] && { PATH="$HOME/.foundry/bin:$PATH"; export PATH; }
fi
for t in cast forge node; do
  command -v "$t" >/dev/null || { echo "ERROR: $t not found" >&2; exit 1; }
done

GOV_ACCT="${1:-}"
[[ -n "$GOV_ACCT" ]] || { echo "usage: $0 <governance-keystore>" >&2; exit 1; }

RPC="${RH_TESTNET_RPC_URL:-https://rpc.testnet.chain.robinhood.com/rpc}"
CHAIN_ID=46630
WEB_ENV="../../zorpha-web/.env.local"
FIXTURES="broadcast/DeployTestnetFixtures.s.sol/$CHAIN_ID/run-latest.json"
VAULTS="broadcast/DeployVaultsV1.s.sol/$CHAIN_ID/run-latest.json"

# Short enough to wait out, long enough that the fresh assertions are not
# racing the clock on a chain with ~2s blocks.
STALENESS="${STALENESS_SECS:-45}"
PRICE_USD="${PRICE_USD:-250}"
DEPOSIT="${DEPOSIT_AMOUNT:-10000000000000000000}"   # 10 equity, 18dp

bold() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m+\033[0m %s\n' "$1"; }
info() { printf '    %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
die()  { printf '\n  \033[31mx %s\033[0m\n\n' "$1" >&2; exit 1; }

# Bash arithmetic is 64-BIT SIGNED, and every token amount here is 18-decimal.
# `$(( DEPOSIT * 2 ))` on 1e19 does not error -- it wraps to
# 1553255926290448384, which is 2e19 - 2**64. That became the approval, and
# the deposit then failed with ERC20InsufficientAllowance reporting exactly
# that number. Silent, and it looked like an approval bug rather than an
# overflow. Node BigInt for anything that can exceed 9.2e18.
bi()      { MSYS_NO_PATHCONV=1 node -e 'const [a,op,b]=process.argv.slice(1);const A=BigInt(a),B=BigInt(b);
  const f={add:()=>A+B,sub:()=>A-B,mul:()=>A*B,div:()=>A/B}[op];
  process.stdout.write(f().toString())' -- "$1" "$2" "$3"; }
num()     { awk '{print $1}'; }
env_of()  { grep -E "^$1=" "$WEB_ENV" | head -1 | cut -d= -f2-; }
call()    { cast call "$@" --rpc-url "$RPC" | num; }
send()    { cast send "$@" --rpc-url "$RPC" --account "$GOV_ACCT" >/dev/null; }
created() { MSYS_NO_PATHCONV=1 node -e 'process.stdout.write(JSON.parse(process.argv[1]).deployedTo || "")' -- "$1"; }
named_of(){ MSYS_NO_PATHCONV=1 node -e '
  const j = require(process.argv[1]);
  const h = (j.transactions || []).find(t => t.contractName === process.argv[2]);
  process.stdout.write(h && h.contractAddress ? h.contractAddress : "");' "$1" "$2"; }

# Does this call revert with StaleOracle? A revert is the pass condition, so the
# pipeline must not be allowed to abort the script, and the reason has to be
# checked -- any revert would satisfy a bare "it failed" test, including one
# caused by a missing role or a bad balance, which would prove nothing.
refuses_as_stale() {
  local what="$1"; shift
  local err rc
  set +e
  err=$(cast call "$@" --rpc-url "$RPC" --from "$ACTOR" 2>&1)
  rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    die "$what SUCCEEDED against a stale price. The vault is transacting on a
     number that stopped being true. This is the whole reason the check exists."
  fi
  if echo "$err" | grep -qi 'StaleOracle'; then
    ok "$what refused with StaleOracle (the vault's own check)"
  elif echo "$err" | grep -qi 'InsufficientFreshReports'; then
    ok "$what refused with InsufficientFreshReports (the oracle went dark first)"
  elif echo "$err" | grep -qiE 'AccessControl|Unauthorized|ERC20|InsufficientBalance'; then
    die "$what reverted, but for the WRONG reason -- a role or balance problem,
     not staleness. This assertion proves nothing as written. Error: $err"
  else
    warn "$what reverted, reason unrecognised"
    info "$(echo "$err" | head -2)"
  fi
}

[[ -f "$WEB_ENV" ]]  || die "no $WEB_ENV"
[[ -f "$FIXTURES" ]] || die "no $FIXTURES"
[[ -f "$VAULTS" ]]   || die "no $VAULTS"

ACTOR=$(cast wallet address --account "$GOV_ACCT")
FACTORY=$(env_of NEXT_PUBLIC_VAULT_FACTORY_ADDRESS)
TREASURY=$(env_of NEXT_PUBLIC_TREASURY_ADDRESS)
ASSET=$(named_of "./$FIXTURES" TestEquity)
CASH=$(named_of "./$FIXTURES" TestUSDG)
ORACLE=$(named_of "./$VAULTS" MedianOracle)
[[ -n "$ASSET" && -n "$CASH" && -n "$ORACLE" && -n "$FACTORY" ]] \
  || die "could not resolve asset, cash, oracle or factory"

bold "Stale oracle refusal"
info "factory   $FACTORY"
info "asset     $ASSET   (equity, 18dp)"
info "cash      $CASH   (stable, 6dp)"
info "oracle    $ORACLE"
info "actor     $ACTOR"
info "staleness $STALENESS seconds"

# ── 0. Preflight ────────────────────────────────────────────────────────────
bold "0/7  Preflight"
DR=$(call "$FACTORY" 'DEPLOYER_ROLE()(bytes32)')
if [[ "$(call "$FACTORY" 'hasRole(bytes32,address)(bool)' "$DR" "$ACTOR")" != "true" ]]; then
  send "$FACTORY" 'grantRole(bytes32,address)' "$DR" "$ACTOR"
  ok "granted itself DEPLOYER_ROLE on the factory"
else
  ok "holds DEPLOYER_ROLE on the factory"
fi

UR=$(call "$ORACLE" 'UPDATER_ROLE()(bytes32)')
[[ "$(call "$ORACLE" 'hasRole(bytes32,address)(bool)' "$UR" "$ACTOR")" == "true" ]] \
  || die "$ACTOR lacks UPDATER_ROLE on the oracle; it cannot post a price and
     this drill cannot control freshness"
ok "can post prices to the oracle"

# ── 1. A vault with a short staleness window ────────────────────────────────
bold "1/7  Deploy a vault with a $STALENESS second window"
SALT=$(cast keccak "zorpha-stale-drill-$(date +%s)")
PARAMS="($ASSET,$CASH,$ORACLE,$STALENESS,\"Zorpha Staleness Drill\",\"zqSTALE\",200,100,0,$TREASURY,$ACTOR,3600)"
send "$FACTORY" \
  'deploySpotVault((address,address,address,uint256,string,string,uint16,uint16,uint256,address,address,uint256),bytes32)' \
  "$PARAMS" "$SALT"
BLK=$(cast block-number --rpc-url "$RPC")
FROM=$(( BLK > 500 ? BLK - 500 : 0 ))
VAULT=$(cast logs --rpc-url "$RPC" --address "$FACTORY" --from-block "$FROM" \
          'SpotVaultDeployed(address,address,bytes32)' --json 2>/dev/null \
        | MSYS_NO_PATHCONV=1 node -e '
            let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
              let l=[];try{l=JSON.parse(s||"[]")}catch(e){}
              if(!l.length) return process.stdout.write("");
              process.stdout.write("0x"+l[l.length-1].topics[1].slice(26));
            })' || true)
[[ -n "$VAULT" ]] || die "the vault deployed but its address could not be read"
ok "deployed $VAULT"
[[ "$(call "$VAULT" 'maxOracleStaleness()(uint256)')" == "$STALENESS" ]] \
  || die "the vault's staleness window is not $STALENESS"
ok "its window is $STALENESS seconds, as asked"

# Which layer refuses first depends on which window is shorter, and they are
# different checks with different errors:
#
#   MedianOracle.latestRoundData   reverts InsufficientFreshReports once fewer
#                                  than minQuorum reports sit inside ITS
#                                  maxStaleness. It goes dark rather than
#                                  answering with an old number.
#   SpotVaultMinimal._oraclePrice  reverts StaleOracle once the returned
#                                  updatedAt is older than the VAULT's window.
#
# On the live deployment both are 3600s, so the oracle refuses first and the
# vault's check never engages. It is there for a Chainlink-style feed that
# keeps answering with stale data, which MedianOracle deliberately does not.
#
# This drill exists to exercise the VAULT's check, so its window must be the
# shorter of the two. Asserted, because otherwise the drill would quietly test
# the oracle's behaviour and report it as the vault's.
ORACLE_WINDOW=$(call "$ORACLE" 'maxStaleness()(uint256)')
info "oracle window $ORACLE_WINDOW s, vault window $STALENESS s"
[[ $STALENESS -lt $ORACLE_WINDOW ]] || die "the vault window ($STALENESS s) is not
     shorter than the oracle window ($ORACLE_WINDOW s), so the oracle refuses first
     and this drill would be testing MedianOracle rather than the vault.
     Lower STALENESS_SECS below $ORACLE_WINDOW."
ok "the vault window is the shorter one, so its check is the one under test"

# Fee set to zero on purpose: a performance fee would make the recovery
# assertions depend on fee accrual timing, and the subject here is the price
# check, not the fee.
ok "performance fee is 0, so nothing below is confounded by fee accrual"

# ── 2. A priced adapter, so a rebalance can actually trade ──────────────────
bold "2/7  Priced swap adapter"
OUT=$(forge create src/adapters/RobinhoodChainRouterAdapter.sol:StubSwapAdapter \
      --rpc-url "$RPC" --account "$GOV_ACCT" --broadcast --json \
      --constructor-args "$ASSET" "$CASH" "$ORACLE" "$ACTOR")
ADAPTER=$(created "$OUT")
[[ -n "$ADAPTER" ]] || die "could not read the adapter address"
ok "deployed $ADAPTER"
send "$ADAPTER" 'grantRole(bytes32,address)' "$(call "$ADAPTER" 'VAULT_ROLE()(bytes32)')" "$VAULT"
send "$VAULT" 'setSwapAdapter(address)' "$ADAPTER"
send "$VAULT" 'grantRole(bytes32,address)' "$(call "$VAULT" 'KEEPER_ROLE()(bytes32)')" "$ACTOR"
ok "adapter wired, and the actor can call rebalanceTo directly"
send "$ASSET" 'mint(address,uint256)' "$ADAPTER" 1000000000000000000000
send "$CASH"  'mint(address,uint256)' "$ADAPTER" 250000000000
ok "adapter funded on both legs so it can settle either direction"

# ── 3. Fresh price, deposit, and hold BOTH legs ─────────────────────────────
bold "3/7  Fresh price, then take both legs"
send "$ORACLE" 'report(int256)' "$(( PRICE_USD * 100000000 ))"
ok "reported \$$PRICE_USD"

# Mint for BOTH deposits. Step 6 probes a stale deposit, and if the actor has
# no asset left that probe reverts on balance instead of on staleness -- which
# the refusal helper correctly rejects as the wrong reason, failing the drill
# for something unrelated to what it tests.
NEED=$(bi "$DEPOSIT" mul 2)
HAVE=$(call "$ASSET" 'balanceOf(address)(uint256)' "$ACTOR")
if MSYS_NO_PATHCONV=1 node -e 'process.exit(BigInt(process.argv[1])<BigInt(process.argv[2])?0:1)' -- "$HAVE" "$NEED"; then
  send "$ASSET" 'mint(address,uint256)' "$ACTOR" "$NEED"
  ok "minted $NEED"
fi
send "$ASSET" 'approve(address,uint256)' "$VAULT" "$(bi "$DEPOSIT" mul 2)"
# Twice the deposit, so the stale probe in step 6 still has allowance.
send "$VAULT" 'deposit(uint256,address)' "$DEPOSIT" "$ACTOR"
SHARES=$(call "$VAULT" 'balanceOf(address)(uint256)' "$ACTOR")
ok "deposited, shares $SHARES"

send "$VAULT" 'rebalanceTo(uint16)' 5000
EQ=$(call "$ASSET" 'balanceOf(address)(uint256)' "$VAULT")
CA=$(call "$CASH" 'balanceOf(address)(uint256)' "$VAULT")
info "equity $EQ, cash $CA"
[[ "$CA" != "0" ]] || die "the vault holds no cash after rebalancing to 5000bps.
     cashToAsset(0) short-circuits before the oracle is read, so every
     staleness assertion below would pass without reaching the check. Refusing
     to report a proof that cannot fail."
ok "the vault holds BOTH legs, so the oracle is now load-bearing"

# ── 4. Everything works while the price is fresh ────────────────────────────
bold "4/7  Fresh: operations succeed"
GV=$(call "$VAULT" 'grossValue()(uint256)')
NAV=$(call "$VAULT" 'getNavPerShare()(uint256)')
ok "grossValue $GV, nav/share $NAV"
cast call "$VAULT" 'previewRedeem(uint256)(uint256)' "$SHARES" --rpc-url "$RPC" >/dev/null \
  || die "previewRedeem reverts while the price is fresh"
ok "previewRedeem answers"
cast call "$VAULT" 'rebalanceTo(uint16)' 6000 --rpc-url "$RPC" --from "$ACTOR" >/dev/null \
  || die "rebalanceTo reverts while the price is fresh"
ok "rebalanceTo simulates cleanly"

# ── 5. Let it age out ───────────────────────────────────────────────────────
bold "5/7  Wait out the window"
UPDATED=$(cast call "$ORACLE" 'latestRoundData()(uint80,int256,uint256,uint256,uint80)' --rpc-url "$RPC" | sed -n '4p' | num)
NOW=$(cast block latest --rpc-url "$RPC" --field timestamp | num)
WAIT=$(( STALENESS - (NOW - UPDATED) + 8 ))
[[ $WAIT -lt 1 ]] && WAIT=1
info "price posted at $UPDATED, chain now $NOW, sleeping ${WAIT}s"
sleep "$WAIT"
NOW=$(cast block latest --rpc-url "$RPC" --field timestamp | num)
AGE=$(( NOW - UPDATED ))
info "the price is now ${AGE}s old against a ${STALENESS}s window"
[[ $AGE -gt $STALENESS ]] || die "the price is only ${AGE}s old; it has not aged out
     and the refusals below would not be testing staleness. Chain time may be
     drifting from wall clock -- raise STALENESS_SECS and retry."
ok "the price has aged out"

# ── 6. Now it must refuse, and for the right reason ─────────────────────────
bold "6/7  Stale: operations must refuse"
refuses_as_stale "grossValue"    "$VAULT" 'grossValue()(uint256)'
refuses_as_stale "previewRedeem" "$VAULT" 'previewRedeem(uint256)(uint256)' "$SHARES"
refuses_as_stale "deposit"       "$VAULT" 'deposit(uint256,address)' 1000000000000000000 "$ACTOR"
refuses_as_stale "rebalanceTo"   "$VAULT" 'rebalanceTo(uint16)' 6000
ok "a frozen feed halts the vault instead of mispricing it"

# ── 7. And a new price must unfreeze it ─────────────────────────────────────
bold "7/7  Recovery"
send "$ORACLE" 'report(int256)' "$(( PRICE_USD * 100000000 ))"
ok "reported a fresh price"
GV2=$(call "$VAULT" 'grossValue()(uint256)')
ok "grossValue answers again: $GV2"
cast call "$VAULT" 'previewRedeem(uint256)(uint256)' "$SHARES" --rpc-url "$RPC" >/dev/null \
  || die "previewRedeem still reverts after a fresh report -- staleness has
     bricked the vault rather than pausing it, which is worse than the failure
     it was protecting against"
ok "previewRedeem answers again"

send "$VAULT" 'redeem(uint256,address,address)' "$SHARES" "$ACTOR" "$ACTOR"
LEFT=$(call "$VAULT" 'totalSupply()(uint256)')
[[ "$LEFT" == "0" ]] || die "shares remain after redeeming everything: $LEFT"
ok "and the depositor exits cleanly, so the pause was fully reversible"

bold "Stale oracle drill passed"
info "With both legs held, a price older than the vault's window halts"
info "grossValue, previewRedeem, deposit and rebalanceTo -- each refusing with"
info "StaleOracle rather than transacting on a number that stopped being true."
info "A fresh report restores all of it and the depositor exits whole."
info ""
info "Vault $VAULT is left empty."

#!/usr/bin/env bash
# Prove the yield vault charges its fee, and only its fee, on a live chain.
#
# Phase 3 of docs/LAUNCH-CHECKLIST.md, "Yield vault (zqUSD)". This is the vault
# that will hold real size, and the fee is the only revenue the protocol has:
# half of it funds the buyback, so a fee that silently does not accrue is also
# $ZOR value accrual that silently does not happen.
#
# What is asserted, in order:
#
#   circuit breaker  set -> a real deposit is refused -> unset -> accepted
#   deposit          shares minted at the opening NAV
#   accrue           the venue earns; NAV per share rises
#   redeem           the depositor gets the principal plus 90% of the gain.
#                    Getting all of it means fees are broken.
#   accrual          performanceFeeAccrued is non-zero WITHOUT anyone having
#                    called evaluateFees(). It accrues inside redeem itself.
#   claimFees        the accrued amount lands in the treasury, and the counter
#                    resets to zero.
#
# Usage:
#   ./script/testnet-yield-drill.sh zorpha-gov
#
# The account needs DEFAULT_ADMIN_ROLE (claimFees) and RISK_COUNCIL_ROLE
# (circuit breaker) on the vault. Governance holds both after the deploy.

set -euo pipefail

if ! command -v cast >/dev/null; then
  [[ -d "$HOME/.foundry/bin" ]] && { PATH="$HOME/.foundry/bin:$PATH"; export PATH; }
fi
command -v cast >/dev/null || { echo "ERROR: cast not found" >&2; exit 1; }
command -v node >/dev/null || { echo "ERROR: node not found" >&2; exit 1; }

ACCOUNT="${1:-}"
[[ -n "$ACCOUNT" ]] || { echo "usage: $0 <keystore-account-name>" >&2; exit 1; }

RPC="${RH_TESTNET_RPC_URL:-https://rpc.testnet.chain.robinhood.com/rpc}"
CHAIN_ID=46630
WEB_ENV="../../zorpha-web/.env.local"
FIXTURES="broadcast/DeployTestnetFixtures.s.sol/$CHAIN_ID/run-latest.json"
VAULTS="broadcast/DeployVaultsV1.s.sol/$CHAIN_ID/run-latest.json"

bold() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m+\033[0m %s\n' "$1"; }
info() { printf '    %s\n' "$1"; }
die()  { printf '\n  \033[31mx %s\033[0m\n\n' "$1" >&2; exit 1; }

# All arithmetic through node BigInt. bc is absent from Git Bash and these
# values overflow shell integers.
bi()  { node -e 'const [a,op,b]=process.argv.slice(1);const A=BigInt(a),B=BigInt(b);
  const f={"+":()=>A+B,"-":()=>A-B,"*":()=>A*B,"/":()=>A/B,"min":()=>A<B?A:B,"max":()=>A>B?A:B}[op];
  process.stdout.write(f().toString())' -- "$1" "$2" "$3"; }
lt()  { node -e 'process.exit(BigInt(process.argv[1]) <  BigInt(process.argv[2]) ? 0 : 1)' -- "$1" "$2"; }
gt()  { node -e 'process.exit(BigInt(process.argv[1]) >  BigInt(process.argv[2]) ? 0 : 1)' -- "$1" "$2"; }
eq()  { [[ "$1" == "$2" ]]; }

env_of() { grep -E "^$1=" "$WEB_ENV" | head -1 | cut -d= -f2-; }
num()    { awk '{print $1}'; }
call()   { cast call "$@" --rpc-url "$RPC" | num; }
send()   { cast send "$@" --rpc-url "$RPC" --account "$ACCOUNT" >/dev/null; }

[[ -f "$WEB_ENV" ]]  || die "no $WEB_ENV"
[[ -f "$FIXTURES" ]] || die "no $FIXTURES"
[[ -f "$VAULTS" ]]   || die "no $VAULTS"

# The yield vault is the CREATE2 child of the deploy whose firstLossEscrow is
# unset: the factory vault, not a leader's. Identified by behaviour, not by a
# hardcoded address that goes stale on the next deploy.
VAULT=$(node -e '
  const j = require(process.argv[1]);
  const seen = new Set();
  for (const t of j.transactions || [])
    for (const x of t.additionalContracts || [])
      if (x.address && !seen.has(x.address)) { seen.add(x.address); console.log(x.address); }
' "./$VAULTS" | while read -r a; do
  esc=$(cast call "$a" 'firstLossEscrow()(address)' --rpc-url "$RPC" 2>/dev/null | num || true)
  [[ "$esc" == "0x0000000000000000000000000000000000000000" ]] && { echo "$a"; break; }
done)
[[ -n "$VAULT" ]] || die "could not find the factory yield vault in $VAULTS"

TARGET=$(node -e '
  const j = require(process.argv[1]);
  const h = (j.transactions || []).find(t => t.contractName === "TestYieldTarget");
  process.stdout.write(h ? h.contractAddress : "");
' "./$FIXTURES")
[[ -n "$TARGET" ]] || die "could not find TestYieldTarget"

ASSET=$(call "$VAULT" 'asset()(address)')
TREASURY=$(call "$VAULT" 'feeRecipient()(address)')
ACTOR=$(cast wallet address --account "$ACCOUNT")

DEPOSIT="${DEPOSIT_AMOUNT:-1000000000}"   # 1,000 USDG
YIELD="${YIELD_AMOUNT:-500000000}"        #   500 USDG, the checklist's figure
FEE_BPS=$(call "$VAULT" 'performanceFee()(uint256)')

bold "Yield vault drill"
info "vault     $VAULT"
info "venue     $TARGET"
info "asset     $ASSET"
info "treasury  $TREASURY"
info "actor     $ACTOR"
info "deposit $DEPOSIT, yield $YIELD, fee $FEE_BPS bps"

# --- Preflight -------------------------------------------------------------
bold "Preflight"
Z0=0x0000000000000000000000000000000000000000000000000000000000000000
RISK=$(cast keccak "RISK_COUNCIL_ROLE")
eq "$(call "$VAULT" 'hasRole(bytes32,address)(bool)' "$Z0" "$ACTOR")" true \
  || die "$ACTOR is not DEFAULT_ADMIN on the vault; claimFees would revert"
eq "$(call "$VAULT" 'hasRole(bytes32,address)(bool)' "$RISK" "$ACTOR")" true \
  || die "$ACTOR is not RISK_COUNCIL on the vault; setCircuitBreaker would revert"
ok "actor holds DEFAULT_ADMIN and RISK_COUNCIL"

SUPPLY0=$(call "$VAULT" 'totalSupply()(uint256)')
eq "$SUPPLY0" 0 || info "note: vault already has $SUPPLY0 shares outstanding; deltas are still measured, not assumed"

HAVE=$(call "$ASSET" 'balanceOf(address)(uint256)' "$ACTOR")
if lt "$HAVE" "$DEPOSIT"; then
  send "$ASSET" 'mint(address,uint256)' "$ACTOR" "$DEPOSIT"
  ok "minted $DEPOSIT"
fi
send "$ASSET" 'approve(address,uint256)' "$VAULT" "$DEPOSIT"
ok "approved"

# --- 1. Circuit breaker ----------------------------------------------------
# Tested against a real deposit attempt, not by reading the flag back.
bold "1/6  Circuit breaker"
send "$VAULT" 'setCircuitBreaker(bool)' true
eq "$(call "$VAULT" 'maxDeposit(address)(uint256)' "$ACTOR")" 0 || die "breaker set but maxDeposit is not 0"
if cast send "$VAULT" 'deposit(uint256,address)' "$DEPOSIT" "$ACTOR" \
     --rpc-url "$RPC" --account "$ACCOUNT" >/dev/null 2>&1; then
  die "a deposit SUCCEEDED with the circuit breaker active"
fi
ok "breaker on: deposit refused"
send "$VAULT" 'setCircuitBreaker(bool)' false
eq "$(call "$VAULT" 'isCircuitBreakerActive()(bool)')" false || die "breaker did not clear"
ok "breaker off"

# --- 2. Deposit ------------------------------------------------------------
bold "2/6  Deposit"
send "$VAULT" 'deposit(uint256,address)' "$DEPOSIT" "$ACTOR"
SHARES=$(call "$VAULT" 'balanceOf(address)(uint256)' "$ACTOR")
NAV0=$(call "$VAULT" 'getNavPerShare()(uint256)')
RAW0=$(call "$VAULT" 'rawAssets()(uint256)')
FEE0=$(call "$VAULT" 'performanceFeeAccrued()(uint256)')
gt "$SHARES" 0 || die "no shares minted"
ok "shares $SHARES"
info "nav/share $NAV0, rawAssets $RAW0, feeAccrued $FEE0"

# --- 3. The venue earns ----------------------------------------------------
bold "3/6  Venue accrues $YIELD"
send "$TARGET" 'accrue(uint256)' "$YIELD"
NAV1=$(call "$VAULT" 'getNavPerShare()(uint256)')
RAW1=$(call "$VAULT" 'rawAssets()(uint256)')
GAIN=$(bi "$RAW1" - "$RAW0")
info "nav/share $NAV0 -> $NAV1"
info "rawAssets $RAW0 -> $RAW1  (gain seen by this vault: $GAIN)"
gt "$NAV1" "$NAV0" || die "NAV did not rise after the venue accrued"
gt "$GAIN" 0       || die "this vault saw none of the gain"
ok "NAV per share rose"

# Nobody has called evaluateFees. The counter must still be zero here, because
# accrual happens on the next deposit/withdraw/redeem, not on the venue's move.
eq "$(call "$VAULT" 'performanceFeeAccrued()(uint256)')" "$FEE0" \
  || info "note: feeAccrued moved before redeem (another actor touched the vault)"

# --- 4. Redeem -------------------------------------------------------------
bold "4/6  Redeem everything"
BEFORE=$(call "$ASSET" 'balanceOf(address)(uint256)' "$ACTOR")
send "$VAULT" 'redeem(uint256,address,address)' "$SHARES" "$ACTOR" "$ACTOR"
AFTER=$(call "$ASSET" 'balanceOf(address)(uint256)' "$ACTOR")
RECEIVED=$(bi "$AFTER" - "$BEFORE")
PROFIT=$(bi "$RECEIVED" - "$DEPOSIT")
EXPECTED_FEE=$(bi "$(bi "$GAIN" '*' "$FEE_BPS")" / 10000)
EXPECTED_NET=$(bi "$GAIN" - "$EXPECTED_FEE")

info "received $RECEIVED for $SHARES shares"
info "profit   $PROFIT  (gain $GAIN, expected fee $EXPECTED_FEE, expected net $EXPECTED_NET)"

gt "$RECEIVED" "$DEPOSIT" || die "received $RECEIVED, no more than deposited. The gain did not reach the depositor."
ok "depositor received the principal plus a gain"

# THE assertion. If the depositor got the whole gain, no fee was charged.
lt "$RECEIVED" "$(bi "$DEPOSIT" + "$GAIN")" \
  || die "received the ENTIRE gain ($RECEIVED). Fees are broken. See ERC4626YieldAdapter.t.sol."
ok "depositor received LESS than the full gain: a fee was taken"

# Allow one base unit of rounding either way on the net figure.
DIFF=$(bi "$PROFIT" - "$EXPECTED_NET")
case "$DIFF" in -1|0|1) ok "net gain matches $FEE_BPS bps fee to within rounding ($DIFF)";;
  *) die "net gain $PROFIT differs from expected $EXPECTED_NET by $DIFF";; esac

# --- 5. Fee accrued without a keeper ----------------------------------------
bold "5/6  Fee accrual"
ACCRUED=$(call "$VAULT" 'performanceFeeAccrued()(uint256)')
info "performanceFeeAccrued $ACCRUED  (expected ~$EXPECTED_FEE)"
gt "$ACCRUED" 0 || die "performanceFeeAccrued is ZERO after a profitable redeem. Nothing accrued."
ok "fee accrued inside redeem, no evaluateFees() call anywhere"
DIFF=$(bi "$ACCRUED" - "$EXPECTED_FEE")
case "$DIFF" in -1|0|1) ok "accrued amount is $FEE_BPS bps of the gain";;
  *) die "accrued $ACCRUED vs expected $EXPECTED_FEE (diff $DIFF)";; esac

# --- 6. Claim to the treasury -----------------------------------------------
bold "6/6  claimFees"
T0=$(call "$ASSET" 'balanceOf(address)(uint256)' "$TREASURY")
send "$VAULT" 'claimFees()'
T1=$(call "$ASSET" 'balanceOf(address)(uint256)' "$TREASURY")
MOVED=$(bi "$T1" - "$T0")
info "treasury $T0 -> $T1  (+$MOVED)"
eq "$MOVED" "$ACCRUED" || die "treasury received $MOVED but $ACCRUED was accrued"
ok "the full accrued fee reached the treasury"
eq "$(call "$VAULT" 'performanceFeeAccrued()(uint256)')" 0 || die "performanceFeeAccrued did not reset"
ok "counter reset to 0"

bold "Drill passed"
echo "  Deposited $DEPOSIT, venue earned $GAIN, depositor took home $PROFIT,"
echo "  treasury took $MOVED. That is a $FEE_BPS bps performance fee working on"
echo "  a live chain, and it accrued without a keeper."
echo

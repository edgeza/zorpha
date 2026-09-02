#!/usr/bin/env bash
# Make the spot vault capable of actually rebalancing.
#
# As deployed it is inert, and the reasons are separate from each other:
#
#   1. The oracle holds ZERO price reports. latestRoundData() reverts with
#      InsufficientFreshReports(0, 1), so nothing can value the vault's
#      holdings. The deploy seats an updater set but never posts a first price.
#
#   2. The only account with UPDATER_ROLE is the deployer, whose private key was
#      exposed in plaintext. So the one key that can price every equity vault is
#      a key that must never be used again. See docs/BURNED-KEYS.md.
#
#   3. The vault has no deposits, so `rebalanceTo` hits
#      `if (tvl == 0) { targetWeightBps = targetBps; return; }` -- it records the
#      requested weight and returns without trading, without incrementing
#      rebalanceCount and without emitting a receipt. Correct: there is nothing
#      to trade. But it means a rebalance drill against an empty vault proves
#      only that the signature was accepted.
#
#   4. StubSwapAdapter holds nothing. It swaps 1:1 ignoring price and must be
#      pre-funded, so a rebalance that wants to trade reverts on its balance.
#
# This fixes all four so testnet-spot-drill.sh can exercise the real path.
# Everything here is testnet-only setup, not something a mainnet deploy wants:
# on mainnet the oracle updaters are a real multi-key set, the swap adapter is a
# real router, and the deposits are real money.
#
# Usage:
#   ./script/testnet-spot-setup.sh zorpha-gov
#
# The account must be DEFAULT_ADMIN on the oracle (to seat itself as an updater)
# and hold gas. Governance is both after the deploy.

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
VAULTS="broadcast/DeployVaultsV1.s.sol/$CHAIN_ID/run-latest.json"

bold() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m+\033[0m %s\n' "$1"; }
info() { printf '    %s\n' "$1"; }
die()  { printf '\n  \033[31mx %s\033[0m\n\n' "$1" >&2; exit 1; }

bi()  { MSYS_NO_PATHCONV=1 node -e 'const [a,op,b]=process.argv.slice(1);const A=BigInt(a),B=BigInt(b);
  const f={add:()=>A+B,sub:()=>A-B,mul:()=>A*B,div:()=>A/B,min:()=>A<B?A:B,max:()=>A>B?A:B}[op];
  if(!f) throw new Error("unknown op: "+op);
  process.stdout.write(f().toString())' -- "$1" "$2" "$3"; }
lt()  { MSYS_NO_PATHCONV=1 node -e 'process.exit(BigInt(process.argv[1]) < BigInt(process.argv[2]) ? 0 : 1)' -- "$1" "$2"; }
eq()  { [[ "$1" == "$2" ]]; }

env_of() { grep -E "^$1=" "$WEB_ENV" | head -1 | cut -d= -f2-; }
num()    { awk '{print $1}'; }
call()   { cast call "$@" --rpc-url "$RPC" | num; }
try()    { cast call "$@" --rpc-url "$RPC" 2>/dev/null | num || true; }
send()   { cast send "$@" --rpc-url "$RPC" --account "$ACCOUNT" >/dev/null; }

[[ -f "$WEB_ENV" ]] || die "no $WEB_ENV"
[[ -f "$VAULTS" ]]  || die "no $VAULTS"

ACTOR=$(cast wallet address --account "$ACCOUNT")

# The spot vault is the CREATE2 child with a cashAsset, and the swap adapter is
# the StubSwapAdapter in the same broadcast. Both read off the artifact rather
# than hardcoded, so a redeploy does not silently point this at stale state.
addr_of_create2_with() {
  MSYS_NO_PATHCONV=1 node -e '
    const j = require(process.argv[1]);
    const seen = new Set();
    for (const t of j.transactions || [])
      for (const x of t.additionalContracts || [])
        if (x.address && !seen.has(x.address)) { seen.add(x.address); console.log(x.address); }
  ' "./$VAULTS" | while read -r a; do
    v=$(cast call "$a" "$1" --rpc-url "$RPC" 2>/dev/null | num || true)
    [[ -n "$v" ]] && { echo "$a"; break; }
  done
}
named_of() {
  MSYS_NO_PATHCONV=1 node -e '
    const j = require(process.argv[1]);
    const h = (j.transactions || []).find(t => t.contractName === process.argv[2]);
    process.stdout.write(h && h.contractAddress ? h.contractAddress : "");
  ' "./$VAULTS" "$1"
}

VAULT=$(addr_of_create2_with 'cashAsset()(address)')
[[ -n "$VAULT" ]] || die "could not find the spot vault"
SWAP=$(named_of StubSwapAdapter)
[[ -n "$SWAP" ]] || die "could not find StubSwapAdapter"

ORACLE=$(call "$VAULT" 'oracle()(address)')
ASSET=$(call "$VAULT" 'asset()(address)')
CASH=$(call "$VAULT" 'cashAsset()(address)')

bold "Spot vault setup"
info "vault    $VAULT"
info "oracle   $ORACLE"
info "asset    $ASSET   (the equity)"
info "cash     $CASH   (the stable leg)"
info "swap     $SWAP   (stub: 1:1, must be pre-funded)"
info "actor    $ACTOR"

# ─── 1. Seat an oracle updater that is not the burned key ───────────────────
bold "1/6  Oracle updater"
U_ROLE=$(cast keccak "UPDATER_ROLE")
if eq "$(call "$ORACLE" 'hasRole(bytes32,address)(bool)' "$U_ROLE" "$ACTOR")" true; then
  ok "already an updater"
else
  Z0=0x0000000000000000000000000000000000000000000000000000000000000000
  eq "$(call "$ORACLE" 'hasRole(bytes32,address)(bool)' "$Z0" "$ACTOR")" true \
    || die "$ACTOR is not DEFAULT_ADMIN on the oracle, so it cannot seat itself"
  # addUpdater, not grantRole: the oracle keeps its own `updaters` array for
  # quorum accounting, and a bare grantRole would give the role without adding
  # to the array -- so updaterCount would not move and quorum maths would be
  # computed against a set this updater is not in.
  send "$ORACLE" 'addUpdater(address)' "$ACTOR"
  ok "seated $ACTOR as an updater"
fi
info "updaterCount $(call "$ORACLE" 'updaterCount()(uint256)'), minQuorum $(call "$ORACLE" 'minQuorum()(uint256)')"

# ─── 2. Post a price ───────────────────────────────────────────────────────
bold "2/6  Price report"
MIN=$(call "$ORACLE" 'minAnswer()(int256)')
MAX=$(call "$ORACLE" 'maxAnswer()(int256)')
DEC=$(call "$ORACLE" 'decimals()(uint8)')
UNIT=$(MSYS_NO_PATHCONV=1 node -e 'process.stdout.write((10n**BigInt(process.argv[1])).toString())' -- "$DEC")
PRICE_USD="${SPOT_PRICE_USD:-250}"
PRICE=$(bi "$PRICE_USD" mul "$UNIT")
lt "$PRICE" "$MIN" && die "price $PRICE below minAnswer $MIN"
lt "$MAX" "$PRICE" && die "price $PRICE above maxAnswer $MAX"
send "$ORACLE" 'report(int256)' "$PRICE"
ok "reported \$$PRICE_USD ($PRICE at $DEC dp)"

ROUND=$(cast call "$ORACLE" 'latestRoundData()(uint80,int256,uint256,uint256,uint80)' --rpc-url "$RPC" 2>&1 | tr '\n' ' ')
[[ "$ROUND" == *"revert"* ]] && die "latestRoundData still reverts: $ROUND"
ok "latestRoundData answers now"
info "$ROUND"

# ─── 3. Fund the swap adapter ──────────────────────────────────────────────
# It swaps 1:1 out of its own balance, so it needs both legs. This is a stub
# standing in for a router; on mainnet the router holds nothing on our behalf.
bold "3/6  Fund the stub swap adapter"
# Sized in RAW UNITS off the deposit, not in nominal token amounts.
#
# The stub "returns the same amount as the input" -- 1:1 on raw units, with no
# regard for decimals. The equity is 18dp and the stable is 6dp, so selling
# 50e18 of equity makes the stub try to pay out 50e18 raw units of a 6dp token:
# fifty trillion nominal tUSDG. Funding it with a sensible-looking 1,000 tUSDG
# (1e9 raw) is what made the first drill run revert with
# ERC20InsufficientBalance(adapter, 1e9, 5e19).
#
# So both legs get twice the deposit in raw units, which covers any rebalance
# of this vault. The nominal figure for the stable leg is absurd; that is the
# stub being a stub, and it is free to mint on testnet.
FUND_RAW="${FUND_RAW_AMOUNT:-}"
DEPOSIT="${SPOT_DEPOSIT_AMOUNT:-100000000000000000000}"      # 100 units, 18dp
[[ -n "$FUND_RAW" ]] || FUND_RAW=$(bi "$DEPOSIT" mul 2)
info "funding each leg with $FUND_RAW raw units (2x the deposit)"

for pair in "$ASSET:$FUND_RAW:equity" "$CASH:$FUND_RAW:cash"; do
  TOK="${pair%%:*}"; REST="${pair#*:}"; AMT="${REST%%:*}"; WHAT="${REST##*:}"
  HAVE=$(try "$TOK" 'balanceOf(address)(uint256)' "$SWAP")
  HAVE="${HAVE:-0}"
  if lt "$HAVE" "$AMT"; then
    send "$TOK" 'mint(address,uint256)' "$SWAP" "$AMT"
    ok "minted $AMT $WHAT into the adapter"
  else
    ok "adapter already holds $HAVE $WHAT"
  fi
done

# ─── 4. Deposit, so there is something to rebalance ────────────────────────
bold "4/6  Deposit into the vault"
# Skip if the vault is already funded. Re-running setup used to stack another
# deposit on top every time -- harmless but it grows the vault, spends gas, and
# makes the figures in the drill's output drift from run to run for no reason.
TVL_NOW=$(try "$VAULT" 'grossValue()(uint256)')
TVL_NOW="${TVL_NOW:-0}"
if lt "$TVL_NOW" "$DEPOSIT"; then
  HAVE=$(try "$ASSET" 'balanceOf(address)(uint256)' "$ACTOR")
  HAVE="${HAVE:-0}"
  if lt "$HAVE" "$DEPOSIT"; then
    send "$ASSET" 'mint(address,uint256)' "$ACTOR" "$DEPOSIT"
    ok "minted $DEPOSIT of the equity"
  fi
  send "$ASSET" 'approve(address,uint256)' "$VAULT" "$DEPOSIT"
  send "$VAULT" 'deposit(uint256,address)' "$DEPOSIT" "$ACTOR"
  ok "deposited $DEPOSIT"
else
  ok "vault already holds $TVL_NOW, no deposit needed"
fi

# ─── 5. Confirm it can now rebalance ───────────────────────────────────────
# grossValue is the figure `rebalanceTo` gates on. If it is still zero, or it
# reverts, the drill will pass its signature checks and prove nothing about
# trading.
bold "5/6  Can it rebalance?"
TVL=$(try "$VAULT" 'grossValue()(uint256)')
[[ -n "$TVL" && "$TVL" != "0" ]] \
  || die "grossValue is still ${TVL:-reverting}. rebalanceTo would take the
     tvl == 0 early return and trade nothing."
ok "grossValue $TVL"
info "totalSupply     $(call "$VAULT" 'totalSupply()(uint256)')"
info "rebalanceCount  $(call "$VAULT" 'rebalanceCount()(uint256)')"
info "targetWeightBps $(call "$VAULT" 'targetWeightBps()(uint16)')"
info "threshold       $(call "$VAULT" 'rebalanceThresholdBps()(uint16)') bps of tvl"

# ─── 6. A rate-limit target the vault cannot distort ───────────────────────
# The executor's rate limit is its own property -- it validates the window
# before calling the vault at all -- but testing it against the real vault
# entangles the assertion with oracle prices, rebalance thresholds and adapter
# liquidity. On this deployment that entanglement is fatal: one stub swap
# inflates the cash leg eleven orders of magnitude, after which every rebalance
# demands an impossible trade. So the limit gets its own no-op target.
bold "6/6  Rate-limit target"
CACHE=".noop-rebalancer-$CHAIN_ID"
if [[ -f "$CACHE" ]] && [[ -n "$(cat "$CACHE")" ]]; then
  NOOP=$(cat "$CACHE")
  CODE=$(cast code "$NOOP" --rpc-url "$RPC")
  [[ ${#CODE} -gt 2 ]] || die "cached $NOOP has no code; delete $CACHE and re-run"
  ok "reusing $NOOP"
else
  # --constructor-args would go last, but this one takes none.
  OUT=$(forge create src/testnet/TestnetFixtures.sol:NoopRebalancer         --rpc-url "$RPC" --account "$ACCOUNT" --broadcast --json)
  NOOP=$(MSYS_NO_PATHCONV=1 node -e 'process.stdout.write(JSON.parse(process.argv[1]).deployedTo || "")' -- "$OUT")
  [[ -n "$NOOP" ]] || die "could not read the deployed address"
  printf '%s' "$NOOP" > "$CACHE"
  ok "deployed $NOOP"
fi

EXEC=$(env_of NEXT_PUBLIC_STRATEGY_EXECUTOR_ADDRESS)
RL_LIMIT="${RATE_LIMIT:-4}"
CUR=$(try "$EXEC" 'dailyLimit(address)(uint256)' "$NOOP")
if [[ "${CUR:-0}" != "$RL_LIMIT" ]]; then
  send "$EXEC" 'setDailyLimit(address,uint256)' "$NOOP" "$RL_LIMIT"
  ok "dailyLimit for the noop target set to $RL_LIMIT"
else
  ok "dailyLimit already $RL_LIMIT"
fi

bold "Ready"
echo "  The oracle has a price, the adapter has both legs, and the vault holds"
echo "  $DEPOSIT of the equity. A rebalance away from the current weight will"
echo "  now trade, increment rebalanceCount and emit a receipt."
echo
echo "  Note the price is stale after $(call "$ORACLE" 'maxStaleness()(uint256)')s. Re-run step 2 if the drill"
echo "  starts failing on staleness -- that is the oracle working, not breaking."
echo

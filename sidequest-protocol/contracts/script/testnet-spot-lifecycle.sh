#!/usr/bin/env bash
# The whole spot lifecycle, twice over, on a vault that has never been broken.
#
# WHY A FRESH VAULT
#
# The spot vault deployed by DeployVaultsV1 cannot be used for this. The old
# StubSwapAdapter swapped 1:1 on RAW units, so a single trade between an 18dp
# equity and a 6dp stable left the cash leg valued eleven orders of magnitude
# too high -- grossValue went from 1e20 to 2e29. After that no rebalance and no
# redemption could settle. redeemEmergency got the depositor out, and that
# forfeited cash is now stranded in the vault with no rescue path, so a fresh
# deposit there would mint approximately zero shares. The vault is a write-off.
#
# The adapter is fixed. What has never been shown is the consequence: that the
# spot vault can be rebalanced MORE THAN ONCE and then emptied. Every earlier
# run proved a single trade and then died.
#
# WHAT IT PROVES
#
#   deposit      shares minted, the position lands in the vault
#   rebalance 1  a signed instruction trades, and the legs move as the oracle
#                price says they should -- not 1:1 on raw units
#   rebalance 2  and again, which is the step that was impossible
#   redeem       the depositor gets their capital back through the venue, which
#                is the other step that was impossible
#   conservation what came out is what went in, less the performance fee, less
#                rounding -- and the depositor is never paid more than that
#
# Usage:
#   ./script/testnet-spot-lifecycle.sh zorpha-signer zorpha-gov
#                                      ^signs         ^governance and keeper
#
# Governance must be DEFAULT_ADMIN on the factory and the oracle. It is, after
# the deploy handover.

set -euo pipefail

if ! command -v cast >/dev/null || ! command -v forge >/dev/null; then
  [[ -d "$HOME/.foundry/bin" ]] && { PATH="$HOME/.foundry/bin:$PATH"; export PATH; }
fi
for t in cast forge node; do
  command -v "$t" >/dev/null || { echo "ERROR: $t not found" >&2; exit 1; }
done

SIGNER_ACCT="${1:-}"
GOV_ACCT="${2:-}"
[[ -n "$SIGNER_ACCT" && -n "$GOV_ACCT" ]] || {
  echo "usage: $0 <signer-keystore> <governance-keystore>" >&2
  exit 1
}

RPC="${RH_TESTNET_RPC_URL:-https://rpc.testnet.chain.robinhood.com/rpc}"
CHAIN_ID=46630
WEB_ENV="../../zorpha-web/.env.local"
FIXTURES="broadcast/DeployTestnetFixtures.s.sol/$CHAIN_ID/run-latest.json"
VAULTS="broadcast/DeployVaultsV1.s.sol/$CHAIN_ID/run-latest.json"
ADAPTER_CACHE=".priced-adapter-$CHAIN_ID"
VAULT_CACHE=".spot-v2-$CHAIN_ID"

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
# `call` pipes through `num`, which takes the first whitespace-delimited field.
# That is right for numbers and addresses and silently truncates strings: it
# rendered "Zorpha HOOD Long/Flat V2" as `"Zorpha`. Strings get their own reader.
callstr() { cast call "$@" --rpc-url "$RPC" | head -1; }
try()    { cast call "$@" --rpc-url "$RPC" 2>/dev/null | num || true; }
gov()    { cast send "$@" --rpc-url "$RPC" --account "$GOV_ACCT" >/dev/null; }

[[ -f "$WEB_ENV" ]]  || die "no $WEB_ENV"
[[ -f "$FIXTURES" ]] || die "no $FIXTURES"
[[ -f "$VAULTS" ]]   || die "no $VAULTS"

ACTOR=$(cast wallet address --account "$GOV_ACCT")
SIGNER=$(cast wallet address --account "$SIGNER_ACCT")
EXEC=$(env_of NEXT_PUBLIC_STRATEGY_EXECUTOR_ADDRESS)
FACTORY=$(env_of NEXT_PUBLIC_VAULT_FACTORY_ADDRESS)
TREASURY=$(env_of NEXT_PUBLIC_TREASURY_ADDRESS)

named_of() {
  MSYS_NO_PATHCONV=1 node -e '
    const j = require(process.argv[1]);
    const h = (j.transactions || []).find(t => t.contractName === process.argv[2]);
    process.stdout.write(h && h.contractAddress ? h.contractAddress : "");
  ' "$1" "$2"
}
ASSET=$(named_of "./$FIXTURES" TestEquity)
CASH=$(named_of "./$FIXTURES" TestUSDG)
ORACLE=$(named_of "./$VAULTS" MedianOracle)
[[ -n "$ASSET" && -n "$CASH" && -n "$ORACLE" ]] || die "could not resolve asset, cash or oracle"

DEPOSIT="${SPOT_DEPOSIT:-100000000000000000000}"   # 100 equity, 18dp
PRICE_USD="${SPOT_PRICE_USD:-250}"

bold "Spot vault lifecycle"
info "factory   $FACTORY"
info "executor  $EXEC"
info "asset     $ASSET   (equity, 18dp)"
info "cash      $CASH   (stable, 6dp)"
info "oracle    $ORACLE"
info "signer    $SIGNER"
info "actor     $ACTOR"

# ─── Preflight ──────────────────────────────────────────────────────────────
bold "Preflight"
Z0=0x0000000000000000000000000000000000000000000000000000000000000000
eq "$(call "$FACTORY" 'hasRole(bytes32,address)(bool)' "$Z0" "$ACTOR")" true \
  || die "$ACTOR is not DEFAULT_ADMIN on the factory"
DEPLOYER_ROLE=$(call "$FACTORY" 'DEPLOYER_ROLE()(bytes32)')
if ! eq "$(call "$FACTORY" 'hasRole(bytes32,address)(bool)' "$DEPLOYER_ROLE" "$ACTOR")" true; then
  # The deploy handover strips DEPLOYER_ROLE from everyone but the launcher, on
  # purpose. Governance is admin so it can grant itself back.
  gov "$FACTORY" 'grantRole(bytes32,address)' "$DEPLOYER_ROLE" "$ACTOR"
  ok "granted itself DEPLOYER_ROLE on the factory"
else
  ok "already holds DEPLOYER_ROLE"
fi

[[ -n "$(try "$EXEC" 'BASKET_REBALANCE_TYPEHASH()(bytes32)')" ]] || die "the executor at $EXEC predates the basket path. Migrate first: ./script/testnet-migrate-executor.sh <governance-keystore> $SIGNER"
ok "executor has both rebalance paths"

ONCHAIN_SIGNER=$(call "$EXEC" 'authorizedSigner()(address)')
eq "${ONCHAIN_SIGNER,,}" "${SIGNER,,}" || die "executor trusts $ONCHAIN_SIGNER, not $SIGNER"
ok "executor trusts this signer"

# ─── 1. A correctly-priced adapter ──────────────────────────────────────────
bold "1/9  Priced swap adapter"
if [[ -f "$ADAPTER_CACHE" ]] && [[ -n "$(cat "$ADAPTER_CACHE")" ]]; then
  ADAPTER=$(cat "$ADAPTER_CACHE")
  CODE=$(cast code "$ADAPTER" --rpc-url "$RPC")
  [[ ${#CODE} -gt 2 ]] || die "cached adapter $ADAPTER has no code.
     Delete $ADAPTER_CACHE and re-run."
  ok "reusing $ADAPTER"
else
  OUT=$(forge create src/adapters/RobinhoodChainRouterAdapter.sol:StubSwapAdapter \
        --rpc-url "$RPC" --account "$GOV_ACCT" --broadcast --json \
        --constructor-args "$ASSET" "$CASH" "$ORACLE" "$ACTOR")
  ADAPTER=$(MSYS_NO_PATHCONV=1 node -e 'process.stdout.write(JSON.parse(process.argv[1]).deployedTo || "")' -- "$OUT")
  [[ -n "$ADAPTER" ]] || die "could not read the adapter address"
  printf '%s' "$ADAPTER" > "$ADAPTER_CACHE"
  ok "deployed $ADAPTER"
fi
# It must be the priced version, not the old 1:1 one. The old constructor took
# three arguments and had no oracle, so this is the distinguishing call.
[[ -n "$(try "$ADAPTER" 'oracle()(address)')" ]] \
  || die "this adapter has no oracle(), so it is the old 1:1 version.
     Delete $ADAPTER_CACHE and re-run to deploy the priced one."
ok "it prices off an oracle"

# ─── 2. A fresh vault ───────────────────────────────────────────────────────
bold "2/9  Deploy a fresh spot vault"
if [[ -f "$VAULT_CACHE" ]] && [[ -n "$(cat "$VAULT_CACHE")" ]]; then
  VAULT=$(cat "$VAULT_CACHE")
  ok "reusing $VAULT"
else
  SALT=0x$(openssl rand -hex 32)
  # Derived from the asset, matching DeployVaultsV1. This was hardcoded to
  # "Zorpha HOOD Long/Flat V2" / "zqHOOD2", so every run of this drill minted
  # another vault named after a company it does not hold -- the exact defect
  # fixed in the deploy script and left standing here. Fixing one call site and
  # not the other is how the name drifted in the first place.
  ASYM=$(callstr "$ASSET" 'symbol()(string)' | tr -d '"')
  PARAMS="($ASSET,$CASH,$ORACLE,3600,\"Zorpha $ASYM Long/Flat (drill)\",\"zq${ASYM}D\",200,100,2000,$TREASURY,$ACTOR,3600)"
  gov "$FACTORY" \
    'deploySpotVault((address,address,address,uint256,string,string,uint16,uint16,uint256,address,address,uint256),bytes32)' \
    "$PARAMS" "$SALT"
    # Read the address out of SpotVaultDeployed rather than recomputing the
    # CREATE2 address by hand.
    #
    # Two things went wrong here on the first run, and both are worth naming.
    # `--from-block -200` is not valid -- cast rejects it as "unexpected
    # argument". So the log read failed and node got empty input.
    #
    # And the failure was SILENT. VAR=$(pipeline) under `set -e` exits the
    # script with no message when the pipeline fails, so the run stopped dead
    # right after the deploy transaction with nothing printed at all: the
    # vault existed on chain while the script looked like it had crashed. It
    # deployed two orphan vaults before that was understood. Hence the
    # explicit capture and a check that can actually speak.
    BLK=$(cast block-number --rpc-url "$RPC")
    FROM=$(bi "$(bi "$BLK" sub 5000)" max 0)
    LOGS=$(cast logs --rpc-url "$RPC" --address "$FACTORY" --from-block "$FROM" 'SpotVaultDeployed(address,address,bytes32)' --json 2>/dev/null || true)
    VAULT=$(printf '%s' "$LOGS" | MSYS_NO_PATHCONV=1 node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const l=JSON.parse(s||"[]");if(l.length)process.stdout.write("0x"+l[l.length-1].topics[1].slice(26));}catch{}})' || true)
    [[ -n "$VAULT" ]] || die "the vault deployed, but its address could not be read.
     It exists. Find it and write the newest into $VAULT_CACHE, then re-run:
       cast logs --rpc-url \$RPC --address $FACTORY --from-block $FROM 'SpotVaultDeployed(address,address,bytes32)'"
  printf '%s' "$VAULT" > "$VAULT_CACHE"
  ok "deployed $VAULT"
fi
info "name   $(callstr "$VAULT" 'name()(string)')"
eq "$(call "$VAULT" 'totalSupply()(uint256)')" 0 || info "note: this vault already has shares outstanding"

# ─── 3. Wire it ─────────────────────────────────────────────────────────────
bold "3/9  Wire the vault, the adapter and the executor"
V_ROLE=$(call "$ADAPTER" 'VAULT_ROLE()(bytes32)')
if ! eq "$(call "$ADAPTER" 'hasRole(bytes32,address)(bool)' "$V_ROLE" "$VAULT")" true; then
  gov "$ADAPTER" 'grantRole(bytes32,address)' "$V_ROLE" "$VAULT"
  ok "adapter accepts swaps from the vault"
else
  ok "adapter already accepts the vault"
fi

CUR_ADAPTER=$(try "$VAULT" 'swapAdapter()(address)')
if ! eq "${CUR_ADAPTER,,}" "${ADAPTER,,}"; then
  # The factory's params struct has no adapter field, so a fresh vault starts
  # with swapAdapter unset and _swap reverts until this is called.
  gov "$VAULT" 'setSwapAdapter(address)' "$ADAPTER"
  ok "vault points at the priced adapter"
else
  ok "vault already points at it"
fi

K_ROLE=$(call "$VAULT" 'KEEPER_ROLE()(bytes32)')
if ! eq "$(call "$VAULT" 'hasRole(bytes32,address)(bool)' "$K_ROLE" "$EXEC")" true; then
  gov "$VAULT" 'grantRole(bytes32,address)' "$K_ROLE" "$EXEC"
  ok "vault accepts rebalances from the executor"
else
  ok "vault already accepts the executor"
fi

if eq "$(call "$EXEC" 'dailyLimit(address)(uint256)' "$VAULT")" 0; then
  gov "$EXEC" 'setDailyLimit(address,uint256)' "$VAULT" 8
  ok "rate limit set to 8, enough for this drill"
else
  ok "rate limit is $(call "$EXEC" 'dailyLimit(address)(uint256)' "$VAULT")"
fi

# ─── 4. A fresh price ───────────────────────────────────────────────────────
bold "4/9  Post a price"
U_ROLE=$(cast keccak "UPDATER_ROLE")
eq "$(call "$ORACLE" 'hasRole(bytes32,address)(bool)' "$U_ROLE" "$ACTOR")" true \
  || die "$ACTOR cannot report to the oracle. Run testnet-spot-setup.sh first."
DEC=$(call "$ORACLE" 'decimals()(uint8)')
UNIT=$(MSYS_NO_PATHCONV=1 node -e 'process.stdout.write((10n**BigInt(process.argv[1])).toString())' -- "$DEC")
gov "$ORACLE" 'report(int256)' "$(bi "$PRICE_USD" mul "$UNIT")"
ok "reported \$$PRICE_USD"
[[ -n "$(try "$VAULT" 'grossValue()(uint256)')" ]] || die "grossValue still reverts"
ok "the vault can value itself"

# ─── 5. Fund the adapter ────────────────────────────────────────────────────
# In VALUE terms now, not raw units. That is the whole difference: the old stub
# needed 50e18 raw units of a 6dp token -- fifty trillion nominal dollars -- to
# service a 50-equity sale. The priced one needs 12,500.
bold "5/9  Fund the adapter"
FUND_ASSET=$(bi "$DEPOSIT" mul 10)
FUND_CASH=$(bi "$(bi "$DEPOSIT" mul "$PRICE_USD")" div 1000000000000)
FUND_CASH=$(bi "$FUND_CASH" mul 10)
for pair in "$ASSET:$FUND_ASSET:equity" "$CASH:$FUND_CASH:cash"; do
  TOK="${pair%%:*}"; REST="${pair#*:}"; AMT="${REST%%:*}"; WHAT="${REST##*:}"
  HAVE=$(try "$TOK" 'balanceOf(address)(uint256)' "$ADAPTER"); HAVE="${HAVE:-0}"
  if lt "$HAVE" "$AMT"; then
    gov "$TOK" 'mint(address,uint256)' "$ADAPTER" "$AMT"
    ok "minted $AMT $WHAT into the adapter"
  else
    ok "adapter holds $HAVE $WHAT already"
  fi
done

# ─── Signing helpers ────────────────────────────────────────────────────────
DOMAIN=$(cast keccak "$(cast abi-encode 'f(bytes32,bytes32,bytes32,uint256,address)' \
          "$(cast keccak 'EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)')" \
          "$(cast keccak 'Zorpha Strategy Executor')" \
          "$(cast keccak '1')" \
          "$CHAIN_ID" "$EXEC")")
eq "$DOMAIN" "$(call "$EXEC" 'DOMAIN_SEPARATOR()(bytes32)')" || die "domain separator mismatch"
RTH=$(call "$EXEC" 'REBALANCE_TYPEHASH()(bytes32)')

ERRFILE=$(mktemp); trap 'rm -f "$ERRFILE"' EXIT
rebalance() {
  local weight=$1 nonce=$2 expiry sh digest sig
  expiry=$(bi "$(cast block latest --field timestamp --rpc-url "$RPC")" add 3600)
  sh=$(cast keccak "$(cast abi-encode 'f(bytes32,address,uint16,uint256,uint256)' \
        "$RTH" "$VAULT" "$weight" "$nonce" "$expiry")")
  digest=$(cast keccak "$(printf '0x1901%s%s' "${DOMAIN#0x}" "${sh#0x}")")
  sig=$(cast wallet sign --no-hash --account "$SIGNER_ACCT" "$digest")
  cast send "$EXEC" 'executeRebalance(address,uint16,uint256,uint256,bytes)' \
    "$VAULT" "$weight" "$nonce" "$expiry" "$sig" \
    --rpc-url "$RPC" --account "$GOV_ACCT" >/dev/null 2>"$ERRFILE"
}
reason() {
  local r
  r=$(grep -oE '[A-Z][A-Za-z]+\(' "$ERRFILE" 2>/dev/null | grep -v '^Error($' | head -1 | tr -d '(' || true)
  [[ -n "$r" ]] && { printf '%s' "$r"; return 0; }
  r=$(grep -oE 'Error\("[^"]*"\)' "$ERRFILE" 2>/dev/null | head -1 || true)
  [[ -n "$r" ]] && { printf '%s' "$r"; return 0; }
  printf 'reverted; see the tail below'
}
legs() {
  printf 'equity %s, cash %s, grossValue %s' \
    "$(call "$ASSET" 'balanceOf(address)(uint256)' "$VAULT")" \
    "$(call "$CASH" 'balanceOf(address)(uint256)' "$VAULT")" \
    "$(call "$VAULT" 'grossValue()(uint256)')"
}

# ─── 6. Deposit ─────────────────────────────────────────────────────────────
bold "6/9  Deposit $DEPOSIT of the equity"
HAVE=$(try "$ASSET" 'balanceOf(address)(uint256)' "$ACTOR"); HAVE="${HAVE:-0}"
lt "$HAVE" "$DEPOSIT" && gov "$ASSET" 'mint(address,uint256)' "$ACTOR" "$DEPOSIT"
gov "$ASSET" 'approve(address,uint256)' "$VAULT" "$DEPOSIT"
gov "$VAULT" 'deposit(uint256,address)' "$DEPOSIT" "$ACTOR"
SHARES=$(call "$VAULT" 'balanceOf(address)(uint256)' "$ACTOR")
ok "shares $SHARES"
info "$(legs)"
TVL0=$(call "$VAULT" 'grossValue()(uint256)')

# ─── 7. Rebalance once ──────────────────────────────────────────────────────
bold "7/9  Rebalance to 5000 bps"
N=$(bi "$(call "$EXEC" 'nonces(address)(uint256)' "$VAULT")" add 1)
rebalance 5000 "$N" || die "the first rebalance was REJECTED: $(reason)
     $(tail -2 "$ERRFILE")"
ok "traded"
info "$(legs)"
CASH1=$(call "$CASH" 'balanceOf(address)(uint256)' "$VAULT")
[[ "$CASH1" != "0" ]] || die "no cash leg after a 50% rebalance, so nothing traded"

# The cash leg must be worth about half the book, not eleven orders of
# magnitude more. This is the assertion the old adapter failed.
TVL1=$(call "$VAULT" 'grossValue()(uint256)')
DRIFT=$(bi "$(bi "$TVL1" mul 100)" div "$TVL0")
info "grossValue $TVL0 -> $TVL1 (${DRIFT}% of the original)"
lt 150 "$DRIFT" && die "grossValue grew to ${DRIFT}% of its starting value.
     A rebalance must not create value. This is the raw-units bug."
lt "$DRIFT" 50 && die "grossValue fell to ${DRIFT}% of its starting value."
ok "grossValue held within a sane band across the trade"

# ─── 8. Rebalance again ─────────────────────────────────────────────────────
# The step that was impossible. With the old adapter grossValue was already
# 2e29 by now and every subsequent trade asked for more than existed.
bold "8/9  Rebalance again, to 7000 bps"
N=$(bi "$N" add 1)
rebalance 7000 "$N" || die "the SECOND rebalance was rejected: $(reason)
     This is the step the old 1:1 adapter made impossible.
     $(tail -2 "$ERRFILE")"
ok "traded again"
info "$(legs)"
eq "$(call "$VAULT" 'rebalanceCount()(uint256)')" 2 || die "rebalanceCount is not 2"
ok "rebalanceCount 2, two receipts emitted"

TVL2=$(call "$VAULT" 'grossValue()(uint256)')
DRIFT=$(bi "$(bi "$TVL2" mul 100)" div "$TVL0")
info "grossValue now ${DRIFT}% of the original"
lt 150 "$DRIFT" && die "value created across two trades"
ok "still sane after two trades"

# ─── 9. Redeem normally ─────────────────────────────────────────────────────
# The other step that was impossible: a normal redemption has to buy the asset
# leg back through the venue.
bold "9/9  Redeem everything through the venue"
BEFORE=$(call "$ASSET" 'balanceOf(address)(uint256)' "$ACTOR")
cast send "$VAULT" 'redeem(uint256,address,address)' "$SHARES" "$ACTOR" "$ACTOR" \
  --rpc-url "$RPC" --account "$GOV_ACCT" >/dev/null 2>"$ERRFILE" \
  || die "the normal redemption was rejected: $(reason)
     This is what redeemEmergency existed to work around.
     $(tail -2 "$ERRFILE")"
AFTER=$(call "$ASSET" 'balanceOf(address)(uint256)' "$ACTOR")
RECEIVED=$(bi "$AFTER" sub "$BEFORE")
ok "received $RECEIVED of the equity"
info "$(legs)"

eq "$(call "$VAULT" 'totalSupply()(uint256)')" 0 || die "shares remain after a full redemption"
ok "position fully closed"

# Never more than was put in. A round trip through a zero-slippage venue can
# lose to rounding and the performance fee; it must not gain.
lt "$DEPOSIT" "$RECEIVED" \
  && die "received $RECEIVED for a $DEPOSIT deposit. A round trip through a
     zero-slippage venue created value, which is the 1:1 bug in another form."
ok "received no more than was deposited"

LOST=$(bi "$DEPOSIT" sub "$RECEIVED")
LOSTPCT=$(bi "$(bi "$LOST" mul 10000)" div "$DEPOSIT")
info "gave up $LOST ($((LOSTPCT / 100)).$((LOSTPCT % 100))% to fees, spread and rounding)"
lt 500 "$LOSTPCT" && die "lost ${LOSTPCT} bps on a round trip through a
     zero-slippage venue with a 200 bps rebalance threshold. Too much to be
     rounding; something is being charged twice."
ok "the round-trip cost is within what fees and rounding explain"

bold "Lifecycle passed"
echo "  Deposited $DEPOSIT, rebalanced twice, redeemed through the venue, and"
echo "  got $RECEIVED back. Two rebalances and a normal redemption are all"
echo "  steps the 1:1 adapter made impossible, so this is the first time the"
echo "  spot vault has completed a full lifecycle on chain."
echo
echo "  Vault $VAULT is left empty and reusable. Delete $VAULT_CACHE to have"
echo "  the next run deploy a new one instead."
echo

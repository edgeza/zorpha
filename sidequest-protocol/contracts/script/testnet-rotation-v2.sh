#!/usr/bin/env bash
# Redeploy the rotation vault with working arithmetic, and prove it on chain.
#
# WHY A REDEPLOY
#
# The rotation vault at 0x6cb2a47b... has a units bug that destroys most of a
# deposit. `asset()` is tokens[0] -- what a depositor pays in and is paid out in
# -- but `totalAssets()` returned `grossValue()`, which is denominated in
# `baseAsset`, a different token. No ERC-4626 conversion was overridden, so
# OpenZeppelin sized every share against a base-denominated total and then moved
# `asset()` tokens by that number. The two differ by a decimal gap AND the
# oracle price.
#
# Measured in Foundry before the fix, with no fee and no price movement:
# 10 HOOD in, 2 HOOD out. On the deployed vault the gap is wider still -- an
# 18-decimal asset against a 6-decimal base. `totalSupply` is 0, so nobody lost
# money; the first depositor would have.
#
# The vault is immutable, so it cannot be repaired. It must be replaced and
# unlisted. See docs/FINDINGS-ROTATION-UNITS.md.
#
# WHAT IT PROVES
#
#   round trip   N of asset() in, N of asset() out, exactly. This is the single
#                assertion that would have caught the bug on day one and the
#                reason nine passing tests did not: every one of them was
#                internally consistent in base units or in shares, and only a
#                deposit measured against its own redemption in ONE unit shows
#                the mismatch.
#   first entry  the high-water mark equals the price the first depositor paid,
#                not the 10**baseDecimals sentinel the constructor seeds. On
#                this vault that sentinel is ~20x below a real entry NAV, so the
#                first fee evaluation used to charge 20% of a gain nobody earned.
#   fee cap      an accrued claim can never exceed the value backing it.
#   naming       the deployed name matches the asset it actually holds. The old
#                one was "Zorpha HOOD Long/Flat Vault" holding Test Apple.
#
# Usage:
#   ./script/testnet-rotation-v2.sh zorpha-gov
#
# The account needs DEPLOYER_ROLE on the factory (to deploy) and KEEPER_ROLE on
# the new vault (granted here) to call evaluateFees.

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
VAULT_CACHE=""   # keyed on the factory once it is resolved, see below

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

# `|| true` is load-bearing under `set -euo pipefail`. grep exits 1 when it
# finds nothing, pipefail propagates that, and the assignment then kills the
# script -- BEFORE the `[[ -n "$X" ]] || die` meant to report the missing key.
# A drill died three times printing nothing at all this way, with its own
# diagnostic sitting unreachable two lines below.
env_of()  { grep -E "^$1=" "$WEB_ENV" | head -1 | cut -d= -f2- || true; }
num()     { awk '{print $1}'; }
call()    { cast call "$@" --rpc-url "$RPC" | num; }
callstr() { cast call "$@" --rpc-url "$RPC" | head -1; }
try()     { cast call "$@" --rpc-url "$RPC" 2>/dev/null | num || true; }
gov()     { cast send "$@" --rpc-url "$RPC" --account "$GOV_ACCT" >/dev/null; }

[[ -f "$WEB_ENV" ]]  || die "no $WEB_ENV"

ACTOR=$(cast wallet address --account "$GOV_ACCT")
FACTORY=$(env_of NEXT_PUBLIC_VAULT_FACTORY_ADDRESS)

# The cache is keyed on the FACTORY, not just the chain. VaultFactory compiles
# the vault bytecode into itself, so a vault is only as fixed as the factory
# that built it -- and a redeploy of the factory makes every previously cached
# vault stale in a way nothing here could see.
#
# This exact trap already fired: the drill reused a vault from the old factory,
# whose totalAssets() still returned base units, and reported "the mark is
# 250000000 but the first depositor paid 0". That reads as the equalisation fix
# failing. It was the units bug, in bytecode predating the fix, being graded as
# though it were the fix. A confusing failure on old code is worse than no
# drill, because it sends you to rewrite something that was already correct.
#
# Keying the filename on the factory means a factory redeploy orphans the cache
# and the next run deploys fresh, with no one having to remember.
VAULT_CACHE=".rotation-v2-$CHAIN_ID-$(printf '%s' "$FACTORY" | tail -c 9)"
TREASURY=$(env_of NEXT_PUBLIC_TREASURY_ADDRESS)

# The vault being replaced is the authoritative source for the basket, the
# oracles, the staleness window and the fee. Reading them off chain makes the
# replacement a like-for-like and removes every value I would otherwise have to
# guess -- the fixtures broadcast only records ONE equity token, and this basket
# has two.
OLD_VAULT="${OLD_ROTATION_VAULT:-0x6cb2a47bf911b7eed21a7b16d90c89986daa44e8}"

CASH=$(call "$OLD_VAULT" 'baseAsset()(address)') \
  || die "could not read baseAsset() from $OLD_VAULT; is that a rotation vault?"
LEN=$(call "$OLD_VAULT" 'basketLength()(uint256)')
[[ "$LEN" -ge 2 ]] || die "the old basket has $LEN tokens; RWRotationVault requires 2..5"

TOKENS=(); ORACLES=()
i=0
while [[ "$i" -lt "$LEN" ]]; do
  TOKENS+=("$(call "$OLD_VAULT" 'tokens(uint256)(address)' "$i")")
  ORACLES+=("$(call "$OLD_VAULT" 'oracles(uint256)(address)' "$i")")
  i=$((i + 1))
done
STALENESS=$(call "$OLD_VAULT" 'maxOracleStaleness()(uint256)')
FEE=$(call "$OLD_VAULT" 'performanceFee()(uint256)')

# Comma-joined for the tuple literal, and an even split across the basket.
TOKENS_CSV=$(IFS=,; echo "${TOKENS[*]}")
ORACLES_CSV=$(IFS=,; echo "${ORACLES[*]}")
EACH=$((10000 / LEN))
WEIGHTS_CSV=""
i=0
while [[ "$i" -lt "$LEN" ]]; do
  W=$EACH
  # Any remainder lands on the first leg so the weights sum to exactly 10000,
  # which the constructor requires.
  [[ "$i" -eq 0 ]] && W=$((EACH + 10000 - EACH * LEN))
  WEIGHTS_CSV="${WEIGHTS_CSV:+$WEIGHTS_CSV,}$W"
  i=$((i + 1))
done

ASSET="${TOKENS[0]}"          # tokens[0] IS asset() for this vault
ORACLE="${ORACLES[0]}"
ADEC=$(call "$ASSET" 'decimals()(uint8)')
CDEC=$(call "$CASH" 'decimals()(uint8)')
ASYM=$(callstr "$ASSET" 'symbol()(string)' | tr -d '"')
CSYM=$(callstr "$CASH" 'symbol()(string)' | tr -d '"')

bold "Rotation vault v2"
info "factory   $FACTORY"
info "replacing $OLD_VAULT"
info "basket    $LEN tokens: $TOKENS_CSV"
info "weights   $WEIGHTS_CSV"
info "asset     $ASSET   ($ASYM, ${ADEC}dp)   <- tokens[0], what a depositor pays in"
info "base      $CASH   ($CSYM, ${CDEC}dp)   <- what NAV is measured in"
info "fee       $FEE bps   staleness ${STALENESS}s"
info "actor     $ACTOR"

Z0=0x0000000000000000000000000000000000000000000000000000000000000000
DEPLOYER_ROLE=$(cast keccak "DEPLOYER_ROLE")
KEEPER_ROLE=$(cast keccak "KEEPER_ROLE")

bold "Preflight"
eq "$(call "$FACTORY" 'hasRole(bytes32,address)(bool)' "$DEPLOYER_ROLE" "$ACTOR")" true \
  || die "$ACTOR lacks DEPLOYER_ROLE on the factory; deployRotationVault would revert"
ok "holds DEPLOYER_ROLE on the factory"

# The bug needs asset and base to be DIFFERENT tokens. If a future fixture set
# made them the same the mismatch would be latent and this drill would prove
# nothing, so refuse rather than pass vacuously.
[[ "$(printf '%s' "$ASSET" | tr 'A-Z' 'a-z')" != "$(printf '%s' "$CASH" | tr 'A-Z' 'a-z')" ]] \
  || die "asset and base are the same token; the units bug would be latent and this drill vacuous"
ok "asset and base are different tokens, so the arithmetic is actually exercised"

# --- 1. Deploy -------------------------------------------------------------
bold "1/6  Deploy the fixed rotation vault"

if [[ -f "$VAULT_CACHE" ]] && [[ -n "$(cat "$VAULT_CACHE")" ]]; then
  VAULT=$(cat "$VAULT_CACHE")
  ok "reusing $VAULT"
else
  SALT=$(cast keccak "zorpha-rotation-v2-$(date +%s)")
  # Name derived from the base asset, matching DeployVaultsV1 after the naming
  # fix. A basket has no single asset to take a name from.
  NAME="Zorpha Rotation Vault ($CSYM base)"
  gov "$FACTORY" \
    'deployRotationVault((address,address[],address[],uint256,uint16[],string,string,uint256,address,address),bytes32)' \
    "($CASH,[$TOKENS_CSV],[$ORACLES_CSV],$STALENESS,[$WEIGHTS_CSV],\"$NAME\",\"zqROT2\",$FEE,$TREASURY,$ACTOR)" \
    "$SALT"

  BLK=$(cast block-number --rpc-url "$RPC")
  FROM=$(bi "$(bi "$BLK" sub 500)" max 0)
  LOGS=$(cast logs --rpc-url "$RPC" --address "$FACTORY" --from-block "$FROM" \
           'RotationVaultDeployed(address,address,bytes32)' --json 2>/dev/null || true)
  VAULT=$(printf '%s' "$LOGS" | MSYS_NO_PATHCONV=1 node -e '
    let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
      const l=JSON.parse(s||"[]");
      if(!l.length) return process.stdout.write("");
      const t=l[l.length-1].topics;
      process.stdout.write("0x"+t[1].slice(26));
    })' || true)
  [[ -n "$VAULT" ]] || die "the vault deployed, but its address could not be read.
     Recover it with:
       cast logs --rpc-url $RPC --address $FACTORY --from-block $FROM 'RotationVaultDeployed(address,address,bytes32)'
     then write it into $VAULT_CACHE and re-run."
  printf '%s' "$VAULT" > "$VAULT_CACHE"
  ok "deployed $VAULT"
fi

# Assert the bytecode under test is actually the fixed bytecode. `netValueInBase`
# was added by the units fix and does not exist before it, so a call that reverts
# is a positive identification of a pre-fix vault -- not a guess from an address
# or a filename. Cheap, and it makes a stale cache impossible to mistake for a
# failing fix.
if ! cast call "$VAULT" 'netValueInBase()(uint256)' --rpc-url "$RPC" >/dev/null 2>&1; then
  die "vault $VAULT predates the units fix -- netValueInBase() is not in its
     bytecode, so totalAssets() still returns base units. It was built by an
     older factory. Delete the cache and re-run to deploy from the current one:
       rm -f $VAULT_CACHE"
fi
ok "vault carries the units fix (netValueInBase is present)"

info "name   $(callstr "$VAULT" 'name()(string)')"
info "symbol $(callstr "$VAULT" 'symbol()(string)')"

# --- 2. The name matches the holding ---------------------------------------
bold "2/6  The name names what it holds"
VNAME=$(callstr "$VAULT" 'name()(string)' | tr -d '"')
case "$VNAME" in
  *"$CSYM"*) ok "name references $CSYM, the unit it is measured in" ;;
  *)         die "name '$VNAME' does not reference the base asset $CSYM" ;;
esac
case "$VNAME" in
  *HOOD*) die "name still says HOOD. The old vault said HOOD and held Test Apple." ;;
  *)      ok "and does not name a company it does not hold" ;;
esac

# --- 3. Post a price -------------------------------------------------------
bold "3/6  Confirm the oracle is fresh"
# MedianOracle's setter is report(int256), gated on UPDATER_ROLE. Only report if
# the actor actually holds it -- and only if the price is stale, since a fresh
# feed needs nothing and reporting into a live median for no reason is noise.
UPDATER_ROLE=$(cast keccak "UPDATER_ROLE")
# Ask the ORACLE, not the vault. grossValue() looks like the right probe and is
# not: tokenToBase returns early on a zero balance, so on a freshly deployed
# empty vault it answers 0 without ever reading a price. That check would have
# passed on a dead feed and then failed at the deposit -- the same shape as
# every other assertion that cannot fail.
FRESH=$(try "$ORACLE" 'latestRoundData()(uint80,int256,uint256,uint256,uint80)')
if [[ -z "$FRESH" ]]; then
  if eq "$(call "$ORACLE" 'hasRole(bytes32,address)(bool)' "$UPDATER_ROLE" "$ACTOR")" true; then
    gov "$ORACLE" 'report(int256)' 25000000000
    ok "reported \$250 into the median"
  else
    die "the oracle is stale and $ACTOR lacks UPDATER_ROLE, so it cannot be refreshed.
     grossValue() reverts, which means every deposit and redemption below would too.
     Grant UPDATER_ROLE from governance, or report from a seated updater, then re-run."
  fi
else
  ok "oracle is fresh; latestRoundData() answers rather than reverting"
fi
NAV_EMPTY=$(call "$VAULT" 'getNavPerShare()(uint256)')
ok "empty-vault NAV sentinel is $NAV_EMPTY"
info "constructor seeds highWaterMark to the same value: $(call "$VAULT" 'highWaterMark()(uint256)')"

# --- 4. The round trip -----------------------------------------------------
bold "4/6  Round trip: what goes in comes out"
DEPOSIT=$(MSYS_NO_PATHCONV=1 node -e 'process.stdout.write((10n * 10n**BigInt(process.argv[1])).toString())' -- "$ADEC")

HAVE=$(call "$ASSET" 'balanceOf(address)(uint256)' "$ACTOR")
if lt "$HAVE" "$DEPOSIT"; then
  gov "$ASSET" 'mint(address,uint256)' "$ACTOR" "$DEPOSIT"
  ok "minted $DEPOSIT $ASYM"
fi

BEFORE=$(call "$ASSET" 'balanceOf(address)(uint256)' "$ACTOR")
gov "$ASSET" 'approve(address,uint256)' "$VAULT" "$DEPOSIT"
gov "$VAULT" 'deposit(uint256,address)' "$DEPOSIT" "$ACTOR"
SHARES=$(call "$VAULT" 'balanceOf(address)(uint256)' "$ACTOR")
[[ "$SHARES" != "0" ]] || die "deposit minted no shares"
ok "deposited $DEPOSIT, got $SHARES shares"

MARK=$(call "$VAULT" 'highWaterMark()(uint256)')
NAV=$(call "$VAULT" 'getNavPerShare()(uint256)')
info "highWaterMark $MARK"
info "entry NAV     $NAV"
eq "$MARK" "$NAV" \
  || die "the mark is $MARK but the first depositor paid $NAV.
     Before the fix the mark stayed at the $NAV_EMPTY sentinel, so the first fee
     evaluation charged 20% of the gap -- a gain nobody earned."
ok "the mark equals the price the first depositor actually paid"

gov "$VAULT" 'redeem(uint256,address,address)' "$SHARES" "$ACTOR" "$ACTOR"
AFTER=$(call "$ASSET" 'balanceOf(address)(uint256)' "$ACTOR")

info "in  $DEPOSIT"
info "out $(bi "$AFTER" sub "$(bi "$BEFORE" sub "$DEPOSIT")")"
RETURNED=$(bi "$AFTER" sub "$(bi "$BEFORE" sub "$DEPOSIT")")
eq "$RETURNED" "$DEPOSIT" || die "put in $DEPOSIT and got back $RETURNED.
     This is the bug: the old vault returned 2 for every 10 deposited, because
     shares were sized against a ${CDEC}dp total and paid out in a ${ADEC}dp token."
ok "exactly what went in came back out"
eq "$(call "$VAULT" 'totalSupply()(uint256)')" 0 || die "shares remain after a full redemption"
ok "and every share was burned"

# --- 5. The fee claim can never exceed its backing -------------------------
bold "5/6  The fee claim is bounded by what backs it"
ACCRUED=$(call "$VAULT" 'performanceFeeAccrued()(uint256)')
GROSS=$(call "$VAULT" 'grossValue()(uint256)')
info "accrued $ACCRUED   backing $GROSS"
lt "$GROSS" "$ACCRUED" && die "the claim exceeds its backing; _reconcileFeeClaimWhenEmpty did not fire"
ok "claim never exceeds the value behind it"

# --- 6. Nothing stranded ---------------------------------------------------
bold "6/6  Nothing left owned by nobody"
RESID_A=$(call "$ASSET" 'balanceOf(address)(uint256)' "$VAULT")
RESID_C=$(call "$CASH"  'balanceOf(address)(uint256)' "$VAULT")
info "$ASYM residue $RESID_A"
info "$CSYM residue $RESID_C"
ok "recorded; a residue here would price the next depositor off a balance nobody owns"

bold "Rotation vault v2 passed"
info "Vault $VAULT"
info ""
info "The deposit-to-redemption round trip is the assertion nine passing tests"
info "did not make. It is now made here and in Foundry, on all three vaults."
info ""
info "NEXT: unlist the old vault 0x6cb2a47bf911b7eed21a7b16d90c89986daa44e8 from"
info "the portal, and point NEXT_PUBLIC_ROTATION_VAULT_ADDRESS at $VAULT."
info "Delete $VAULT_CACHE to deploy a fresh one instead of reusing this."

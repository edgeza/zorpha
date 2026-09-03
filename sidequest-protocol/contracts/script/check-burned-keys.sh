#!/usr/bin/env bash
# Fail if a key whose private key has been exposed holds power on chain.
#
# Two keys have had their private key pasted in plaintext during development.
# Both are still in daily use on testnet, which is fine -- nothing of value
# sits behind them. The risk is that one of them silently carries a role onto
# mainnet, because the deploy scripts read whatever key the shell hands them and
# have no opinion about its history.
#
# So this asks the chain rather than trusting a runbook: for every address in
# docs/BURNED-KEYS.md, does it hold any role, ownership or signing authority on
# the deployment in ../../zorpha-web/.env.local?
#
# Usage:
#   ./script/check-burned-keys.sh                 # checks the configured chain
#   CHAIN_ID=4663 ./script/check-burned-keys.sh   # explicit
#
# Exits non-zero if anything is found. Read-only: no keys, no transactions.

set -euo pipefail

if ! command -v cast >/dev/null; then
  [[ -d "$HOME/.foundry/bin" ]] && { PATH="$HOME/.foundry/bin:$PATH"; export PATH; }
fi
command -v cast >/dev/null || { echo "ERROR: cast not found" >&2; exit 1; }

RPC="${RH_TESTNET_RPC_URL:-https://rpc.testnet.chain.robinhood.com/rpc}"
WEB_ENV="../../zorpha-web/.env.local"
MAINNET=4663

# Keep in step with docs/BURNED-KEYS.md. Deliberately hardcoded rather than
# parsed out of the markdown: a checker that silently finds no addresses
# because a table's formatting changed is worse than no checker.
BURNED=(
  "0xB4a7C2DeebB5EaDC34e120bC8a5708508DC17f4b:deployer, and authorizedSigner until rotated"
  "0x5EC41DBe5Ca00cB00B896570c5Ff8fFc274cB5F6:manager signer (zorpha-signer)"
)

bold() { printf '\n\033[1m%s\033[0m\n' "$1"; }
bad()  { printf '  \033[31mFOUND\033[0m  %s\n' "$1"; }
ok()   { printf '  \033[32mclear\033[0m  %s\n' "$1"; }
die()  { printf '\n  \033[31mx %s\033[0m\n\n' "$1" >&2; exit 1; }

[[ -f "$WEB_ENV" ]] || die "no $WEB_ENV"
# `|| true` is load-bearing under `set -euo pipefail`. grep exits 1 when it
# finds nothing, pipefail propagates that, and the assignment then kills the
# script -- BEFORE the `[[ -n "$X" ]] || die` meant to report the missing key.
# A drill died three times printing nothing at all this way, with its own
# diagnostic sitting unreachable two lines below.
env_of() { grep -E "^$1=" "$WEB_ENV" | head -1 | cut -d= -f2- || true; }
num()    { awk '{print $1}'; }
# A revert means the contract does not have that accessor, which is not a
# finding. Only a definite "true" is.
try()    { cast call "$@" --rpc-url "$RPC" 2>/dev/null | num || true; }

CHAIN_ON_WIRE=$(cast chain-id --rpc-url "$RPC")
bold "Burned-key audit against chain $CHAIN_ON_WIRE"
if [[ "$CHAIN_ON_WIRE" == "$MAINNET" ]]; then
  echo "  MAINNET. Any finding below is a launch blocker."
else
  echo "  Testnet. Findings here are expected and harmless -- these keys run"
  echo "  the testnet deployment. This run is a rehearsal of the mainnet gate."
fi

ZERO=0x0000000000000000000000000000000000000000000000000000000000000000
FINDINGS=0

# Role names, read out of the contracts rather than listed here.
#
# The hand-written version of this list was wrong twice over: it invented
# ORACLE_UPDATER_ROLE, which does not exist -- the real name is UPDATER_ROLE --
# and it omitted SWEEPER_ROLE, which is what gates sweeping the airdrop. So the
# phantom check reported an ordinary deploy-time grant as a finding, and the
# burned-key check would have called a key clear while it held the sweeper role.
#
# A list of things the code already declares will drift from the code, and the
# drift shows up as false findings, which is the fastest way to make a check
# worth ignoring. Every role here is a keccak256("NAME") literal in src/, so
# read them from there.
mapfile -t ROLE_NAMES < <(
  grep -rhoE 'keccak256\("[A-Z_]+"\)' src     | sed -E 's/^keccak256\("//; s/"\)$//'     | sort -u
)

# TimelockController's roles come from OpenZeppelin rather than a literal in
# src/, so they are the one part that must still be named.
ROLE_NAMES+=(PROPOSER_ROLE EXECUTOR_ROLE CANCELLER_ROLE TIMELOCK_ADMIN_ROLE)

[[ ${#ROLE_NAMES[@]} -gt 4 ]]   || die "no role declarations found in src/ -- the grep is broken, not the chain"

# hasRole against a contract that is not an AccessControl reverts, which try()
# swallows, so a role that does not exist on a given contract is simply silent.
ROLES=("DEFAULT_ADMIN:$ZERO")
for nm in "${ROLE_NAMES[@]}"; do
  ROLES+=("$nm:$(cast keccak "$nm")")
done

# Every contract this deployment created, from three sources unioned, because
# each one alone is incomplete and the gaps are not the same gaps.
#
# This list used to be eleven hand-written NEXT_PUBLIC_* names. It omitted the
# MedianOracle, both adapters and all three vaults -- and the oracle is where
# UPDATER_ROLE lives, which on a minQuorum-of-1 median is total control of every
# price the protocol reads. The burned deployer key holds UPDATER_ROLE on testnet
# right now, and this gate reported "2 findings" without mentioning it.
#
# That is the third time a hand-maintained list in this file has silently covered
# less than it claimed. script/broadcast-contracts.js already solved exactly this
# for contract verification -- its own header says "the oracle, the two adapters
# and the three vaults were all deployed and none of them were ever verified,
# because nobody added a line for them" -- and the insight was not carried over
# to the security gate. It is now.
#
#   1. broadcast artifacts   everything a deploy script created, named or not
#   2. zorpha-web/.env.local anything wired up AFTER a deploy. The executor was
#                            migrated, so the live one appears here and not in
#                            any broadcast.
#   3. the factory's events  the vaults, which are CREATE2 children
#
# A gate that checks a subset it does not disclose is worse than no gate: it
# returns "clear" and means "clear among the ones I happened to look at".
declare -a CONTRACTS=()
seen_addrs=""

add_contract() {
  local label="$1" addr="$2"
  [[ -n "$addr" && "$addr" != "$ZERO_ADDR" ]] || return 0
  local lower
  lower=$(printf '%s' "$addr" | tr 'A-Z' 'a-z')
  case "$seen_addrs" in *"|$lower|"*) return 0 ;; esac
  seen_addrs="${seen_addrs}|$lower|"
  CONTRACTS+=("$label:$addr")
}

ZERO_ADDR=0x0000000000000000000000000000000000000000

# 1. Broadcast artifacts.
for f in broadcast/*.s.sol/"$CHAIN_ON_WIRE"/run-latest.json; do
  [[ -f "$f" ]] || continue
  while read -r addr src; do
    [[ -n "$addr" ]] || continue
    add_contract "${src##*:}" "$addr"
  done < <(MSYS_NO_PATHCONV=1 node script/broadcast-contracts.js "$f" 2>/dev/null | awk '{print $1, $2}')
done

# 2. Anything the front end is pointed at, which includes post-deploy rewires.
while read -r key; do
  add_contract "${key#NEXT_PUBLIC_}" "$(env_of "$key")"
done < <(grep -oE '^NEXT_PUBLIC_[A-Z_0-9]*ADDRESS' "$WEB_ENV" | sort -u)

# 3. The vaults, which the factory creates by CREATE2 and which therefore carry
#    no contractName in any artifact.
FACTORY_ADDR=$(env_of NEXT_PUBLIC_VAULT_FACTORY_ADDRESS)
if [[ -n "$FACTORY_ADDR" ]]; then
  HEAD_BLK=$(cast block-number --rpc-url "$RPC" 2>/dev/null || echo "")
  if [[ -n "$HEAD_BLK" ]]; then
    for ev in SpotVaultDeployed RotationVaultDeployed YieldVaultDeployed; do
      while read -r v; do
        add_contract "Vault(${ev%VaultDeployed})" "$v"
      done < <(cast logs --rpc-url "$RPC" --address "$FACTORY_ADDR" \
                 --from-block 0 "${ev}(address,address,bytes32)" --json 2>/dev/null \
               | MSYS_NO_PATHCONV=1 node -e '
                   let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
                     let l=[];try{l=JSON.parse(s||"[]")}catch(e){}
                     for(const e of l) if(e.topics&&e.topics[1])
                       console.log("0x"+e.topics[1].slice(26));
                   })' || true)
    done
  fi
fi

[[ ${#CONTRACTS[@]} -gt 5 ]] || die "only ${#CONTRACTS[@]} contracts discovered.
     Expected the token layer, the vault layer and the vaults. Either the
     broadcast artifacts are missing for chain $CHAIN_ON_WIRE or the discovery is
     broken -- and a gate that checks almost nothing must fail loudly rather
     than report clear."
info_line=$(printf '%s' "checking ${#CONTRACTS[@]} contracts")
printf '  %s\n' "$info_line"


for entry in "${BURNED[@]}"; do
  ADDR="${entry%%:*}"; WAS="${entry##*:}"
  bold "$ADDR"
  echo "  was: $WAS"
  HITS=0

  for c in "${CONTRACTS[@]}"; do
    # Entries are "Label:0xADDRESS". They used to be "Label:ENV_VAR_NAME" and
    # this line called env_of on the second half; after discovery started
    # yielding addresses directly, that lookup returned empty for all 27 and
    # every contract was silently skipped -- the audit printed a key header and
    # no findings, which reads exactly like a clean result.
    CNAME="${c%%:*}"; CADDR="${c##*:}"
    if [[ -z "$CADDR" || "$CADDR" == "$ZERO_ADDR" ]]; then
      continue
    fi

    for r in "${ROLES[@]}"; do
      RNAME="${r%%:*}"; RHASH="${r##*:}"
      if [[ "$(try "$CADDR" 'hasRole(bytes32,address)(bool)' "$RHASH" "$ADDR")" == "true" ]]; then
        bad "$CNAME $CADDR holds $RNAME"
        HITS=$((HITS + 1))
      fi
    done

    # Ownable and Ownable2Step, which are not roles.
    for fn in 'owner()(address)' 'pendingOwner()(address)'; do
      GOT=$(try "$CADDR" "$fn")
      if [[ -n "$GOT" ]] && [[ "${GOT,,}" == "${ADDR,,}" ]]; then
        bad "$CNAME $CADDR ${fn%%(*} is this address"
        HITS=$((HITS + 1))
      fi
    done
  done

  # The signing authority, which is neither a role nor ownership.
  EXEC=$(env_of NEXT_PUBLIC_STRATEGY_EXECUTOR_ADDRESS)
  if [[ -n "$EXEC" ]]; then
    SIGNER=$(try "$EXEC" 'authorizedSigner()(address)')
    if [[ -n "$SIGNER" ]] && [[ "${SIGNER,,}" == "${ADDR,,}" ]]; then
      bad "Executor authorizedSigner is this address -- it can sign rebalances"
      HITS=$((HITS + 1))
    fi
  fi

  BAL=$(cast balance "$ADDR" --rpc-url "$RPC")
  ZOR=$(env_of NEXT_PUBLIC_ZOR_ADDRESS)
  ZBAL=$(try "$ZOR" 'balanceOf(address)(uint256)' "$ADDR")
  [[ "$BAL" != "0" ]] && echo "  note: holds $(cast to-unit "$BAL" ether) ETH of gas"
  [[ -n "$ZBAL" && "$ZBAL" != "0" ]] && bad "holds $(cast to-unit "$ZBAL" ether) ZOR" && HITS=$((HITS + 1))

  [[ "$HITS" == "0" ]] && ok "no roles, no ownership, no signing authority, no ZOR"
  FINDINGS=$((FINDINGS + HITS))
done

bold "Result"
if [[ "$FINDINGS" == "0" ]]; then
  echo "  $FINDINGS findings. No exposed key holds power on chain $CHAIN_ON_WIRE."
  exit 0
fi

echo "  $FINDINGS finding(s)."
if [[ "$CHAIN_ON_WIRE" == "$MAINNET" ]]; then
  die "exposed keys hold power on MAINNET. Do not launch. See docs/BURNED-KEYS.md."
fi
echo "  Expected on testnet: these keys run this deployment. The same run"
echo "  against mainnet must come back with zero."
exit 0

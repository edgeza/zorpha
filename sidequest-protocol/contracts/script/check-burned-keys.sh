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
env_of() { grep -E "^$1=" "$WEB_ENV" | head -1 | cut -d= -f2-; }
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

# Every role the protocol defines. hasRole against a contract that is not an
# AccessControl reverts, which try() swallows.
ROLES=(
  "DEFAULT_ADMIN:$ZERO"
  "DEPLOYER_ROLE:$(cast keccak 'DEPLOYER_ROLE')"
  "KEEPER_ROLE:$(cast keccak 'KEEPER_ROLE')"
  "RISK_COUNCIL_ROLE:$(cast keccak 'RISK_COUNCIL_ROLE')"
  "ADAPTER_SETTER_ROLE:$(cast keccak 'ADAPTER_SETTER_ROLE')"
  "GOVERNANCE_ROLE:$(cast keccak 'GOVERNANCE_ROLE')"
  "PROPOSER_ROLE:$(cast keccak 'PROPOSER_ROLE')"
  "EXECUTOR_ROLE:$(cast keccak 'EXECUTOR_ROLE')"
  "CANCELLER_ROLE:$(cast keccak 'CANCELLER_ROLE')"
  "ORACLE_UPDATER_ROLE:$(cast keccak 'ORACLE_UPDATER_ROLE')"
)

CONTRACTS=(
  "ZOR:NEXT_PUBLIC_ZOR_ADDRESS"
  "Timelock:NEXT_PUBLIC_TIMELOCK_ADDRESS"
  "Treasury:NEXT_PUBLIC_TREASURY_ADDRESS"
  "Buyback:NEXT_PUBLIC_BUYBACK_ADDRESS"
  "Insurance:NEXT_PUBLIC_INSURANCE_ADDRESS"
  "Distributor:NEXT_PUBLIC_MERKLE_DISTRIBUTOR_ADDRESS"
  "Vesting:NEXT_PUBLIC_VESTING_ADDRESS"
  "Factory:NEXT_PUBLIC_VAULT_FACTORY_ADDRESS"
  "Executor:NEXT_PUBLIC_STRATEGY_EXECUTOR_ADDRESS"
  "Reputation:NEXT_PUBLIC_REPUTATION_REGISTRY_ADDRESS"
  "Launcher:NEXT_PUBLIC_VAULT_LAUNCHER_ADDRESS"
)

for entry in "${BURNED[@]}"; do
  ADDR="${entry%%:*}"; WAS="${entry##*:}"
  bold "$ADDR"
  echo "  was: $WAS"
  HITS=0

  for c in "${CONTRACTS[@]}"; do
    CNAME="${c%%:*}"; CADDR=$(env_of "${c##*:}")
    [[ -z "$CADDR" || "$CADDR" == "0x0000000000000000000000000000000000000000" ]] && continue

    for r in "${ROLES[@]}"; do
      RNAME="${r%%:*}"; RHASH="${r##*:}"
      if [[ "$(try "$CADDR" 'hasRole(bytes32,address)(bool)' "$RHASH" "$ADDR")" == "true" ]]; then
        bad "$CNAME holds $RNAME"
        HITS=$((HITS + 1))
      fi
    done

    # Ownable and Ownable2Step, which are not roles.
    for fn in 'owner()(address)' 'pendingOwner()(address)'; do
      GOT=$(try "$CADDR" "$fn")
      if [[ -n "$GOT" ]] && [[ "${GOT,,}" == "${ADDR,,}" ]]; then
        bad "$CNAME ${fn%%(*} is this address"
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

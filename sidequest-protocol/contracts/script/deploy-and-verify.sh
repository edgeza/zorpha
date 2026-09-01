#!/usr/bin/env bash
# Zorpha V1 — Robinhood Chain deploy + verify.
#
# The pipeline is TWO scripts, not one. Splitting them means the token can
# launch without dragging the vault contracts along, and a vault-layer failure
# can never leave a half-deployed token.
#
#   Phase A  DeployZorphaToken  — token, timelock, treasury, buyback, insurance,
#                                 airdrop distributor, vesting, and an ATOMIC
#                                 distribution of the whole supply. Asserts the
#                                 deployer ends with zero tokens and zero roles.
#   Phase B  DeployVaultsV1     — oracle, factory, executor, registry, vaults.
#                                 Opt-in via DEPLOY_VAULTS=true, and refuses to
#                                 run if the test suite is red. Deploying the
#                                 token alone first is a valid launch, so this
#                                 stays deliberate rather than automatic.
#
# Required env:
#   PRIVATE_KEY              deployer EOA (testnet ONLY — it holds nothing after)
#   GOVERNANCE               multisig Safe. MUST NOT equal the deployer.
#   USDC_TOKEN               USDC address on the target chain
#   LIQUIDITY_RECIPIENT      protocol-owned liquidity destination
#   AIRDROP_MERKLE_ROOT      root of the published Season 1 snapshot
#   AIRDROP_CLAIM_DEADLINE   unix seconds, must be in the future
#   RH_TESTNET_RPC_URL       RPC endpoint
#   RH_EXPLORER_URL          Blockscout-style explorer API base
#   RH_EXPLORER_API_KEY      explorer API key
#
# Optional env:
#   TIMELOCK_DELAY           default 172800 (48h)
#   BUYBACK_THRESHOLD_USDC   default 1000e6
#   ORACLE_UPDATERS          comma-separated updater addresses (phase B)
#   ORACLE_QUORUM            median quorum (phase B), must be <= updater count
#   STOCK_TOKEN_1/2, STOCK_FEED_1/2                        (phase B)
#   DEPLOY_VAULTS=true       opt in to phase B (token-only is the default)
#
# Pre-reqs: forge, cast, slither, node

set -euo pipefail

CHAIN_ID=${CHAIN_ID:-46630}
PROFILE=${PROFILE:-rhTestnet}
TOKEN_SCRIPT="script/DeployZorphaToken.s.sol:DeployZorphaToken"
VAULT_SCRIPT="script/DeployVaultsV1.s.sol:DeployVaultsV1"
WEB_ENV="../../zorpha-web/.env.local"

require_env() {
  local name=$1
  if [[ -z "${!name:-}" ]]; then
    echo "ERROR: $name is required" >&2
    exit 1
  fi
}

for v in PRIVATE_KEY GOVERNANCE USDC_TOKEN LIQUIDITY_RECIPIENT \
         AIRDROP_MERKLE_ROOT AIRDROP_CLAIM_DEADLINE RH_TESTNET_RPC_URL; do
  require_env "$v"
done

DEPLOYER=$(cast wallet address --private-key "$PRIVATE_KEY")
if [[ "${DEPLOYER,,}" == "${GOVERNANCE,,}" ]]; then
  echo "ERROR: GOVERNANCE must not be the deployer EOA." >&2
  echo "  The whole point of the handover assertions is that the deploy key" >&2
  echo "  ends up with no authority. Point GOVERNANCE at a Safe." >&2
  exit 1
fi

echo "==> [1/7] forge build"
forge build

echo "==> [2/7] forge test — token layer (must be green)"
forge test --match-path 'test/Zorpha.t.sol'

echo "==> [3/7] forge test — full suite"
if forge test; then
  FULL_SUITE_GREEN=true
  echo "    full suite green"
else
  FULL_SUITE_GREEN=false
  echo ""
  echo "    !! Full suite is FAILING. Every finding in"
  echo "    !! docs/AUDIT-TOKEN-V1.md was closed against a green suite, so a"
  echo "    !! red run here is a regression, not a known-open finding."
  echo "    !! Phase B will refuse to run. Fix it before deploying vaults."
  echo ""
fi

echo "==> [4/7] slither"
slither . --config-file slither.config.json --fail-high --fail-medium || {
  echo "slither found high/medium issues; not deploying" >&2
  exit 1
}

echo "==> [5/7] Phase A — token layer deploy"
forge script "$TOKEN_SCRIPT" \
  --rpc-url "$RH_TESTNET_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  --sig "run()" \
  -vvv

BROADCAST="broadcast/DeployZorphaToken.s.sol/$CHAIN_ID/run-latest.json"
if [[ ! -f "$BROADCAST" ]]; then
  echo "ERROR: no broadcast artifact at $BROADCAST" >&2
  exit 1
fi

# Reads a deployed address out of a broadcast artifact, via node rather
# than jq. jq is a separate install often absent on a fresh machine, and it
# is only reached AFTER the token layer is live — the worst moment to find
# out, with a half-finished deploy and no addresses captured.
addr_of() {
  node -e '
    const fs = require("fs");
    const name = process.argv[1], file = process.argv[2];
    const j = JSON.parse(fs.readFileSync(file, "utf8"));
    const hit = (j.transactions || []).find(t => t.contractName === name);
    process.stdout.write(hit && hit.contractAddress ? hit.contractAddress : "");
  ' "$1" "$BROADCAST"
}

ZOR_ADDR=$(addr_of Zorpha)
TIMELOCK_ADDR=$(addr_of Timelock)
TREASURY_ADDR=$(addr_of ProtocolTreasury)
BUYBACK_ADDR=$(addr_of ZorphaBuyback)
INSURANCE_ADDR=$(addr_of InsuranceFund)
DISTRIBUTOR_ADDR=$(addr_of MerkleDistributor)
VESTING_ADDR=$(addr_of ZorphaVesting)

echo "    ZOR          $ZOR_ADDR"
echo "    Timelock     $TIMELOCK_ADDR"
echo "    Treasury     $TREASURY_ADDR"
echo "    Buyback      $BUYBACK_ADDR"
echo "    Insurance    $INSURANCE_ADDR"
echo "    Distributor  $DISTRIBUTOR_ADDR"
echo "    Vesting      $VESTING_ADDR"

# Independent on-chain confirmation of the script's own assertion. If the deploy
# key still holds supply, stop before anything is announced.
DEPLOYER_BAL=$(cast call "$ZOR_ADDR" "balanceOf(address)(uint256)" "$DEPLOYER" \
  --rpc-url "$RH_TESTNET_RPC_URL")
if [[ "${DEPLOYER_BAL%% *}" != "0" ]]; then
  echo "FATAL: deployer still holds ZOR ($DEPLOYER_BAL). Distribution failed." >&2
  exit 1
fi
echo "    verified: deployer holds 0 ZOR"

echo "==> [6/7] verify token-layer contracts"
verify() {
  local path=$1 addr=$2
  [[ -z "$addr" ]] && return 0
  forge verify-contract "$addr" "$path" \
    --chain-id "$CHAIN_ID" \
    --verifier blockscout \
    --verifier-url "${RH_EXPLORER_URL:-}" \
    --etherscan-api-key "${RH_EXPLORER_API_KEY:-}" \
    --watch || echo "    verify failed for $path ($addr) — retry manually"
}

verify src/Zorpha.sol:Zorpha                       "$ZOR_ADDR"
verify src/governance/Timelock.sol:Timelock        "$TIMELOCK_ADDR"
verify src/ProtocolTreasury.sol:ProtocolTreasury   "$TREASURY_ADDR"
verify src/ZorphaBuyback.sol:ZorphaBuyback         "$BUYBACK_ADDR"
verify src/InsuranceFund.sol:InsuranceFund         "$INSURANCE_ADDR"
verify src/MerkleDistributor.sol:MerkleDistributor "$DISTRIBUTOR_ADDR"
verify src/ZorphaVesting.sol:ZorphaVesting         "$VESTING_ADDR"

echo "==> [7/7] Phase B — vault layer"
FACTORY_ADDR=""
EXECUTOR_ADDR=""
REPUTATION_ADDR=""
VAULTS_DEPLOYED=false

if [[ "${DEPLOY_VAULTS:-false}" != "true" ]]; then
  echo "    SKIPPED. Set DEPLOY_VAULTS=true to deploy vaults."
  echo "    The token layer stands alone; launching it without vaults is a"
  echo "    valid first step, and the portal reports the vault addresses as"
  echo "    unconfigured rather than rendering empty panels."
elif [[ "$FULL_SUITE_GREEN" != "true" ]]; then
  echo "    REFUSING: DEPLOY_VAULTS=true but the test suite is failing." >&2
  echo "    A red suite means a regression against the closed audit. Fix it." >&2
  exit 1
else
  # TIMELOCK and TREASURY come from phase A. The vault script reads them from
  # the environment and reverts if either is unset, so they are passed rather
  # than re-derived.
  TIMELOCK="$TIMELOCK_ADDR" TREASURY="$TREASURY_ADDR" \
  forge script "$VAULT_SCRIPT" \
    --rpc-url "$RH_TESTNET_RPC_URL" \
    --private-key "$PRIVATE_KEY" \
    --broadcast \
    --sig "run()" \
    -vvv

  VAULT_BROADCAST="broadcast/DeployVaultsV1.s.sol/$CHAIN_ID/run-latest.json"
  if [[ ! -f "$VAULT_BROADCAST" ]]; then
    echo "ERROR: no vault broadcast artifact at $VAULT_BROADCAST" >&2
    exit 1
  fi

  vault_addr_of() {
    node -e '
      const fs = require("fs");
      const name = process.argv[1], file = process.argv[2];
      const j = JSON.parse(fs.readFileSync(file, "utf8"));
      const hit = (j.transactions || []).find(t => t.contractName === name);
      process.stdout.write(hit && hit.contractAddress ? hit.contractAddress : "");
    ' "$1" "$VAULT_BROADCAST"
  }

  FACTORY_ADDR=$(vault_addr_of VaultFactory)
  EXECUTOR_ADDR=$(vault_addr_of StrategyExecutor)
  REPUTATION_ADDR=$(vault_addr_of ReputationRegistry)

  echo "    Factory      $FACTORY_ADDR"
  echo "    Executor     $EXECUTOR_ADDR"
  echo "    Reputation   $REPUTATION_ADDR"

  if [[ -z "$FACTORY_ADDR" || -z "$EXECUTOR_ADDR" || -z "$REPUTATION_ADDR" ]]; then
    echo "ERROR: a vault-layer address is missing from the broadcast" >&2
    exit 1
  fi
  VAULTS_DEPLOYED=true

  verify src/VaultFactory.sol:VaultFactory                       "$FACTORY_ADDR"
  verify src/executor/StrategyExecutor.sol:StrategyExecutor      "$EXECUTOR_ADDR"
  verify src/reputation/ReputationRegistry.sol:ReputationRegistry "$REPUTATION_ADDR"
fi

echo "==> writing $WEB_ENV"
mkdir -p "$(dirname "$WEB_ENV")"

# Merge, do not clobber. This file also holds values that no deploy can
# reproduce: NEXT_PUBLIC_WC_PROJECT_ID comes from the Reown dashboard and the
# Supabase pair from the Supabase project. An earlier version of this script
# overwrote the whole file and silently destroyed all three, which shows up
# later as "wallet connect does nothing" with no obvious cause.
#
# Every key this script owns is stripped from the old file first, then written
# fresh below, so re-running is still idempotent for the values it manages.
OWNED_KEYS=(
  NEXT_PUBLIC_CHAIN_ID NEXT_PUBLIC_RPC_URL NEXT_PUBLIC_EXPLORER_URL
  NEXT_PUBLIC_ZOR_ADDRESS NEXT_PUBLIC_TIMELOCK_ADDRESS
  NEXT_PUBLIC_TREASURY_ADDRESS NEXT_PUBLIC_BUYBACK_ADDRESS
  NEXT_PUBLIC_INSURANCE_ADDRESS NEXT_PUBLIC_MERKLE_DISTRIBUTOR_ADDRESS
  NEXT_PUBLIC_VESTING_ADDRESS NEXT_PUBLIC_VAULT_FACTORY_ADDRESS
  NEXT_PUBLIC_STRATEGY_EXECUTOR_ADDRESS NEXT_PUBLIC_REPUTATION_REGISTRY_ADDRESS
  NEXT_PUBLIC_ENABLE_VAULT_DEPOSITS
)

PRESERVED=""
if [[ -f "$WEB_ENV" ]]; then
  cp "$WEB_ENV" "$WEB_ENV.bak"
  echo "    previous file backed up to $WEB_ENV.bak"
  PRESERVED=$(grep -v '^[[:space:]]*#' "$WEB_ENV" | grep '=' || true)
  for k in "${OWNED_KEYS[@]}"; do
    PRESERVED=$(printf '%s\n' "$PRESERVED" | grep -v "^${k}=" || true)
  done
fi

if [[ "$VAULTS_DEPLOYED" == "true" ]]; then
  DEPOSITS_ENABLED=true
else
  # No vaults deployed means no deposit surface to enable. The portal reads
  # this as the literal string "false".
  DEPOSITS_ENABLED=false
fi

{
  echo "# Written by contracts/script/deploy-and-verify.sh. Values above the"
  echo "# separator are managed by that script and will be replaced on the next"
  echo "# run; anything below it is preserved."
  echo ""
  echo "NEXT_PUBLIC_CHAIN_ID=$CHAIN_ID"
  echo "NEXT_PUBLIC_RPC_URL=$RH_TESTNET_RPC_URL"
  echo "NEXT_PUBLIC_EXPLORER_URL=${RH_EXPLORER_URL:-}"
  echo ""
  echo "NEXT_PUBLIC_ZOR_ADDRESS=$ZOR_ADDR"
  echo "NEXT_PUBLIC_TIMELOCK_ADDRESS=$TIMELOCK_ADDR"
  echo "NEXT_PUBLIC_TREASURY_ADDRESS=$TREASURY_ADDR"
  echo "NEXT_PUBLIC_BUYBACK_ADDRESS=$BUYBACK_ADDR"
  echo "NEXT_PUBLIC_INSURANCE_ADDRESS=$INSURANCE_ADDR"
  echo "NEXT_PUBLIC_MERKLE_DISTRIBUTOR_ADDRESS=$DISTRIBUTOR_ADDR"
  echo "NEXT_PUBLIC_VESTING_ADDRESS=$VESTING_ADDR"
  echo ""
  echo "NEXT_PUBLIC_VAULT_FACTORY_ADDRESS=$FACTORY_ADDR"
  echo "NEXT_PUBLIC_STRATEGY_EXECUTOR_ADDRESS=$EXECUTOR_ADDR"
  echo "NEXT_PUBLIC_REPUTATION_REGISTRY_ADDRESS=$REPUTATION_ADDR"
  echo ""
  echo "NEXT_PUBLIC_ENABLE_VAULT_DEPOSITS=$DEPOSITS_ENABLED"
  echo ""
  echo "# ─── preserved from the previous file ───────────────────────────────"
  if [[ -n "$PRESERVED" ]]; then
    printf '%s\n' "$PRESERVED"
  fi
} > "$WEB_ENV"

echo "    wrote $WEB_ENV"
if [[ -n "$PRESERVED" ]]; then
  echo "    preserved $(printf '%s\n' "$PRESERVED" | grep -c '=') existing variable(s)"
fi

cat <<'NEXTEOF'

Done. Manual steps that cannot be scripted:

  1. Timelock must queue and execute ProtocolTreasury.acceptOwnership()
     (Ownable2Step is deliberately two-phase).
  2. Safe calls ZorphaVesting.fund() with the real contributor and backer
     schedules. Those addresses do not belong in a committed env file.
  3. Safe queues ZorphaBuyback.setRouter() once a ZOR market exists. Until
     then fee revenue accumulates and is withdrawable via withdrawUsdc.
  4. Seat the real oracle updater set and raise ORACLE_QUORUM above 1.
  5. Publish the Season 1 snapshot criteria BEFORE opening claims.
NEXTEOF

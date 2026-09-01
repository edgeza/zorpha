#!/usr/bin/env bash
# Zorpha V1 — Robinhood Chain deploy + verify.
#
# The pipeline is TWO scripts, not one. The token layer stands alone and is
# audited green; the vault layer has open critical findings. Splitting them
# means the token can launch without dragging the vault contracts along, and a
# vault-layer failure can never leave a half-deployed token.
#
#   Phase A  DeployZorphaToken  — token, timelock, treasury, buyback, insurance,
#                                 airdrop distributor, vesting, and an ATOMIC
#                                 distribution of the whole supply. Asserts the
#                                 deployer ends with zero tokens and zero roles.
#   Phase B  DeployVaultsV1     — oracle, factory, executor, registry, vaults.
#                                 GATED: will not run while the vault test suite
#                                 is failing. See docs/AUDIT-TOKEN-V1.md V-01.
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
#   DEPLOY_VAULTS=true       opt in to phase B despite open findings
#
# Pre-reqs: forge, cast, slither, jq

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

echo "==> [3/7] forge test — full suite (informational)"
if forge test; then
  FULL_SUITE_GREEN=true
  echo "    full suite green"
else
  FULL_SUITE_GREEN=false
  echo ""
  echo "    !! Full suite is FAILING. This is expected while the vault-layer"
  echo "    !! findings in docs/AUDIT-TOKEN-V1.md (V-01..V-05) are open."
  echo "    !! Phase B is skipped unless DEPLOY_VAULTS=true is set."
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

addr_of() {
  jq -r --arg n "$1" \
    '[.transactions[] | select(.contractName == $n) | .contractAddress] | first // ""' \
    "$BROADCAST"
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
if [[ "${DEPLOY_VAULTS:-false}" != "true" ]]; then
  echo "    SKIPPED. Set DEPLOY_VAULTS=true to deploy vaults."
  echo "    Vault deposits should stay disabled in the portal until"
  echo "    docs/AUDIT-TOKEN-V1.md V-01 is fixed and the suite is green."
elif [[ "$FULL_SUITE_GREEN" != "true" ]]; then
  echo "    REFUSING: DEPLOY_VAULTS=true but the test suite is failing." >&2
  echo "    Fix V-01..V-05 first." >&2
  exit 1
else
  TIMELOCK="$TIMELOCK_ADDR" TREASURY="$TREASURY_ADDR" \
  forge script "$VAULT_SCRIPT" \
    --rpc-url "$RH_TESTNET_RPC_URL" \
    --private-key "$PRIVATE_KEY" \
    --broadcast \
    --sig "run()" \
    -vvv
fi

echo "==> writing $WEB_ENV"
mkdir -p "$(dirname "$WEB_ENV")"
cat > "$WEB_ENV" <<ENVEOF
NEXT_PUBLIC_CHAIN_ID=$CHAIN_ID
NEXT_PUBLIC_RPC_URL=$RH_TESTNET_RPC_URL
NEXT_PUBLIC_EXPLORER_URL=${RH_EXPLORER_URL:-}

NEXT_PUBLIC_ZOR_ADDRESS=$ZOR_ADDR
NEXT_PUBLIC_TIMELOCK_ADDRESS=$TIMELOCK_ADDR
NEXT_PUBLIC_TREASURY_ADDRESS=$TREASURY_ADDR
NEXT_PUBLIC_BUYBACK_ADDRESS=$BUYBACK_ADDR
NEXT_PUBLIC_INSURANCE_ADDRESS=$INSURANCE_ADDR
NEXT_PUBLIC_MERKLE_DISTRIBUTOR_ADDRESS=$DISTRIBUTOR_ADDR
NEXT_PUBLIC_VESTING_ADDRESS=$VESTING_ADDR

# Left blank unless phase B ran. Fill from its broadcast artifact.
NEXT_PUBLIC_VAULT_FACTORY_ADDRESS=
NEXT_PUBLIC_STRATEGY_EXECUTOR_ADDRESS=
NEXT_PUBLIC_REPUTATION_REGISTRY_ADDRESS=

# Keep false until docs/AUDIT-TOKEN-V1.md V-01 is closed.
NEXT_PUBLIC_ENABLE_VAULT_DEPOSITS=false
ENVEOF

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

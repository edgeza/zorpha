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
#   PRIVATE_KEY              deployer EOA, as a raw key. Testnet ONLY.
#   DEPLOY_ACCOUNT           deployer as a cast KEYSTORE name, e.g. zorpha-gov.
#                            Preferred, and REQUIRED on mainnet: PRIVATE_KEY
#                            means the key sits in an environment variable and
#                            in shell history, which is how both keys in
#                            docs/BURNED-KEYS.md were burned. Set one or the
#                            other, not both.
#   SKIP_TOKEN=true          redeploy ONLY the vault layer, leaving the token
#                            layer alone. TIMELOCK and TREASURY are then read
#                            from zorpha-web/.env.local instead of from a phase
#                            A run. Needed because VaultFactory compiles the
#                            vault bytecode INTO itself, so any fix to a vault
#                            contract requires a new factory -- and re-running
#                            phase A to get one would orphan the live token,
#                            the airdrop and the vesting schedules.
#   GOVERNANCE               multisig Safe. MUST NOT equal the deployer.
#   USDG_TOKEN               base asset (USDC_TOKEN also accepted)
#   LIQUIDITY_RECIPIENT      protocol-owned liquidity destination
#   AIRDROP_MERKLE_ROOT      root of the published Season 1 snapshot
#   AIRDROP_CLAIM_DEADLINE   unix seconds, must be in the future
#   RH_TESTNET_RPC_URL       RPC endpoint
#   RH_EXPLORER_URL          Blockscout-style explorer API base
#   RH_EXPLORER_API_KEY      explorer API key
#
# Optional env:
#   TIMELOCK_DELAY           default 172800 (48h)
#   BUYBACK_THRESHOLD_USDG   default 1000e6 (BUYBACK_THRESHOLD_USDC also accepted)
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

if [[ -n "${PRIVATE_KEY:-}" && -n "${DEPLOY_ACCOUNT:-}" ]]; then
  echo "ERROR: set PRIVATE_KEY or DEPLOY_ACCOUNT, not both." >&2
  exit 1
fi
if [[ -z "${PRIVATE_KEY:-}" && -z "${DEPLOY_ACCOUNT:-}" ]]; then
  echo "ERROR: set DEPLOY_ACCOUNT to a cast keystore name (preferred) or" >&2
  echo "       PRIVATE_KEY to a raw key (testnet only)." >&2
  exit 1
fi

# How every forge/cast call below authenticates. An array so it expands to two
# words or one, with no quoting games at the call sites.
if [[ -n "${DEPLOY_ACCOUNT:-}" ]]; then
  SIGNER_ARGS=(--account "$DEPLOY_ACCOUNT")
else
  SIGNER_ARGS=(--private-key "$PRIVATE_KEY")
fi

# Split by phase. LIQUIDITY_RECIPIENT, AIRDROP_MERKLE_ROOT and
# AIRDROP_CLAIM_DEADLINE are read only by DeployZorphaToken, so demanding them
# under SKIP_TOKEN blocks a vault redeploy on values that will not be used --
# and pushes whoever is deploying to invent a placeholder for a required-looking
# variable, which is worse than not asking.
REQUIRED_ENV=(GOVERNANCE RH_TESTNET_RPC_URL)
if [[ "${SKIP_TOKEN:-false}" != "true" ]]; then
  REQUIRED_ENV+=(LIQUIDITY_RECIPIENT AIRDROP_MERKLE_ROOT AIRDROP_CLAIM_DEADLINE)
fi
for v in "${REQUIRED_ENV[@]}"; do
  require_env "$v"
done

# The base asset goes by two names. Robinhood Chain's stablecoin is Paxos USDG,
# not USDC -- the canonical USDC addresses have no code on 4663 -- but the
# original variable was USDC_TOKEN and an in-flight runbook may still use it.
# Accept either, prefer USDG_TOKEN, and export both so the forge scripts see a
# value whichever name they read.
if [[ -z "${USDG_TOKEN:-}" && -z "${USDC_TOKEN:-}" ]]; then
  echo "ERROR: set USDG_TOKEN (or the legacy USDC_TOKEN) to the base asset" >&2
  exit 1
fi
export USDG_TOKEN="${USDG_TOKEN:-$USDC_TOKEN}"
export USDC_TOKEN="${USDC_TOKEN:-$USDG_TOKEN}"

DEPLOYER=$(cast wallet address "${SIGNER_ARGS[@]}")
if [[ "${DEPLOYER,,}" == "${GOVERNANCE,,}" ]]; then
  echo "ERROR: GOVERNANCE and the deployer are the same address ($DEPLOYER)." >&2
  echo "" >&2
  echo "  The whole point of the handover assertions is that the deploy key ends" >&2
  echo "  up with no authority. If it is also governance, the deployment ends with" >&2
  echo "  no admin at all, so DeployVaultsV1 refuses it too." >&2
  echo "" >&2
  echo "  This is the natural mistake on testnet, because the governance EOA is" >&2
  echo "  usually the only account with gas, so it is the obvious thing to deploy" >&2
  echo "  with. Use a separate, disposable deployer instead. To create one" >&2
  echo "  WITHOUT ever printing a private key -- the path argument is what makes" >&2
  echo "  it safe, and its absence is how both keys in docs/BURNED-KEYS.md were" >&2
  echo "  burned:" >&2
  echo "" >&2
  echo "    cast wallet new ~/.foundry/keystores zorpha-deployer" >&2
  echo "" >&2
  echo "  Fund the address it prints, then re-run with" >&2
  echo "  DEPLOY_ACCOUNT=zorpha-deployer and leave GOVERNANCE as it is." >&2
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

# Slither shells out to `forge`, and it does so through the OS rather than
# through this shell -- which on Windows means the system PATH, not ours.
# foundryup installs into ~/.foundry/bin, which is usually only on the shell's,
# so slither died in crytic-compile before reading a line of Solidity. Hand the
# child the same forge we are already using.
command -v forge >/dev/null || { echo "ERROR: forge not on PATH" >&2; exit 1; }
FORGE_DIR="$(cd "$(dirname "$(command -v forge)")" && pwd)"
case ":$PATH:" in
  *":$FORGE_DIR:"*) ;;
  *) PATH="$FORGE_DIR:$PATH"; export PATH ;;
esac

SLITHER_JSON="slither-report.json"
SLITHER_LOG="slither-run.log"
rm -f "$SLITHER_JSON" "$SLITHER_LOG"

# --fail-none on purpose. It makes the exit code mean "slither ran", so a crash
# and a finding stop being the same signal -- previously a compile failure was
# reported as "found high/medium issues", which is the most misleading way this
# step could possibly fail. What it found is read out of the report below.
#
# (--fail-high and --fail-medium are also mutually exclusive in argparse, and
# --fail-medium already covers high. Passing both aborted the run outright.)
if ! slither . --config-file slither.config.json --fail-none        --json "$SLITHER_JSON" > "$SLITHER_LOG" 2>&1 || [[ ! -s "$SLITHER_JSON" ]]; then
  echo "" >&2
  echo "ERROR: slither could not run. This is a tooling failure, not a finding." >&2
  echo "       Nothing has been deployed. Last 20 lines of $SLITHER_LOG:" >&2
  echo "" >&2
  tail -20 "$SLITHER_LOG" >&2
  exit 1
fi

if ! node -e '
  const fs = require("fs");
  const file = process.argv[1];
  const all = (JSON.parse(fs.readFileSync(file, "utf8")).results || {}).detectors || [];
  const tally = {};
  for (const d of all) tally[d.impact] = (tally[d.impact] || 0) + 1;
  const summary = Object.entries(tally).map(([k, v]) => k + ": " + v).join(", ");
  console.log("    " + (summary || "no findings"));

  const blocking = all.filter(d => d.impact === "High" || d.impact === "Medium");
  if (blocking.length === 0) {
    console.log("    nothing high or medium");
    process.exit(0);
  }
  console.error("");
  console.error("slither found " + blocking.length + " high/medium finding(s):");
  for (const d of blocking) {
    const el = (d.elements || [])[0] || {};
    const sm = el.source_mapping || {};
    console.error("  [" + d.impact + "] " + d.check + "  " +
      (sm.filename_relative || "?") + ":" + ((sm.lines || [])[0] || "?"));
  }
  console.error("");
  console.error("Full detail is in " + file + ".");
  console.error("Read each one. If it is genuinely a false positive, put the reason");
  console.error("on the line it concerns with a // slither-disable-next-line <check>");
  console.error("comment, so the detector stays live for code written later.");
  process.exit(1);
' "$SLITHER_JSON"; then
  echo "not deploying" >&2
  exit 1
fi

if [[ "${SKIP_TOKEN:-false}" == "true" ]]; then
  echo "==> [5/7] Phase A — SKIPPED (SKIP_TOKEN=true)"
  echo "    The live token layer is left exactly as it is. Nothing below"
  echo "    touches ZOR, the timelock, the treasury, the vesting schedules,"
  echo "    the buyback or the airdrop distributor."
  echo ""
  echo "    This exists because VaultFactory compiles the vault bytecode INTO"
  echo "    itself: it deploys via Create2 with type(Vault).creationCode, fixed"
  echo "    at the factory's own compile time. So a fix to any vault contract"
  echo "    is unreachable until the factory is redeployed, and re-running"
  echo "    phase A to get one would orphan a token that already has holders."
  echo ""
  echo "    Verified on testnet 46630: a rotation vault deployed through the"
  echo "    live factory after the units fix had no netValueInBase() and"
  echo "    reported totalAssets() == grossValue(), the broken behaviour."
  echo ""
  echo "    Vault deposits must be at zero before doing this. The old vaults"
  echo "    keep working and keep their balances; they simply stop being the"
  echo "    ones the portal points at, so anything left in them is stranded"
  echo "    from a user's point of view."
else
  echo "==> [5/7] Phase A — token layer deploy"
  forge script "$TOKEN_SCRIPT" \
  --rpc-url "$RH_TESTNET_RPC_URL" \
  "${SIGNER_ARGS[@]}" \
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
fi

# When phase A was skipped, the same addresses come from whatever the front end
# is currently pointed at -- which is the definition of "the live deployment".
if [[ "${SKIP_TOKEN:-false}" == "true" ]]; then
  env_live() { grep -E "^$1=" "$WEB_ENV" 2>/dev/null | head -1 | cut -d= -f2-; }
  ZOR_ADDR=$(env_live NEXT_PUBLIC_ZOR_ADDRESS)
  TIMELOCK_ADDR=$(env_live NEXT_PUBLIC_TIMELOCK_ADDRESS)
  TREASURY_ADDR=$(env_live NEXT_PUBLIC_TREASURY_ADDRESS)
  BUYBACK_ADDR=$(env_live NEXT_PUBLIC_BUYBACK_ADDRESS)
  INSURANCE_ADDR=$(env_live NEXT_PUBLIC_INSURANCE_ADDRESS)
  DISTRIBUTOR_ADDR=$(env_live NEXT_PUBLIC_MERKLE_DISTRIBUTOR_ADDRESS)
  VESTING_ADDR=$(env_live NEXT_PUBLIC_VESTING_ADDRESS)

  for pair in "ZOR:$ZOR_ADDR" "Timelock:$TIMELOCK_ADDR" "Treasury:$TREASURY_ADDR"; do
    if [[ -z "${pair##*:}" ]]; then
      echo "ERROR: SKIP_TOKEN=true but ${pair%%:*} is not in $WEB_ENV." >&2
      echo "       The vault script reverts without TIMELOCK and TREASURY, so" >&2
      echo "       there is nothing to inherit. Run a full deploy instead." >&2
      exit 1
    fi
  done

  echo "    inherited from $WEB_ENV:"
  echo "    ZOR          $ZOR_ADDR"
  echo "    Timelock     $TIMELOCK_ADDR"
  echo "    Treasury     $TREASURY_ADDR"
fi

# Independent on-chain confirmation of the script's own assertion. If the deploy
# key still holds supply, stop before anything is announced.
#
# Phase A only. It asserts that DISTRIBUTION worked -- that the key which minted
# the supply kept none of it -- and that is only a claim about a run which just
# minted. Under SKIP_TOKEN the deployer is whoever is redeploying the vault
# layer, and there is no reason they should not hold ZOR: the governance
# account holds 880,055,000 of it on testnet, so running this unconditionally
# aborts every vault redeploy with "Distribution failed", which would be both
# wrong and extremely confusing.
if [[ "${SKIP_TOKEN:-false}" != "true" ]]; then
  DEPLOYER_BAL=$(cast call "$ZOR_ADDR" "balanceOf(address)(uint256)" "$DEPLOYER" \
    --rpc-url "$RH_TESTNET_RPC_URL")
  if [[ "${DEPLOYER_BAL%% *}" != "0" ]]; then
    echo "FATAL: deployer still holds ZOR ($DEPLOYER_BAL). Distribution failed." >&2
    exit 1
  fi
  echo "    verified: deployer holds 0 ZOR"
else
  echo "    deployer ZOR check skipped: it asserts phase A distribution, which"
  echo "    did not run. The vault deployer may hold ZOR legitimately."
fi

# Verify every contract in a broadcast artifact.
#
# Note the "/api". RH_EXPLORER_URL is the explorer's base URL, and forge appends
# its query string to whatever it is given, so passing the base sends
# ?module=contract&action=... to the Blockscout *frontend*, which answers with a
# Next.js HTML page and fails as "expected value at line 1 column 1". That is
# what happened on the first testnet run: all seven contracts reported a
# verification failure when nothing was wrong with any of them.
#
# The contract list comes from the broadcast artifact rather than from a list
# maintained here, because the list maintained here was wrong: it named ten
# contracts and the deploy created nineteen. The oracle, both adapters and all
# three vaults were never verified because nobody had added a line for them.
# Constructor arguments are recovered from the same artifact.
# See script/broadcast-contracts.js.
verify_broadcast() {
  local artifact=$1
  [[ -f "$artifact" ]] || { echo "    no artifact at $artifact, skipping verify"; return 0; }

  local key_args=()
  [[ -n "${RH_EXPLORER_API_KEY:-}" ]] && key_args=(--etherscan-api-key "$RH_EXPLORER_API_KEY")

  local addr target args ok=0 bad=0
  while read -r addr target args; do
    [[ -z "$addr" ]] && continue
    if forge verify-contract "$addr" "$target" \
         --chain-id "$CHAIN_ID" \
         --verifier blockscout \
         --verifier-url "${RH_EXPLORER_URL:-}/api" \
         "${key_args[@]}" \
         ${args:+--constructor-args "$args"} \
         --watch >/dev/null 2>&1; then
      echo "    verified  ${target##*:}  $addr"
      ok=$((ok + 1))
    else
      echo "    FAILED    ${target##*:}  $addr  (retry manually)"
      bad=$((bad + 1))
    fi
  done < <(node script/broadcast-contracts.js "$artifact")

  echo "    $ok verified, $bad failed"
  # Deliberately not fatal. Verification is a block-explorer convenience; the
  # contracts are on chain either way, and aborting here would leave a
  # half-deployed protocol over a cosmetic problem.
  return 0
}

echo "==> [6/7] verify token-layer contracts"
if [[ "${SKIP_TOKEN:-false}" == "true" ]]; then
  echo "    SKIPPED. Phase A did not run, so there is no new artifact to verify"
  echo "    and the live token contracts were verified by the deploy that made"
  echo "    them. \$BROADCAST is unset here and set -u would abort the run."
else
  verify_broadcast "$BROADCAST"
fi

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
    "${SIGNER_ARGS[@]}" \
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

  # Covers the oracle, both adapters and the three CREATE2 vaults as well as
  # these three, none of which the old hardcoded list mentioned.
  verify_broadcast "$VAULT_BROADCAST"
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

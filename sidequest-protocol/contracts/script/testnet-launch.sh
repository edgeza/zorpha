#!/usr/bin/env bash
# Zorpha — one-command testnet launch.
#
# Runs the four deploy steps in order, capturing each one's addresses and
# feeding them to the next, so there is no copy-pasting of hex between phases:
#
#   1  fixtures      tUSDG, two equity tokens, a curated-vault stand-in
#   2  token layer   ZOR, timelock, treasury, buyback, insurance, airdrop, vesting
#   3  vault layer   oracle, factory, executor, registry, three vaults
#   4  leadership    the permissionless vault launcher
#
# Everything it needs comes from the environment. It reads PRIVATE_KEY but never
# prints, logs or writes it anywhere.
#
# Usage:
#   export PRIVATE_KEY=0x...          deployer, the funded account
#   export GOVERNANCE=0x...           a DIFFERENT account you control
#   ./script/testnet-launch.sh
#
# Safe to re-run: each phase redeploys, and the last run wins.

set -euo pipefail

RPC="${RH_TESTNET_RPC_URL:-https://rpc.testnet.chain.robinhood.com/rpc}"
EXPLORER="${RH_EXPLORER_URL:-https://explorer.testnet.chain.robinhood.com}"
CHAIN_ID=46630

bold() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
die()  { printf '\n  \033[31m✗ %s\033[0m\n\n' "$1" >&2; exit 1; }

# Reads a deployed address out of a broadcast artifact. node, not jq: jq is a
# separate install often absent on a fresh machine, and it would only be missed
# after the first phase is already on chain.
addr_of() {
  node -e '
    const fs = require("fs");
    const [name, file] = process.argv.slice(1);
    const j = JSON.parse(fs.readFileSync(file, "utf8"));
    const hit = (j.transactions || []).find(t => t.contractName === name);
    process.stdout.write(hit && hit.contractAddress ? hit.contractAddress : "");
  ' "$1" "$2"
}

# ─── Preflight ──────────────────────────────────────────────────────────────
bold "Preflight"

command -v forge >/dev/null || die "forge not found. Install foundry, then reopen the shell."
command -v cast  >/dev/null || die "cast not found. Install foundry, then reopen the shell."
command -v node  >/dev/null || die "node not found."
ok "forge, cast and node are on PATH"

[[ -n "${PRIVATE_KEY:-}" ]] || die "PRIVATE_KEY is not set. export PRIVATE_KEY=0x... first."
[[ -n "${GOVERNANCE:-}"  ]] || die "GOVERNANCE is not set. It must be a SECOND account you control."

DEPLOYER=$(cast wallet address --private-key "$PRIVATE_KEY")
ok "deployer resolves to $DEPLOYER"

if [[ "${DEPLOYER,,}" == "${GOVERNANCE,,}" ]]; then
  die "GOVERNANCE must not equal the deployer.
     The deploy asserts the deploy key ends with no tokens and no roles, and
     that assertion means nothing if it is also the governance key.
     Make a second account in Rabby and use its address."
fi
ok "governance is a different account"

CHAIN_ON_WIRE=$(cast chain-id --rpc-url "$RPC")
[[ "$CHAIN_ON_WIRE" == "$CHAIN_ID" ]] || die "RPC reports chain $CHAIN_ON_WIRE, expected $CHAIN_ID."
ok "connected to Robinhood Chain testnet ($CHAIN_ID)"

BAL=$(cast balance "$DEPLOYER" --rpc-url "$RPC")
if [[ "$BAL" == "0" ]]; then
  die "deployer has no gas. Fund $DEPLOYER from the Robinhood Chain testnet faucet."
fi
ok "deployer funded: $(cast to-unit "$BAL" ether) ETH"

GOV_BAL=$(cast balance "$GOVERNANCE" --rpc-url "$RPC")
if [[ "$GOV_BAL" == "0" ]]; then
  warn "governance account has NO gas."
  warn "It does not need any for these four phases, but it does for the"
  warn "post-deploy steps (granting the launcher its role, claiming fees)."
  warn "Fund $GOVERNANCE from the faucet before step 5."
fi

for v in LIQUIDITY_RECIPIENT AIRDROP_MERKLE_ROOT AIRDROP_CLAIM_DEADLINE; do
  [[ -n "${!v:-}" ]] || die "$v is not set. See the guide."
done
ok "airdrop root and liquidity recipient are set"

# ─── 1. Fixtures ────────────────────────────────────────────────────────────
bold "1/4  Testnet fixtures"
echo "  Testnet has no USDG, no curated vaults and no DEX, so these stand in."

forge script script/DeployTestnetFixtures.s.sol:DeployTestnetFixtures \
  --rpc-url "$RPC" --private-key "$PRIVATE_KEY" --broadcast >/dev/null

FIX="broadcast/DeployTestnetFixtures.s.sol/$CHAIN_ID/run-latest.json"
[[ -f "$FIX" ]] || die "no broadcast artifact at $FIX"

export USDG_TOKEN=$(addr_of TestUSDG "$FIX")
export YIELD_TARGET=$(addr_of TestYieldTarget "$FIX")
# Two TestEquity deployments; take them in order.
export STOCK_TOKEN_1=$(node -e '
  const fs=require("fs");
  const j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
  const e=(j.transactions||[]).filter(t=>t.contractName==="TestEquity");
  process.stdout.write(e[0]?e[0].contractAddress:"");
' "$FIX")
export STOCK_TOKEN_2=$(node -e '
  const fs=require("fs");
  const j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
  const e=(j.transactions||[]).filter(t=>t.contractName==="TestEquity");
  process.stdout.write(e[1]?e[1].contractAddress:"");
' "$FIX")

[[ -n "$USDG_TOKEN" && -n "$YIELD_TARGET" && -n "$STOCK_TOKEN_1" ]] \
  || die "could not read fixture addresses out of $FIX"

ok "tUSDG        $USDG_TOKEN"
ok "yield target $YIELD_TARGET"
ok "tAAPL        $STOCK_TOKEN_1"
ok "tNVDA        $STOCK_TOKEN_2"

# ─── 2 + 3. Token and vault layers ──────────────────────────────────────────
bold "2/4 and 3/4  Token layer, then vault layer"
echo "  Slither and the full test suite run first. This takes a few minutes."

export RH_TESTNET_RPC_URL="$RPC"
export RH_EXPLORER_URL="$EXPLORER"
export DEPLOY_VAULTS=true
export CHAIN_ID

./script/deploy-and-verify.sh

TOK="broadcast/DeployZorphaToken.s.sol/$CHAIN_ID/run-latest.json"
VLT="broadcast/DeployVaultsV1.s.sol/$CHAIN_ID/run-latest.json"

export ZOR_TOKEN=$(addr_of Zorpha "$TOK")
export TIMELOCK=$(addr_of Timelock "$TOK")
export TREASURY=$(addr_of ProtocolTreasury "$TOK")
export VAULT_FACTORY=$(addr_of VaultFactory "$VLT")

[[ -n "$ZOR_TOKEN" && -n "$VAULT_FACTORY" ]] || die "could not read core addresses"
ok "ZOR      $ZOR_TOKEN"
ok "Timelock $TIMELOCK"
ok "Factory  $VAULT_FACTORY"

# ─── 4. Leadership ──────────────────────────────────────────────────────────
bold "4/4  Leadership layer"

export APPROVED_YIELD_TARGETS="$YIELD_TARGET"
forge script script/DeployLeadership.s.sol:DeployLeadership \
  --rpc-url "$RPC" --private-key "$PRIVATE_KEY" --broadcast >/dev/null

LDR="broadcast/DeployLeadership.s.sol/$CHAIN_ID/run-latest.json"
LAUNCHER=$(addr_of VaultLauncher "$LDR")
[[ -n "$LAUNCHER" ]] || die "could not read the launcher address"
ok "VaultLauncher $LAUNCHER"

# Record it for the web app. The leadership script does not write .env.local
# itself, and this key is not one deploy-and-verify.sh manages, so it would
# otherwise have to be pasted by hand.
WEB_ENV="../../zorpha-web/.env.local"
if [[ -f "$WEB_ENV" ]]; then
  if grep -q '^NEXT_PUBLIC_VAULT_LAUNCHER_ADDRESS=' "$WEB_ENV"; then
    node -e '
      const fs=require("fs");
      const [file,addr]=process.argv.slice(1);
      const out=fs.readFileSync(file,"utf8")
        .replace(/^NEXT_PUBLIC_VAULT_LAUNCHER_ADDRESS=.*$/m,
                 "NEXT_PUBLIC_VAULT_LAUNCHER_ADDRESS="+addr);
      fs.writeFileSync(file,out);
    ' "$WEB_ENV" "$LAUNCHER"
  else
    printf '\nNEXT_PUBLIC_VAULT_LAUNCHER_ADDRESS=%s\n' "$LAUNCHER" >> "$WEB_ENV"
  fi
  ok "wrote the launcher address into zorpha-web/.env.local"
fi

# ─── What is left ───────────────────────────────────────────────────────────
bold "Deployed. Two things remain, and both fail SILENTLY if skipped."

cat <<NEXT

  1. Let the launcher create vaults.

     The factory's admin is your governance account, so only it can do this.
     Until it happens, launchYieldVault reverts for everyone and the Leaders
     page stays empty with no error anywhere.

     From the GOVERNANCE account:

       cast send $VAULT_FACTORY \\
         "grantRole(bytes32,address)" \\
         0x$(cast keccak "DEPLOYER_ROLE" | sed 's/^0x//') \\
         $LAUNCHER \\
         --rpc-url $RPC --private-key <GOVERNANCE_KEY>

     Or paste the same call into Rabby if you would rather not export that key.

  2. Accept treasury ownership.

     ProtocolTreasury uses Ownable2Step, so the transfer to the Timelock is
     pending until accepted. Queue acceptOwnership() through the Timelock at
     $TIMELOCK.

  Then start the site and work phases 3 and 5b of docs/LAUNCH-CHECKLIST.md:

       cd ../../zorpha-web && npm run dev

  Explorer: $EXPLORER/address/$DEPLOYER

NEXT

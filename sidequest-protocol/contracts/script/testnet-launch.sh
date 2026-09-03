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
#   export ZORPHA_DEPLOY_ACCOUNT=name  a keystore in ~/.foundry/keystores
#                                      (or PRIVATE_KEY=0x... on TESTNET only)
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

# A KEYSTORE, or a raw key for testnet only.
#
# This wrapper used to require PRIVATE_KEY in the environment and pass it as
# --private-key. That is the practice that burned two of this project's keys:
# a raw key in a shell is one `history` or one pasted terminal buffer from
# being public, and both of ours went that way. It is also the one thing that
# must not happen on mainnet, where the deployer holds every role from the
# first block.
#
# The Solidity scripts already supported keystores -- PRIVATE_KEY is read with
# vm.envOr and they fall back to forge's own signer -- so only this wrapper
# stood in the way.
#
# ZORPHA_DEPLOY_ACCOUNT wins when both are set. Create one with a PATH, which
# prints the address and nothing else:
#
#     cast wallet new ~/.foundry/keystores zorpha-mainnet-deployer
#
# Bare `cast wallet new` prints the private key to stdout. That is exactly how
# the existing keys were lost.
# DEPLOY_ACCOUNT is the canonical name -- script/deploy-and-verify.sh, which
# phases 2 and 3 delegate to, has always read it. ZORPHA_DEPLOY_ACCOUNT is
# accepted as an alias because this wrapper briefly documented it, and having
# two names for one thing is how phase 1 succeeded and phase 2 died on
# "set DEPLOY_ACCOUNT to a cast keystore name".
#
# It is EXPORTED, not just read: the child script runs in its own process and
# inherits nothing that is merely local here.
DEPLOY_ACCT="${DEPLOY_ACCOUNT:-${ZORPHA_DEPLOY_ACCOUNT:-}}"
PW=()
[[ -n "${ZORPHA_PASSWORD_FILE:-}" ]] && {
  [[ -r "$ZORPHA_PASSWORD_FILE" ]] || die "cannot read $ZORPHA_PASSWORD_FILE"
  PW=(--password-file "$ZORPHA_PASSWORD_FILE")
}

if [[ -n "$DEPLOY_ACCT" ]]; then
  # The child refuses when BOTH are set, so a keystore run must not leak a
  # stale PRIVATE_KEY from the caller's environment into it.
  export DEPLOY_ACCOUNT="$DEPLOY_ACCT"
  unset PRIVATE_KEY
  SIGNER=(--account "$DEPLOY_ACCT" "${PW[@]}")
  DEPLOYER=$(cast wallet address --account "$DEPLOY_ACCT" "${PW[@]}")
  ok "deployer resolves to $DEPLOYER (keystore $DEPLOY_ACCT)"
elif [[ -n "${PRIVATE_KEY:-}" ]]; then
  SIGNER=(--private-key "$PRIVATE_KEY")
  DEPLOYER=$(cast wallet address --private-key "$PRIVATE_KEY")
  warn "using a raw PRIVATE_KEY. Acceptable on testnet, never on mainnet --"
  warn "set ZORPHA_DEPLOY_ACCOUNT to a keystore instead."
  ok "deployer resolves to $DEPLOYER"
else
  die "no signer. Set ZORPHA_DEPLOY_ACCOUNT to a keystore name (preferred), or
     PRIVATE_KEY for testnet only."
fi

[[ -n "${GOVERNANCE:-}"  ]] || die "GOVERNANCE is not set. It must be a SECOND account you control."

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

# ─── Oracle updater set ─────────────────────────────────────────────────────
# Phase B defaults ORACLE_UPDATERS to the deployer and then refuses, because
# _handOver renounces UPDATER_ROLE from the deployer while addUpdater has
# already pushed it into the `updaters` array and nothing removes it. The
# result is an oracle that can never reach quorum and vaults that revert on
# their first NAV read.
#
# That refusal is right. Where it lands is not: phase 3 of 4, after slither,
# the full suite and a COMPLETED phase-A deploy have spent three minutes and
# real gas on a run that was never going to finish. Every fact it checks is
# already on the table here, so check it here.
#
# The seated address must be one the price keeper actually signs with. Seating
# an address nobody posts from is the same dead oracle by a slower route: the
# deploy succeeds, and the first rebalance reverts on staleness.
if [[ -z "${ORACLE_UPDATERS:-}" ]]; then
  die "ORACLE_UPDATERS is not set.

     Phase B would default it to the deployer, whose roles are renounced at
     handover -- an oracle that can never report. Set it to the address your
     price keeper signs with, and set ORACLE_QUORUM to match:

       export ORACLE_UPDATERS=0x<keeper address>
       export ORACLE_QUORUM=1

     To read the address the CURRENT keeper is posting from, ask the oracle it
     is already feeding -- the entry whose report is fresh is the live one:

       cast call \$NEXT_PUBLIC_ORACLE_ADDRESS 'updaters(uint256)(address)' 1 --rpc-url $RPC"
fi

IFS=',' read -ra _UPDATERS <<< "$ORACLE_UPDATERS"
for u in "${_UPDATERS[@]}"; do
  u="${u// /}"
  [[ "$u" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "ORACLE_UPDATERS entry '$u' is not an address."
  if [[ "${u,,}" == "${DEPLOYER,,}" ]]; then
    die "ORACLE_UPDATERS contains the deployer ($DEPLOYER).

     Its roles are renounced at handover, so it would sit in the updaters
     array holding no role: the oracle could never reach quorum and every
     vault would revert on its first NAV read.

     Set it to the address your price keeper signs with."
  fi
done

_QUORUM="${ORACLE_QUORUM:-${#_UPDATERS[@]}}"
[[ "$_QUORUM" -ge 1 && "$_QUORUM" -le "${#_UPDATERS[@]}" ]] \
  || die "ORACLE_QUORUM=$_QUORUM but only ${#_UPDATERS[@]} updater(s) are listed."

export ORACLE_UPDATERS
export ORACLE_QUORUM="$_QUORUM"
ok "oracle updaters: ${#_UPDATERS[@]}, quorum $_QUORUM, deployer not among them"

# A seated updater with no gas cannot post, which is the dead oracle again with
# an extra step. Warn rather than refuse -- it is fixable after the deploy.
for u in "${_UPDATERS[@]}"; do
  u="${u// /}"
  if [[ "$(cast balance "$u" --rpc-url "$RPC")" == "0" ]]; then
    warn "oracle updater $u has NO gas and cannot post prices."
    warn "Fund it from the faucet, or the vaults will revert on staleness."
  fi
done

# ─── 1. Fixtures ────────────────────────────────────────────────────────────
bold "1/4  Testnet fixtures"
echo "  Testnet has no USDG, no curated vaults and no DEX, so these stand in."

forge script script/DeployTestnetFixtures.s.sol:DeployTestnetFixtures \
  --rpc-url "$RPC" "${SIGNER[@]}" --sender "$DEPLOYER" --broadcast >/dev/null

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

# Export the legacy name too, so a script that has not been renamed yet still
# finds the address rather than dying after gas has been spent.
export USDC_TOKEN="$USDG_TOKEN"

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
  --rpc-url "$RPC" "${SIGNER[@]}" --sender "$DEPLOYER" --broadcast >/dev/null

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
         --rpc-url $RPC --account <GOVERNANCE_KEYSTORE>

     --account, not --private-key: exporting a governance key to a shell is how
     this project lost two of its own. Or paste the same call into Rabby.

  2. Accept treasury ownership.

     ProtocolTreasury uses Ownable2Step, so the transfer to the Timelock is
     pending until accepted. Queue acceptOwnership() through the Timelock at
     $TIMELOCK.

  Then start the site and work phases 3 and 5b of docs/LAUNCH-CHECKLIST.md:

       cd ../../zorpha-web && npm run dev

  Explorer: $EXPLORER/address/$DEPLOYER

NEXT

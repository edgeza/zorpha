#!/usr/bin/env bash
# Exercise the leadership layer end to end: bond, launch, seed the escrow.
#
# This is the differentiator, so it is the flow most worth testing. A leader
# posts a ZOR bond and first-loss capital in the vault's own asset, and gets a
# vault whose losses hit their capital before any depositor's. Nothing about it
# is permissionless-in-name-only: launchYieldVault has no role check, only the
# bond and the seed.
#
# Addresses are read off chain rather than passed in, because they are outputs
# of four separate deploy scripts and re-typing them is how you seed the wrong
# vault.
#
# Usage:
#   cast wallet import zorpha-gov --interactive     # once, prompts for the key
#   ./script/testnet-launch-vault.sh zorpha-gov
#
# Takes a keystore account name, not a private key: one password prompt per
# transaction beats retyping a key, and the key never reaches shell history.

set -euo pipefail

# foundryup installs to ~/.foundry/bin, which is on the PATH of the shell that
# ran it and often nowhere else -- so this script is frequently invoked from a
# shell where cast is missing even though foundry is installed. Look there
# before giving up.
if ! command -v cast >/dev/null; then
  if [[ -x "$HOME/.foundry/bin/cast" || -x "$HOME/.foundry/bin/cast.exe" ]]; then
    PATH="$HOME/.foundry/bin:$PATH"; export PATH
  else
    echo "ERROR: cast not found, and not at ~/.foundry/bin either." >&2
    echo "       Install foundry (foundryup), then reopen the shell." >&2
    exit 1
  fi
fi

ACCOUNT="${1:-}"
[[ -n "$ACCOUNT" ]] || {
  echo "usage: $0 <keystore-account-name>" >&2
  echo "  create one with: cast wallet import <name> --interactive" >&2
  exit 1
}

RPC="${RH_TESTNET_RPC_URL:-https://rpc.testnet.chain.robinhood.com/rpc}"
CHAIN_ID=46630
WEB_ENV="../../zorpha-web/.env.local"
FIXTURES="broadcast/DeployTestnetFixtures.s.sol/$CHAIN_ID/run-latest.json"

bold() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m+\033[0m %s\n' "$1"; }
die()  { printf '\n  \033[31mx %s\033[0m\n\n' "$1" >&2; exit 1; }

# Big-integer comparison, and NOT via bc: bc is absent from Git Bash on
# Windows, where this script actually runs. When it is missing, `echo "a < b" |
# bc` yields an empty string, `[[ "" == "1" ]]` is false, and the caller
# silently takes the "no action needed" branch -- which is how an earlier
# version skipped minting the seed and then reverted on a zero balance. A
# missing helper must fail loudly, so this uses node, which the deploy scripts
# already depend on, and errors if node is gone.
command -v node >/dev/null || die "node is required (the deploy scripts need it too)"
lt() { node -e 'process.exit(BigInt(process.argv[1]) < BigInt(process.argv[2]) ? 0 : 1)' -- "$1" "$2"; }

env_of() { grep -E "^$1=" "$WEB_ENV" | head -1 | cut -d= -f2-; }
num()    { awk '{print $1}'; }

[[ -f "$WEB_ENV" ]]  || die "no $WEB_ENV -- run the deploy first"
[[ -f "$FIXTURES" ]] || die "no $FIXTURES -- run the deploy first"

ZOR=$(env_of NEXT_PUBLIC_ZOR_ADDRESS)
LAUNCHER=$(env_of NEXT_PUBLIC_VAULT_LAUNCHER_ADDRESS)
TARGET=$(node -e '
  const j = require(process.argv[1]);
  const h = (j.transactions || []).find(t => t.contractName === "TestYieldTarget");
  process.stdout.write(h ? h.contractAddress : "");
' "./$FIXTURES")

[[ -n "$ZOR" && -n "$LAUNCHER" && -n "$TARGET" ]] || die "could not resolve addresses"

LEADER=$(cast wallet address --account "$ACCOUNT")
# The asset is whatever the venue settles in, not whatever we assume it is.
ASSET=$(cast call "$TARGET" 'asset()(address)' --rpc-url "$RPC")

bold "Leadership launch"
echo "  leader    $LEADER"
echo "  launcher  $LAUNCHER"
echo "  target    $TARGET"
echo "  asset     $ASSET"

# --- Preflight -------------------------------------------------------------
bold "Preflight"

FACTORY=$(cast call "$LAUNCHER" 'factory()(address)' --rpc-url "$RPC")
DEPLOYER_ROLE=$(cast keccak "DEPLOYER_ROLE")
HAS=$(cast call "$FACTORY" 'hasRole(bytes32,address)(bool)' "$DEPLOYER_ROLE" "$LAUNCHER" --rpc-url "$RPC")
[[ "$HAS" == "true" ]] || die "the launcher does not hold DEPLOYER_ROLE on $FACTORY.
     Grant it from the governance account, or launchYieldVault reverts."
ok "launcher holds DEPLOYER_ROLE"

APPROVED=$(cast call "$LAUNCHER" 'approvedTarget(address)(bool)' "$TARGET" --rpc-url "$RPC")
[[ "$APPROVED" == "true" ]] || die "$TARGET is not an approved target"
ok "target is approved"

BOND=$(cast call "$LAUNCHER" 'bondAmount()(uint256)'    --rpc-url "$RPC" | num)
SEED=$(cast call "$LAUNCHER" 'minSeedEscrow()(uint256)' --rpc-url "$RPC" | num)
ok "bond $(cast to-unit "$BOND" ether) ZOR, minimum seed $SEED (asset base units)"

ZOR_BAL=$(cast call "$ZOR" 'balanceOf(address)(uint256)' "$LEADER" --rpc-url "$RPC" | num)
if lt "$ZOR_BAL" "$BOND"; then
  die "leader holds $(cast to-unit "$ZOR_BAL" ether) ZOR, needs $(cast to-unit "$BOND" ether)"
fi
ok "leader holds $(cast to-unit "$ZOR_BAL" ether) ZOR, enough for the bond"

GAS=$(cast balance "$LEADER" --rpc-url "$RPC")
[[ "$GAS" != "0" ]] || die "leader has no gas"
ok "leader gas $(cast to-unit "$GAS" ether) ETH"

# --- 1. Seed asset ---------------------------------------------------------
# TestUSDG.mint is deliberately permissionless on testnet. On mainnet the seed
# is real capital and this step does not exist.
bold "1/4  Seed asset"
ASSET_BAL=$(cast call "$ASSET" 'balanceOf(address)(uint256)' "$LEADER" --rpc-url "$RPC" | num)
if lt "$ASSET_BAL" "$SEED"; then
  echo "  holds $ASSET_BAL, needs $SEED -- minting"
  cast send "$ASSET" 'mint(address,uint256)' "$LEADER" "$SEED" \
    --rpc-url "$RPC" --account "$ACCOUNT" >/dev/null
  # Read it back. A mint that silently did nothing would otherwise surface as
  # an opaque ERC20InsufficientBalance three transactions later.
  ASSET_BAL=$(cast call "$ASSET" 'balanceOf(address)(uint256)' "$LEADER" --rpc-url "$RPC" | num)
  if lt "$ASSET_BAL" "$SEED"; then
    die "minted, but the balance is still $ASSET_BAL (needs $SEED)"
  fi
  ok "minted, balance now $ASSET_BAL"
else
  ok "already holds $ASSET_BAL, no mint needed"
fi

bold "2/4  Approve the launcher for the ZOR bond"
cast send "$ZOR" 'approve(address,uint256)' "$LAUNCHER" "$BOND" \
  --rpc-url "$RPC" --account "$ACCOUNT" >/dev/null
ok "approved $(cast to-unit "$BOND" ether) ZOR"

bold "3/4  Approve the launcher for the seed"
cast send "$ASSET" 'approve(address,uint256)' "$LAUNCHER" "$SEED" \
  --rpc-url "$RPC" --account "$ACCOUNT" >/dev/null
ok "approved $SEED"

# --- 4. Launch -------------------------------------------------------------
# A random salt, because CREATE2 reverts on a collision and a fixed one would
# make this script single-use. A real leader picks a salt deliberately, to
# pre-compute and publish their vault address before launching.
SALT=0x$(openssl rand -hex 32 2>/dev/null || cast keccak "$(date +%s%N)$LEADER" | sed 's/^0x//')
NAME="${VAULT_NAME:-Zorpha Leader Test Vault}"
SYMBOL="${VAULT_SYMBOL:-zqLEAD}"

bold "4/4  Launch"
echo "  name   $NAME"
echo "  symbol $SYMBOL"
echo "  salt   $SALT"

cast send "$LAUNCHER" 'launchYieldVault(address,uint256,string,string,bytes32)' \
  "$TARGET" "$SEED" "$NAME" "$SYMBOL" "$SALT" \
  --rpc-url "$RPC" --account "$ACCOUNT" >/dev/null
ok "launched"

# --- Verify ----------------------------------------------------------------
# Read the result back off chain rather than trusting the receipt. The point of
# the exercise is that the escrow ends up funded and subordinated; a launch
# that succeeded without funding it would produce an identical receipt.
bold "Verify"

COUNT=$(cast call "$LAUNCHER" 'launchCount()(uint256)' --rpc-url "$RPC" | num)
# Launch ids are 1-indexed (id = launches.length, read after the push), so the
# public array getter wants one less than the count.
IDX=$((COUNT - 1))

# struct Launch { address vault; address escrow; address adapter;
#                 address leader; address asset; uint256 bond;
#                 uint64 createdAt; bool bondReleased; bool bondSlashed; }
RECORD=$(cast call "$LAUNCHER" \
  'launches(uint256)(address,address,address,address,address,uint256,uint64,bool,bool)' \
  "$IDX" --rpc-url "$RPC")

VAULT=$(echo "$RECORD"  | sed -n '1p' | num)
ESCROW=$(echo "$RECORD" | sed -n '2p' | num)
ADAPTER=$(echo "$RECORD"| sed -n '3p' | num)
RLEADER=$(echo "$RECORD"| sed -n '4p' | num)
RBOND=$(echo "$RECORD"  | sed -n '6p' | num)

ok "vault   $VAULT"
ok "escrow  $ESCROW"
ok "adapter $ADAPTER"

[[ "${RLEADER,,}" == "${LEADER,,}" ]] \
  || die "launch record names $RLEADER as leader, not $LEADER"
ok "leader recorded correctly"

VAULT_ESCROW=$(cast call "$VAULT" 'firstLossEscrow()(address)' --rpc-url "$RPC")
[[ "${VAULT_ESCROW,,}" == "${ESCROW,,}" ]] \
  || die "the vault points at $VAULT_ESCROW, the launch record at $ESCROW"
ok "the vault points at that escrow"

AVAILABLE=$(cast call "$ESCROW" 'available()(uint256)' --rpc-url "$RPC" | num)
[[ "$AVAILABLE" != "0" ]] || die "the escrow is EMPTY. Depositors would be unsubordinated."
ok "escrow holds $AVAILABLE of first-loss capital"

echo "  vault name        $(cast call "$VAULT" 'name()(string)' --rpc-url "$RPC")"
echo "  vault asset       $(cast call "$VAULT" 'asset()(address)' --rpc-url "$RPC")"
echo "  adequately covered $(cast call "$ESCROW" 'isAdequatelyCovered()(bool)' --rpc-url "$RPC")"
echo "  bond held         $(cast to-unit "$RBOND" ether) ZOR"

bold "Done"
echo "  The escrow holds the leader's first-loss capital. A loss in this vault"
echo "  hits that balance before any depositor's principal."
echo

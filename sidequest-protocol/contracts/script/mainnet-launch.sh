#!/usr/bin/env bash
#
# The mainnet launch. Both deploys, in order, with the checks between them.
#
# Written as one script rather than a runbook of environment variables because
# the token deploy is the one action in this project with no second attempt:
# MerkleDistributor fixes its root and deadline, ProtocolTreasury fixes both
# destinations, ZorphaVesting fixes its admin, and the token address is what
# every pool, listing and integration points at afterwards. A mistyped env var
# there is a migration, not a retry.
#
# Everything here has been rehearsed against a fork of this exact chain with
# these exact addresses -- see test/fork/LaunchRehearsal.t.sol.
#
#   ZORPHA_PASSWORD_FILE is deliberately NOT supported. This keystore holds the
#   entire supply for one transaction; its passphrase should be typed, not read
#   from a file that outlives the run.
set -euo pipefail

ACCOUNT="${1:-mainnet-deploy}"
RPC="${RH_MAINNET_RPC_URL:-https://rpc.mainnet.chain.robinhood.com}"

# --- The configuration, in one place, visible before anything is sent ------
export GOVERNANCE=0xC75E64Ccf3ce6E2F40939Ab58255681769BcF8C4
export LIQUIDITY_RECIPIENT=0xC75E64Ccf3ce6E2F40939Ab58255681769BcF8C4
export USDG_TOKEN=0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168
export AIRDROP_MERKLE_ROOT=0x82f08a3e5c2343714663a14670596246566ee2a13c6dbc5e032e519e820f8797
export TIMELOCK_DELAY=172800
export BUYBACK_THRESHOLD_USDG=1000000000
export APPROVED_YIELD_TARGETS=0xBeEff033F34C046626B8D0A041844C5d1A5409dd

bold() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m+\033[0m %s\n' "$1"; }
info() { printf '    %s\n' "$1"; }
warn() { printf '  \033[33m~\033[0m %s\n' "$1"; }
die()  { printf '\n  \033[31mx %s\033[0m\n' "$1" >&2; exit 1; }

num() { awk '{print $1}'; }
gwei() { node -e 'process.stdout.write((Number(process.argv[1])/1e9).toFixed(3))' "$1"; }

CHAIN=$(cast chain-id --rpc-url "$RPC")
[[ "$CHAIN" == "4663" ]] || die "this is chain $CHAIN, not mainnet 4663"

# DEPLOYER_ADDRESS skips one passphrase prompt.
#
# This script asks three times: once here to learn the address, then once per
# forge script to sign. Each is a chance to mistype, and a typo on the second
# loses the whole run -- which is exactly what happened on the first real
# attempt, after the simulation had already succeeded.
#
# The address is public and derived from the keystore, so supplying it costs
# nothing in safety and removes a prompt. If it disagrees with the keystore the
# deploy would fail at --sender rather than doing something subtle, and the
# broadcast checks below would catch it either way.
if [[ -n "${DEPLOYER_ADDRESS:-}" ]]; then
  DEPLOYER=$(cast to-check-sum-address "$DEPLOYER_ADDRESS")
else
  DEPLOYER=$(cast wallet address --account "$ACCOUNT")
fi
BAL=$(cast balance "$DEPLOYER" --rpc-url "$RPC")
GP=$(cast gas-price --rpc-url "$RPC")

bold "Zorpha mainnet launch"
info "chain        4663"
info "deployer     $DEPLOYER"
info "balance      $(cast to-unit "$BAL" ether) ETH"
info "gas          $(gwei "$GP") gwei"
info "governance   $GOVERNANCE"
info "liquidity to $GOVERNANCE"
info "airdrop root $AIRDROP_MERKLE_ROOT"
info "venue        $APPROVED_YIELD_TARGETS  (Steakhouse USDG)"

# The claim window opens now. Ninety days is long enough that a distributor
# swap is never forced by the clock, and short enough that unclaimed supply
# returns to governance in a reasonable time.
export AIRDROP_CLAIM_DEADLINE=$(( $(cast block latest --field timestamp --rpc-url "$RPC") + 7776000 ))
info "claims close $(date -u -d "@$AIRDROP_CLAIM_DEADLINE" '+%Y-%m-%d %H:%M UTC')"

[[ "$GOVERNANCE" != "$DEPLOYER" ]] || die "GOVERNANCE is the deploy key"
CODE=$(cast code "$GOVERNANCE" --rpc-url "$RPC")
[[ ${#CODE} -gt 2 ]] || die "GOVERNANCE has no code -- the mainnet liquidity guard will refuse this"
ok "governance is a contract, and is not the deployer"

# --- Can it afford BOTH? --------------------------------------------------
#
# Checked before the first send, because the failure that matters is running
# out between the two: the token would exist, immutably, with no launchpad
# pointing at it, and the second half would need a top-up and a re-run.
NEED=$(node -e 'const g=7347540n+13709610n;process.stdout.write((g*BigInt(process.argv[1])).toString())' "$GP")
node -e 'process.exit(BigInt(process.argv[1]) >= BigInt(process.argv[2]) ? 0 : 1)' "$BAL" "$NEED" \
  || die "balance $(cast to-unit "$BAL" ether) ETH is below the $(cast to-unit "$NEED" ether) ETH both deploys need at $(gwei "$GP") gwei.
     Top up, or wait for gas to fall -- it has ranged 0.38 to 2.23 gwei today."
HEAD=$(node -e 'process.stdout.write((Number(BigInt(process.argv[1]))/Number(BigInt(process.argv[2]))).toFixed(1))' "$BAL" "$NEED")

# WAIT_FOR_GAS=1 turns the affordability check from a refusal into a wait.
#
# This chain is an Arbitrum Orbit rollup, so its base fee decays after a
# congestion spike rather than staying high. Observed on 4 September: 5.38 gwei
# falling to 3.12 within ninety seconds, against 0.38 for most of the day. The
# right response to an unaffordable moment is usually to wait a few minutes, and
# an operator polling by hand tends to either give up or overpay.
if [[ -n "${WAIT_FOR_GAS:-}" ]]; then
  AFFORD=$(node -e 'process.stdout.write((BigInt(process.argv[1]) / (7347540n+13709610n)).toString())' "$BAL")
  info "waiting for gas at or below $(gwei "$AFFORD") gwei, which is what this balance affords"
  while :; do
    GP=$(cast gas-price --rpc-url "$RPC")
    if node -e 'process.exit(BigInt(process.argv[1]) <= BigInt(process.argv[2]) ? 0 : 1)' "$GP" "$AFFORD"; then
      ok "gas is $(gwei "$GP") gwei"
      break
    fi
    info "$(date -u +%H:%M:%S)  $(gwei "$GP") gwei -- still above $(gwei "$AFFORD"), waiting"
    sleep 30
  done
  NEED=$(node -e 'const g=7347540n+13709610n;process.stdout.write((g*BigInt(process.argv[1])).toString())' "$GP")
  HEAD=$(node -e 'process.stdout.write((Number(BigInt(process.argv[1]))/Number(BigInt(process.argv[2]))).toFixed(1))' "$BAL" "$NEED")
fi
if node -e 'process.exit(Number(process.argv[1]) < 2 ? 0 : 1)' "$HEAD"; then
  warn "only ${HEAD}x headroom at $(gwei "$GP") gwei. A spike between the two deploys would"
  info "strand the token without its launchpad. Consider waiting for cheaper gas."
else
  ok "${HEAD}x headroom for both deploys"
fi

# --- Confirmation ---------------------------------------------------------
#
# One prompt, once, naming the irreversible part. Everything above this line
# is read-only.
bold "This is irreversible"
echo "  The token deploy mints the entire supply and distributes it in one"
echo "  transaction. The token address, the airdrop root, the treasury"
echo "  destinations and the vesting admin are all immutable afterwards."
echo
read -r -p "  Type LAUNCH to proceed: " CONFIRM
[[ "$CONFIRM" == "LAUNCH" ]] || die "not confirmed, nothing was sent"

# --- 1. The token layer ---------------------------------------------------
#
# RESUMABLE, and this is not a nicety.
#
# If step 2 runs out of gas the token is already deployed, immutably. The
# obvious recovery -- top up and re-run -- would, without this check, deploy a
# SECOND ZOR: a duplicate address with the whole supply minted again, no way to
# retire the first, and two tokens with equal claim to the name. The previous
# version of this script PROMISED a resume in its error message and did not
# implement one, which is worse than not offering it at all.
#
# The broadcast file alone is not proof: it records what was SENT, not what
# landed. The address is confirmed to hold code and report a supply before
# step 1 is skipped.
BC=broadcast/DeployZorphaToken.s.sol/4663/run-latest.json
ZOR=""
if [[ -f "$BC" ]]; then
  PRIOR=$(node -e '
    const j=require(process.argv[1]);
    const t=(j.transactions||[]).find(x=>x.contractName==="Zorpha");
    process.stdout.write(t?t.contractAddress:"");
  ' "./$BC" 2>/dev/null || true)
  if [[ -n "$PRIOR" ]]; then
    PCODE=$(cast code "$PRIOR" --rpc-url "$RPC" 2>/dev/null || echo 0x)
    if [[ ${#PCODE} -gt 2 ]]; then
      PSUP=$(cast call "$PRIOR" 'totalSupply()(uint256)' --rpc-url "$RPC" 2>/dev/null | num || echo 0)
      [[ "$PSUP" != "0" ]] || die "a contract exists at $PRIOR from a previous run but reports no
     supply. Investigate before deploying anything else -- a second token is not
     the answer to a first one that went wrong."
      ZOR="$PRIOR"
      bold "1/2  Token layer -- ALREADY DEPLOYED"
      ok "ZOR exists at $ZOR, supply $PSUP"
      info "skipping step 1; deploying again would mint a second, duplicate supply"
    fi
  fi
fi

if [[ -z "$ZOR" ]]; then
  bold "1/2  Token layer"
  forge script script/DeployZorphaToken.s.sol:DeployZorphaToken \
    --rpc-url "$RPC" --account "$ACCOUNT" --sender "$DEPLOYER" --broadcast --slow

  ZOR=$(node -e '
    const j=require("./broadcast/DeployZorphaToken.s.sol/4663/run-latest.json");
    const t=(j.transactions||[]).find(x=>x.contractName==="Zorpha");
    process.stdout.write(t?t.contractAddress:"");
  ')
  [[ -n "$ZOR" ]] || die "could not read the ZOR address from the broadcast"
  ok "ZOR deployed at $ZOR"
fi

TIMELOCK=$(node -e '
  const j=require("./broadcast/DeployZorphaToken.s.sol/4663/run-latest.json");
  const t=(j.transactions||[]).find(x=>x.contractName==="Timelock");
  process.stdout.write(t?t.contractAddress:"");
')
TREASURY=$(node -e '
  const j=require("./broadcast/DeployZorphaToken.s.sol/4663/run-latest.json");
  const t=(j.transactions||[]).find(x=>x.contractName==="ProtocolTreasury");
  process.stdout.write(t?t.contractAddress:"");
')
[[ -n "$TIMELOCK" && -n "$TREASURY" ]] || die "could not read the timelock or treasury address"

# Read back off chain rather than trusting the broadcast file.
SUPPLY=$(cast call "$ZOR" 'totalSupply()(uint256)' --rpc-url "$RPC" | num)
HELD=$(cast call "$ZOR" 'balanceOf(address)(uint256)' "$DEPLOYER" --rpc-url "$RPC" | num)
[[ "$HELD" == "0" ]] || die "the deploy key still holds $HELD ZOR"
ok "supply $SUPPLY, and the deploy key holds none of it"
ok "timelock $TIMELOCK"
ok "treasury $TREASURY"

# --- Gas, again -----------------------------------------------------------
GP2=$(cast gas-price --rpc-url "$RPC")
BAL2=$(cast balance "$DEPLOYER" --rpc-url "$RPC")
NEED2=$(node -e 'process.stdout.write((13709610n*BigInt(process.argv[1])).toString())' "$GP2")
info "gas is now $(gwei "$GP2") gwei; the launchpad needs $(cast to-unit "$NEED2" ether) ETH"
node -e 'process.exit(BigInt(process.argv[1]) >= BigInt(process.argv[2]) ? 0 : 1)' "$BAL2" "$NEED2" \
  || die "the token is deployed at $ZOR, but there is not enough left for the launchpad.
     Nothing is lost: top up $DEPLOYER and re-run this script -- it will skip
     straight to step 2, because the token deploy is already recorded."

# --- 2. The launchpad -----------------------------------------------------
bold "2/2  Launchpad"
export ZOR_TOKEN="$ZOR"
export TIMELOCK="$TIMELOCK"
export TREASURY="$TREASURY"

forge script script/DeployMinimal.s.sol:DeployMinimal \
  --rpc-url "$RPC" --account "$ACCOUNT" --sender "$DEPLOYER" --broadcast --slow

FACTORY=$(node -e '
  const j=require("./broadcast/DeployMinimal.s.sol/4663/run-latest.json");
  const t=(j.transactions||[]).find(x=>x.contractName==="VaultFactory");
  process.stdout.write(t?t.contractAddress:"");
')
LAUNCHER=$(node -e '
  const j=require("./broadcast/DeployMinimal.s.sol/4663/run-latest.json");
  const t=(j.transactions||[]).find(x=>x.contractName==="VaultLauncher");
  process.stdout.write(t?t.contractAddress:"");
')
[[ -n "$FACTORY" && -n "$LAUNCHER" ]] || die "could not read the factory or launcher address"

DR=$(cast call "$FACTORY" 'DEPLOYER_ROLE()(bytes32)' --rpc-url "$RPC")
[[ "$(cast call "$FACTORY" 'hasRole(bytes32,address)(bool)' "$DR" "$LAUNCHER" --rpc-url "$RPC")" == "true" ]] \
  || die "the launcher cannot deploy vaults -- the launchpad is inert"
ok "factory  $FACTORY"
ok "launcher $LAUNCHER, and it can deploy vaults"

# --- Done -----------------------------------------------------------------
FINAL=$(cast balance "$DEPLOYER" --rpc-url "$RPC")
bold "Launched"
echo "  ZOR        $ZOR"
echo "  Timelock   $TIMELOCK"
echo "  Treasury   $TREASURY"
echo "  Factory    $FACTORY"
echo "  Launcher   $LAUNCHER"
echo "  Governance $GOVERNANCE"
echo
echo "  spent  $(node -e 'const a=BigInt(process.argv[1]),b=BigInt(process.argv[2]);process.stdout.write((Number(a-b)/1e18).toFixed(6))' "$BAL" "$FINAL") ETH"
echo "  left   $(cast to-unit "$FINAL" ether) ETH"
echo
echo "  NEXT, IN ORDER:"
echo "  1. The governance Safe claims the airdrop tranche:"
echo "       claim(0, $GOVERNANCE, <tranche>, [])"
echo "     An EMPTY proof -- the tree has one leaf, so the leaf is the root."
echo "  2. Queue ProtocolTreasury.acceptOwnership() through the timelock. Until"
echo "     it executes, $DEPLOYER still owns the treasury and can call rescue()."
echo "  3. Repoint the portal, the indexer and Supabase at these addresses."
echo "  4. Add a second owner to the Safe. It holds 96% of supply behind one key."

#!/usr/bin/env bash
# Prove the first-loss waterfall on a live chain.
#
# testnet-launch-vault.sh shows the escrow gets FUNDED. This shows it ABSORBS,
# which is the part the whole protocol is for and the part that was previously
# untestable on testnet: TestYieldTarget can only accrue, so there was no way to
# make a venue lose money. LossyYieldTarget exists for this drill.
#
# The mechanism, and what each step below is checking:
#
#   totalAssets() = rawAssets() + escrowSupport()
#
# When the venue loses value, rawAssets() falls but escrowSupport() rises to
# meet the high-water mark, so totalAssets() -- and therefore the share price --
# does not move while the leader's capital can cover it. That is the protection,
# and it is visible BEFORE anyone withdraws. On withdrawal the vault holds less
# than it owes and FirstLossEscrow.absorb() makes up the difference.
#
# Usage:
#   ./script/testnet-loss-drill.sh zorpha-gov
#
# The account acts as both leader and depositor. That is not a weaker test: the
# assertions are on the escrow balance and on rawAssets vs totalAssets, which
# are unambiguous regardless of who holds the shares.

set -euo pipefail

# This drill needs forge as well as cast, and they can be missing separately.
if ! command -v cast >/dev/null || ! command -v forge >/dev/null; then
  if [[ -d "$HOME/.foundry/bin" ]]; then
    PATH="$HOME/.foundry/bin:$PATH"; export PATH
  fi
fi
for tool in cast forge; do
  command -v "$tool" >/dev/null || {
    echo "ERROR: $tool not found, and not at ~/.foundry/bin either." >&2
    echo "       Install foundry (foundryup), then reopen the shell." >&2
    exit 1
  }
done

ACCOUNT="${1:-}"
[[ -n "$ACCOUNT" ]] || { echo "usage: $0 <keystore-account-name>" >&2; exit 1; }

RPC="${RH_TESTNET_RPC_URL:-https://rpc.testnet.chain.robinhood.com/rpc}"
CHAIN_ID=46630
WEB_ENV="../../zorpha-web/.env.local"
# Deploying the fixture is the only irreversible step, so its address is cached
# and a re-run reuses it rather than littering the chain with venues.
CACHE=".lossy-target-$CHAIN_ID"

bold() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m+\033[0m %s\n' "$1"; }
info() { printf '    %s\n' "$1"; }
die()  { printf '\n  \033[31mx %s\033[0m\n\n' "$1" >&2; exit 1; }

command -v node >/dev/null || die "node is required"
lt()  { node -e 'process.exit(BigInt(process.argv[1]) < BigInt(process.argv[2]) ? 0 : 1)' "$1" "$2"; }
sub() { node -e 'process.stdout.write((BigInt(process.argv[1]) - BigInt(process.argv[2])).toString())' "$1" "$2"; }
eq()  { [[ "$1" == "$2" ]]; }

env_of() { grep -E "^$1=" "$WEB_ENV" | head -1 | cut -d= -f2-; }
num()    { awk '{print $1}'; }
call()   { cast call "$@" --rpc-url "$RPC" | num; }

[[ -f "$WEB_ENV" ]] || die "no $WEB_ENV -- run the deploy first"

ZOR=$(env_of NEXT_PUBLIC_ZOR_ADDRESS)
LAUNCHER=$(env_of NEXT_PUBLIC_VAULT_LAUNCHER_ADDRESS)
ACTOR=$(cast wallet address --account "$ACCOUNT")

# --- 0. The lossy venue ----------------------------------------------------
bold "0/6  A venue that can lose money"

# Reuse the asset every other fixture already uses, so the drill runs against
# the same token the real vaults hold rather than a parallel universe.
FIXTURES="broadcast/DeployTestnetFixtures.s.sol/$CHAIN_ID/run-latest.json"
ASSET=$(node -e '
  const j = require(process.argv[1]);
  const h = (j.transactions || []).find(t => t.contractName === "TestUSDG");
  process.stdout.write(h ? h.contractAddress : "");
' "./$FIXTURES")
[[ -n "$ASSET" ]] || die "could not find TestUSDG in $FIXTURES"

if [[ -f "$CACHE" ]] && [[ -n "$(cat "$CACHE")" ]]; then
  LOSSY=$(cat "$CACHE")
  CODE=$(cast code "$LOSSY" --rpc-url "$RPC")
  [[ ${#CODE} -gt 2 ]] || die "cached $LOSSY has no code; delete $CACHE and re-run"
  ok "reusing $LOSSY"
else
  info "deploying LossyYieldTarget..."
  # --constructor-args LAST, always. It is variadic, so anything after it is
  # read as another constructor argument -- including flags. With it in the
  # middle, --rpc-url never registers and forge falls back to localhost:8545
  # with no warning that it ignored the network you asked for.
  OUT=$(forge create src/testnet/TestnetFixtures.sol:LossyYieldTarget \
        --rpc-url "$RPC" --account "$ACCOUNT" --broadcast --json \
        --constructor-args "$ASSET")
  LOSSY=$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).deployedTo || "")' "$OUT")
  [[ -n "$LOSSY" ]] || die "could not read the deployed address from forge create"
  printf '%s' "$LOSSY" > "$CACHE"
  ok "deployed $LOSSY"
fi

# --- 1. Approve it ---------------------------------------------------------
bold "1/6  Approve the venue"
if [[ "$(call "$LAUNCHER" 'approvedTarget(address)(bool)' "$LOSSY")" == "true" ]]; then
  ok "already approved"
else
  cast send "$LAUNCHER" 'setTargetApproved(address,bool)' "$LOSSY" true \
    --rpc-url "$RPC" --account "$ACCOUNT" >/dev/null
  ok "approved"
fi

BOND=$(call "$LAUNCHER" 'bondAmount()(uint256)')
SEED=$(call "$LAUNCHER" 'minSeedEscrow()(uint256)')
DEPOSIT="${DEPOSIT_AMOUNT:-$SEED}"
# A loss the escrow can absorb in full. The partial-coverage case -- where the
# depositor takes the remainder -- is covered by the fuzz test in
# FirstLossEscrow.t.sol; this drill is about proving the path runs at all.
LOSS="${LOSS_AMOUNT:-$(node -e 'process.stdout.write((BigInt(process.argv[1])/5n).toString())' "$DEPOSIT")}"

info "bond $(cast to-unit "$BOND" ether) ZOR, seed $SEED, deposit $DEPOSIT, loss $LOSS"

# --- 2. Launch -------------------------------------------------------------
bold "2/6  Launch a vault against it"

NEED=$(node -e 'process.stdout.write((BigInt(process.argv[1])+BigInt(process.argv[2])).toString())' "$SEED" "$DEPOSIT")
HAVE=$(call "$ASSET" 'balanceOf(address)(uint256)' "$ACTOR")
if lt "$HAVE" "$NEED"; then
  cast send "$ASSET" 'mint(address,uint256)' "$ACTOR" "$NEED" \
    --rpc-url "$RPC" --account "$ACCOUNT" >/dev/null
  ok "minted $NEED"
fi

cast send "$ZOR"   'approve(address,uint256)' "$LAUNCHER" "$BOND" --rpc-url "$RPC" --account "$ACCOUNT" >/dev/null
cast send "$ASSET" 'approve(address,uint256)' "$LAUNCHER" "$SEED" --rpc-url "$RPC" --account "$ACCOUNT" >/dev/null

SALT=0x$(openssl rand -hex 32)
cast send "$LAUNCHER" 'launchYieldVault(address,uint256,string,string,bytes32)' \
  "$LOSSY" "$SEED" "Zorpha Loss Drill Vault" "zqDRILL" "$SALT" \
  --rpc-url "$RPC" --account "$ACCOUNT" >/dev/null

COUNT=$(call "$LAUNCHER" 'launchCount()(uint256)')
RECORD=$(cast call "$LAUNCHER" \
  'launches(uint256)(address,address,address,address,address,uint256,uint64,bool,bool)' \
  "$((COUNT - 1))" --rpc-url "$RPC")
VAULT=$(echo "$RECORD"  | sed -n '1p' | num)
ESCROW=$(echo "$RECORD" | sed -n '2p' | num)
ok "vault  $VAULT"
ok "escrow $ESCROW"

ESCROW_START=$(call "$ESCROW" 'available()(uint256)')
eq "$ESCROW_START" "$SEED" || die "escrow holds $ESCROW_START, expected the $SEED seed"
ok "escrow seeded with $ESCROW_START"

# --- 3. Deposit ------------------------------------------------------------
bold "3/6  Deposit"
cast send "$ASSET" 'approve(address,uint256)' "$VAULT" "$DEPOSIT" --rpc-url "$RPC" --account "$ACCOUNT" >/dev/null
cast send "$VAULT" 'deposit(uint256,address)' "$DEPOSIT" "$ACTOR" --rpc-url "$RPC" --account "$ACCOUNT" >/dev/null

SHARES=$(call "$VAULT" 'balanceOf(address)(uint256)' "$ACTOR")
RAW0=$(call "$VAULT" 'rawAssets()(uint256)')
SUP0=$(call "$VAULT" 'escrowSupport()(uint256)')
TOT0=$(call "$VAULT" 'totalAssets()(uint256)')
NAV0=$(call "$VAULT" 'getNavPerShare()(uint256)')

ok "shares      $SHARES"
ok "rawAssets   $RAW0"
ok "escrowSupport $SUP0  (nothing to support yet)"
ok "totalAssets $TOT0"
ok "nav/share   $NAV0"
eq "$SUP0" "0" || die "the escrow is supporting $SUP0 before any loss has happened"

# --- 4. The loss -----------------------------------------------------------
bold "4/6  Make the venue lose $LOSS"
cast send "$LOSSY" 'lose(uint256)' "$LOSS" --rpc-url "$RPC" --account "$ACCOUNT" >/dev/null

RAW1=$(call "$VAULT" 'rawAssets()(uint256)')
SUP1=$(call "$VAULT" 'escrowSupport()(uint256)')
TOT1=$(call "$VAULT" 'totalAssets()(uint256)')
NAV1=$(call "$VAULT" 'getNavPerShare()(uint256)')

info "rawAssets     $RAW0 -> $RAW1"
info "escrowSupport $SUP0 -> $SUP1"
info "totalAssets   $TOT0 -> $TOT1"
info "nav/share     $NAV0 -> $NAV1"

lt "$RAW1" "$RAW0" || die "rawAssets did not fall; the venue did not actually lose anything"
ok "the venue lost value: rawAssets fell by $(sub "$RAW0" "$RAW1")"

[[ "$SUP1" != "0" ]] || die "escrowSupport is still 0 -- the leader's capital is NOT backing this vault"
ok "the leader's capital stepped in: escrowSupport is now $SUP1"

# This is the assertion that matters. If totalAssets moved, the depositor
# already took the loss and the subordination did nothing.
eq "$TOT1" "$TOT0" || die "totalAssets moved $TOT0 -> $TOT1. The depositor absorbed the loss, not the leader."
ok "totalAssets UNCHANGED at $TOT1 -- the depositor has not lost anything"
eq "$NAV1" "$NAV0" || die "nav/share moved $NAV0 -> $NAV1"
ok "nav/share UNCHANGED at $NAV1"

# --- 5. Withdraw -----------------------------------------------------------
bold "5/6  Redeem everything"
BEFORE=$(call "$ASSET" 'balanceOf(address)(uint256)' "$ACTOR")
cast send "$VAULT" 'redeem(uint256,address,address)' "$SHARES" "$ACTOR" "$ACTOR" \
  --rpc-url "$RPC" --account "$ACCOUNT" >/dev/null
AFTER=$(call "$ASSET" 'balanceOf(address)(uint256)' "$ACTOR")
RECEIVED=$(sub "$AFTER" "$BEFORE")

ok "received $RECEIVED for $SHARES shares"
lt "$RECEIVED" "$RAW1" && die "received $RECEIVED, less than the vault's own $RAW1 -- absorption did not happen"
ok "received more than the vault held on its own ($RAW1)"

# --- 6. The escrow paid ----------------------------------------------------
bold "6/6  Who paid"
ESCROW_END=$(call "$ESCROW" 'available()(uint256)')
PAID=$(sub "$ESCROW_START" "$ESCROW_END")

info "escrow  $ESCROW_START -> $ESCROW_END"
info "paid    $PAID"

[[ "$PAID" != "0" ]] || die "the escrow paid NOTHING. The waterfall did not run."
ok "the leader's capital paid $PAID so the depositor did not have to"

bold "Drill passed"
echo "  The venue lost $LOSS. The depositor got $RECEIVED back and the leader's"
echo "  escrow fell by $PAID. That is the subordination working on a live chain,"
echo "  not in a test with a mocked venue."
echo

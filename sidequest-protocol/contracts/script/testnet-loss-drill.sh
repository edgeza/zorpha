#!/usr/bin/env bash
# Prove the first-loss waterfall on a live chain, in both regimes.
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
# Two regimes, one formula. With UNCOVERED = max(0, loss - escrow):
#
#   full coverage     loss <= escrow   totalAssets unchanged, escrow pays loss
#   partial coverage  loss >  escrow   totalAssets falls by exactly UNCOVERED,
#                                      escrow pays everything it has, and the
#                                      depositor takes only the remainder
#
# Both are asserted with the same arithmetic. The second is the case the fuzz
# test testFuzz_DepositorNeverLosesMoreThanTheUncoveredShortfall covers off
# chain; here it runs against the real adapter.
#
# Usage:
#   ./script/testnet-loss-drill.sh zorpha-gov                        # full
#   DEPOSIT_AMOUNT=2000000000 LOSS_AMOUNT=1500000000 \
#     ./script/testnet-loss-drill.sh zorpha-gov                      # partial
#
# For partial coverage the deposit must exceed the seed, because the venue can
# only lose what it holds, and the seed is 1,000 USDG. The script checks.
#
# The account acts as both leader and depositor. The assertions are on the
# escrow balance and on rawAssets vs totalAssets, which are unambiguous
# regardless of who holds the shares.

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
bi()  { MSYS_NO_PATHCONV=1 node -e 'const [a,op,b]=process.argv.slice(1);const A=BigInt(a),B=BigInt(b);
  const f={add:()=>A+B,sub:()=>A-B,mul:()=>A*B,div:()=>A/B,
           min:()=>A<B?A:B,max:()=>A>B?A:B}[op];
  if(!f) throw new Error("unknown op: "+op);
  process.stdout.write(f().toString())' -- "$1" "$2" "$3"; }
lt()  { MSYS_NO_PATHCONV=1 node -e 'process.exit(BigInt(process.argv[1]) < BigInt(process.argv[2]) ? 0 : 1)' -- "$1" "$2"; }
eq()  { [[ "$1" == "$2" ]]; }

# `|| true` is load-bearing under `set -euo pipefail`. grep exits 1 when it
# finds nothing, pipefail propagates that, and the assignment then kills the
# script -- BEFORE the `[[ -n "$X" ]] || die` meant to report the missing key.
# A drill died three times printing nothing at all this way, with its own
# diagnostic sitting unreachable two lines below.
env_of() { grep -E "^$1=" "$WEB_ENV" | head -1 | cut -d= -f2- || true; }
num()    { awk '{print $1}'; }
call()   { cast call "$@" --rpc-url "$RPC" | num; }
send()   { cast send "$@" --rpc-url "$RPC" --account "$ACCOUNT" >/dev/null; }

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
  send "$LAUNCHER" 'setTargetApproved(address,bool)' "$LOSSY" true
  ok "approved"
fi

BOND=$(call "$LAUNCHER" 'bondAmount()(uint256)')
SEED=$(call "$LAUNCHER" 'minSeedEscrow()(uint256)')
DEPOSIT="${DEPOSIT_AMOUNT:-$SEED}"
LOSS="${LOSS_AMOUNT:-$(bi "$DEPOSIT" div 5)}"

# The venue holds only the deposit (the seed sits in the escrow, not the
# venue), so it cannot lose more than that.
lt "$DEPOSIT" "$LOSS" && die "LOSS_AMOUNT ($LOSS) exceeds DEPOSIT_AMOUNT ($DEPOSIT); the venue cannot lose what it does not hold"

UNCOVERED=$(bi "$(bi "$LOSS" sub "$SEED")" max 0)
if eq "$UNCOVERED" 0; then MODE="full coverage"; else MODE="PARTIAL coverage, $UNCOVERED uncovered"; fi

info "bond $(cast to-unit "$BOND" ether) ZOR, seed $SEED, deposit $DEPOSIT, loss $LOSS"
info "regime: $MODE"

# --- 2. Launch -------------------------------------------------------------
bold "2/6  Launch a vault against it"

NEED=$(bi "$SEED" add "$DEPOSIT")
HAVE=$(call "$ASSET" 'balanceOf(address)(uint256)' "$ACTOR")
if lt "$HAVE" "$NEED"; then
  send "$ASSET" 'mint(address,uint256)' "$ACTOR" "$NEED"
  ok "minted $NEED"
fi

send "$ZOR"   'approve(address,uint256)' "$LAUNCHER" "$BOND"
send "$ASSET" 'approve(address,uint256)' "$LAUNCHER" "$SEED"

SALT=0x$(openssl rand -hex 32)
send "$LAUNCHER" 'launchYieldVault(address,uint256,string,string,bytes32)' \
  "$LOSSY" "$SEED" "Zorpha Loss Drill Vault" "zqDRILL" "$SALT"

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
send "$ASSET" 'approve(address,uint256)' "$VAULT" "$DEPOSIT"
send "$VAULT" 'deposit(uint256,address)' "$DEPOSIT" "$ACTOR"

SHARES=$(call "$VAULT" 'balanceOf(address)(uint256)' "$ACTOR")
RAW0=$(call "$VAULT" 'rawAssets()(uint256)')
SUP0=$(call "$VAULT" 'escrowSupport()(uint256)')
TOT0=$(call "$VAULT" 'totalAssets()(uint256)')
NAV0=$(call "$VAULT" 'getNavPerShare()(uint256)')

ok "shares        $SHARES"
ok "rawAssets     $RAW0"
ok "escrowSupport $SUP0  (nothing to support yet)"
ok "totalAssets   $TOT0"
ok "nav/share     $NAV0"
eq "$SUP0" "0" || die "the escrow is supporting $SUP0 before any loss has happened"

# --- 4. The loss -----------------------------------------------------------
bold "4/6  Make the venue lose $LOSS"
send "$LOSSY" 'lose(uint256)' "$LOSS"

RAW1=$(call "$VAULT" 'rawAssets()(uint256)')
SUP1=$(call "$VAULT" 'escrowSupport()(uint256)')
TOT1=$(call "$VAULT" 'totalAssets()(uint256)')
NAV1=$(call "$VAULT" 'getNavPerShare()(uint256)')

info "rawAssets     $RAW0 -> $RAW1"
info "escrowSupport $SUP0 -> $SUP1"
info "totalAssets   $TOT0 -> $TOT1"
info "nav/share     $NAV0 -> $NAV1"

lt "$RAW1" "$RAW0" || die "rawAssets did not fall; the venue did not actually lose anything"
ok "the venue lost value: rawAssets fell by $(bi "$RAW0" sub "$RAW1")"

EXPECTED_SUPPORT=$(bi "$LOSS" min "$ESCROW_START")
eq "$SUP1" "$EXPECTED_SUPPORT" \
  || die "escrowSupport is $SUP1, expected $EXPECTED_SUPPORT (min of loss and escrow)"
ok "the leader's capital stepped in: escrowSupport is $SUP1"

# THE assertion, in both regimes. totalAssets may fall by the uncovered part
# and not one unit more. If it fell further, the depositor absorbed a loss the
# leader's capital should have taken. If it fell less, the vault is reporting
# assets it does not have.
EXPECTED_TOT=$(bi "$TOT0" sub "$UNCOVERED")
eq "$TOT1" "$EXPECTED_TOT" \
  || die "totalAssets $TOT0 -> $TOT1, expected $EXPECTED_TOT. The depositor bore $(bi "$TOT0" sub "$TOT1") of a $LOSS loss with $ESCROW_START of escrow."
if eq "$UNCOVERED" 0; then
  ok "totalAssets UNCHANGED at $TOT1 -- the depositor has not lost anything"
  eq "$NAV1" "$NAV0" || die "nav/share moved $NAV0 -> $NAV1 under full coverage"
  ok "nav/share UNCHANGED at $NAV1"
else
  ok "totalAssets fell by exactly the uncovered $UNCOVERED and no more"
  lt "$NAV1" "$NAV0" || die "nav/share did not fall under partial coverage"
  ok "nav/share fell, as it must once the buffer is exhausted"
fi

# --- 5. Withdraw -----------------------------------------------------------
bold "5/6  Redeem everything"
BEFORE=$(call "$ASSET" 'balanceOf(address)(uint256)' "$ACTOR")
send "$VAULT" 'redeem(uint256,address,address)' "$SHARES" "$ACTOR" "$ACTOR"
AFTER=$(call "$ASSET" 'balanceOf(address)(uint256)' "$ACTOR")
RECEIVED=$(bi "$AFTER" sub "$BEFORE")
DEPOSITOR_LOSS=$(bi "$DEPOSIT" sub "$RECEIVED")

ok "received $RECEIVED for $SHARES shares"
info "depositor's loss $DEPOSITOR_LOSS  (uncovered part of the venue's loss: $UNCOVERED)"
lt "$RECEIVED" "$RAW1" && die "received $RECEIVED, less than the vault's own $RAW1 -- absorption did not happen"
ok "received more than the vault held on its own ($RAW1)"

# One unit of rounding either way on a redeem is ERC-4626; more is a bug.
DIFF=$(bi "$DEPOSITOR_LOSS" sub "$UNCOVERED")
case "$DIFF" in -1|0|1) ok "depositor lost exactly the uncovered part ($DIFF rounding)";;
  *) die "depositor lost $DEPOSITOR_LOSS but only $UNCOVERED was uncovered";; esac

# --- 6. The escrow paid ----------------------------------------------------
bold "6/6  Who paid"
ESCROW_END=$(call "$ESCROW" 'available()(uint256)')
PAID=$(bi "$ESCROW_START" sub "$ESCROW_END")

info "escrow  $ESCROW_START -> $ESCROW_END"
info "paid    $PAID  (expected $EXPECTED_SUPPORT)"

eq "$PAID" "$EXPECTED_SUPPORT" || die "the escrow paid $PAID, expected $EXPECTED_SUPPORT"
if eq "$UNCOVERED" 0; then
  ok "the leader's capital paid the whole $PAID so the depositor did not have to"
else
  eq "$ESCROW_END" 0 || die "escrow still holds $ESCROW_END under partial coverage; it should be exhausted"
  ok "the leader's capital paid everything it had ($PAID); the depositor took only the $UNCOVERED beyond it"
fi

bold "Drill passed ($MODE)"
echo "  The venue lost $LOSS. The leader's escrow paid $PAID. The depositor"
echo "  got $RECEIVED back and bore $DEPOSITOR_LOSS. Conservation exact."
echo

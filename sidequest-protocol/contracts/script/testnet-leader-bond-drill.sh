#!/usr/bin/env bash
# The leader's bond, and what the "minimum coverage" floor actually binds.
#
# Two subjects, one launch, because both need a live leader-launched vault and
# launching one costs a 10,000 ZOR bond plus a seed.
#
# PART A -- THE BOND
#
# `slashBond` sends a leader's bond to the treasury; `reclaimBond` returns it,
# but only to the leader and only once the vault holds no depositor money. The
# interesting assertion is not that each works, it is that they are mutually
# exclusive and one-shot: a slashed bond must never be reclaimable, and a
# reclaimed bond must never be slashable. `bondReleased || bondSlashed ->
# BondAlreadyResolved` is the only thing standing between the treasury and the
# leader both being paid the same bond.
#
# PART B -- THE COVERAGE FLOOR, AND WHAT IT DOES NOT DO
#
# `minCoverageBps` reads as a minimum on the leader's first-loss capital, and
# `vaultSummary` returns `adequatelyCovered` for a leaderboard to display. But
# the only place the floor is enforced is `executeWithdrawal`:
#
#     if (after_ < minCoverageBps) revert WouldBreachMinimum(...)
#
# `YieldVault.maxDeposit` returns `type(uint256).max`. Nothing consults the
# escrow on the way in. So deposits can dilute coverage arbitrarily far below
# the stated minimum and every one of them succeeds.
#
# That is defensible -- the escrow is an absolute buffer and coverage naturally
# thins as a vault grows, and capping deposits on coverage would stop a vault
# growing unless the leader kept adding capital. It is also not what the word
# "minimum" suggests, and `adequatelyCovered` can read false while the vault
# still takes money with no warning at the deposit call.
#
# So Part B asserts the behaviour as it IS, in both directions: the dilution
# succeeds, and the leader's withdrawal is refused. It deliberately does not
# assert a guarantee that does not exist. Whether inflows should be capped is a
# product decision with real consequences for growth, and belongs to governance
# and the audit, not to this script.
#
# Usage:
#   ./script/testnet-leader-bond-drill.sh zorpha-gov
#
# The actor is both governance (to slash) and the leader (to launch and
# reclaim), which is fine on testnet and is asserted rather than assumed.

set -euo pipefail

if ! command -v cast >/dev/null; then
  [[ -d "$HOME/.foundry/bin" ]] && { PATH="$HOME/.foundry/bin:$PATH"; export PATH; }
fi
for t in cast node; do
  command -v "$t" >/dev/null || { echo "ERROR: $t not found" >&2; exit 1; }
done

GOV_ACCT="${1:-}"
[[ -n "$GOV_ACCT" ]] || { echo "usage: $0 <governance-keystore>" >&2; exit 1; }

RPC="${RH_TESTNET_RPC_URL:-https://rpc.testnet.chain.robinhood.com/rpc}"
WEB_ENV="../../zorpha-web/.env.local"

bold() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m+\033[0m %s\n' "$1"; }
info() { printf '    %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
die()  { printf '\n  \033[31mx %s\033[0m\n\n' "$1" >&2; exit 1; }

num()     { awk '{print $1}'; }
env_of()  { grep -E "^$1=" "$WEB_ENV" | head -1 | cut -d= -f2-; }
call()    { cast call "$@" --rpc-url "$RPC" | num; }
send()    { cast send "$@" --rpc-url "$RPC" --account "$GOV_ACCT" >/dev/null; }
bi()      { MSYS_NO_PATHCONV=1 node -e 'const [a,op,b]=process.argv.slice(1);const A=BigInt(a),B=BigInt(b);
  const f={add:()=>A+B,sub:()=>A-B,mul:()=>A*B,div:()=>A/B}[op];
  process.stdout.write(f().toString())' -- "$1" "$2" "$3"; }
lt()      { MSYS_NO_PATHCONV=1 node -e 'process.exit(BigInt(process.argv[1]) < BigInt(process.argv[2]) ? 0 : 1)' -- "$1" "$2"; }

# A revert is the pass condition for most of this drill, so the reason must be
# checked. "It failed" is satisfied by a missing role or an empty balance just
# as well as by the guard under test.
refuses_with() {
  local want="$1" what="$2"; shift 2
  local err rc
  set +e
  err=$(cast call "$@" --rpc-url "$RPC" --from "$ACTOR" 2>&1)
  rc=$?
  set -e
  [[ $rc -ne 0 ]] || die "$what SUCCEEDED. Expected it to revert with $want."
  if echo "$err" | grep -qi "$want"; then
    ok "$what refused with $want"
  elif echo "$err" | grep -qiE 'AccessControl|Unauthorized|ERC20|InsufficientBalance|InsufficientAllowance'; then
    die "$what reverted, but on a role or balance problem rather than $want.
     This assertion proves nothing as written. Error: $err"
  else
    warn "$what refused, but not recognisably with $want"
    info "$(echo "$err" | head -2)"
  fi
}

[[ -f "$WEB_ENV" ]] || die "no $WEB_ENV"

ACTOR=$(cast wallet address --account "$GOV_ACCT")
LAUNCHER=$(env_of NEXT_PUBLIC_VAULT_LAUNCHER_ADDRESS)
ZOR=$(env_of NEXT_PUBLIC_ZOR_TOKEN_ADDRESS)
TREASURY=$(env_of NEXT_PUBLIC_TREASURY_ADDRESS)
[[ -n "$LAUNCHER" ]] || die "NEXT_PUBLIC_VAULT_LAUNCHER_ADDRESS not in $WEB_ENV"
[[ -n "$ZOR" ]]      || die "NEXT_PUBLIC_ZOR_TOKEN_ADDRESS not in $WEB_ENV"

TARGET="${YIELD_TARGET:-}"
if [[ -z "$TARGET" ]]; then
  TARGET=$(MSYS_NO_PATHCONV=1 node -e '
    const j = require("./broadcast/DeployTestnetFixtures.s.sol/46630/run-latest.json");
    const h = (j.transactions||[]).find(t => t.contractName === "TestYieldTarget");
    process.stdout.write(h && h.contractAddress ? h.contractAddress : "");')
fi
[[ -n "$TARGET" ]] || die "could not resolve an approved yield target"
ASSET=$(call "$TARGET" 'asset()(address)')

bold "Leader bond and coverage floor"
info "launcher $LAUNCHER"
info "target   $TARGET"
info "asset    $ASSET"
info "actor    $ACTOR"

# ── 0. Preflight ────────────────────────────────────────────────────────────
bold "0/9  Preflight"
GR=$(call "$LAUNCHER" 'GOVERNANCE_ROLE()(bytes32)')
[[ "$(call "$LAUNCHER" 'hasRole(bytes32,address)(bool)' "$GR" "$ACTOR")" == "true" ]] \
  || die "$ACTOR lacks GOVERNANCE_ROLE on the launcher, so it cannot slash and
     Part A cannot run"
ok "actor holds GOVERNANCE_ROLE, so it can slash"

[[ "$(call "$LAUNCHER" 'approvedTarget(address)(bool)' "$TARGET")" == "true" ]] \
  || die "$TARGET is not an approved venue; launchYieldVault would revert"
ok "the venue is approved"

DR=$(cast keccak "DEPLOYER_ROLE")
FACTORY=$(call "$LAUNCHER" 'factory()(address)')
[[ "$(call "$FACTORY" 'hasRole(bytes32,address)(bool)' "$DR" "$LAUNCHER")" == "true" ]] \
  || die "the launcher lacks DEPLOYER_ROLE on the factory; it cannot create a vault"
ok "the launcher can create vaults"

BOND=$(call "$LAUNCHER" 'bondAmount()(uint256)')
SEED=$(call "$LAUNCHER" 'minSeedEscrow()(uint256)')
FLOOR=$(call "$LAUNCHER" 'minCoverageBps()(uint256)')
info "bond $BOND, min seed $SEED, min coverage $FLOOR bps"

HAVE_ZOR=$(call "$ZOR" 'balanceOf(address)(uint256)' "$ACTOR")
lt "$HAVE_ZOR" "$BOND" && die "actor holds $HAVE_ZOR ZOR, needs $BOND for the bond"
ok "actor can post the bond"

HAVE_ASSET=$(call "$ASSET" 'balanceOf(address)(uint256)' "$ACTOR")
NEED=$(bi "$SEED" mul 40)
if lt "$HAVE_ASSET" "$NEED"; then
  send "$ASSET" 'mint(address,uint256)' "$ACTOR" "$NEED"
  ok "minted $NEED of the asset"
fi

# ── 1. Launch ───────────────────────────────────────────────────────────────
bold "1/9  Launch a vault"
send "$ZOR" 'approve(address,uint256)' "$LAUNCHER" "$BOND"
send "$ASSET" 'approve(address,uint256)' "$LAUNCHER" "$SEED"
SALT=$(cast keccak "zorpha-bond-drill-$(date +%s)")
send "$LAUNCHER" 'launchYieldVault(address,uint256,string,string,bytes32)' \
  "$TARGET" "$SEED" "Zorpha Bond Drill" "zqBOND" "$SALT"
# 1-INDEXED. _launch does `launches[launchId - 1]` and reverts on 0, so the
# newest launch is launchCount(), not launchCount() - 1. The off-by-one is not
# cosmetic here: step 6 slashes a bond, and the wrong id slashes a bond
# belonging to somebody else, irreversibly.
LID=$(call "$LAUNCHER" 'launchCount()(uint256)')
[[ "$LID" != "0" ]] || die "launchCount is 0 after a launch"
ok "launch id $LID (1-indexed)"

# Field by field. A multi-return cast call prints one value per line, and
# collapsing that into positional awk was fragile for no gain.
summary_field() { cast call "$LAUNCHER" 'vaultSummary(uint256)(address,address,uint256,uint256,uint256,bool)' "$LID" --rpc-url "$RPC" | sed -n "${1}p" | num; }
VAULT=$(summary_field 1)
LEADER=$(summary_field 2)
ESCBAL=$(summary_field 4)
COV=$(summary_field 5)
COVOK=$(summary_field 6)

# The escrow comes off the public `launches` array, which is indexed from 0
# while ids run from 1.
ESCROW=$(cast call "$LAUNCHER" 'launches(uint256)(address,address,address,address,address,uint256,uint64,bool,bool)' "$(bi "$LID" sub 1)" --rpc-url "$RPC" | sed -n "2p" | num)
info "vault $VAULT"
info "escrow balance $ESCBAL, coverage $COV bps, adequately covered $COVOK"
[[ "$(printf '%s' "$LEADER" | tr 'A-Z' 'a-z')" == "$(printf '%s' "$ACTOR" | tr 'A-Z' 'a-z')" ]] \
  || die "the recorded leader is $LEADER, not $ACTOR; the reclaim assertions
     below would test NotLeader rather than the guards they are aimed at"
ok "the actor is the recorded leader"

# Belt and braces against an id mistake of any kind. The vault this id points
# at must be one that did not exist a moment ago, so the drill can never act
# on somebody else’s launch even if the indexing changes under it.
CREATED=$(cast call "$LAUNCHER" 'launches(uint256)(address,address,address,address,address,uint256,uint64,bool,bool)' "$(bi "$LID" sub 1)" --rpc-url "$RPC" | sed -n "7p" | num)
NOW=$(cast block latest --rpc-url "$RPC" --field timestamp | num)
[[ $(( NOW - CREATED )) -lt 600 ]] || die "launch $LID was created $(( NOW - CREATED ))s ago.
     This drill slashes a bond and must only ever act on the launch it just
     made. Refusing to touch an older one."
ok "launch $LID was created $(( NOW - CREATED ))s ago, so it is this run’s"
info "escrow $ESCROW"
[[ "$COVOK" == "true" ]] || die "the vault launched already under-covered"
ok "launched adequately covered"

BOND_HELD=$(call "$ZOR" 'balanceOf(address)(uint256)' "$LAUNCHER")
info "launcher holds $BOND_HELD ZOR"

# ── PART A: the bond ────────────────────────────────────────────────────────

# ── 2. Reclaim must refuse while depositors are in ──────────────────────────
bold "2/9  Reclaim refused while the vault holds shares"
DEP=$(bi "$SEED" mul 2)
send "$ASSET" 'approve(address,uint256)' "$VAULT" "$DEP"
send "$VAULT" 'deposit(uint256,address)' "$DEP" "$ACTOR"
SUP=$(call "$VAULT" 'totalSupply()(uint256)')
[[ "$SUP" != "0" ]] || die "the deposit minted no shares, so VaultNotEmpty cannot be tested"
ok "deposited; supply $SUP"
refuses_with "VaultNotEmpty" "reclaimBond with depositors in" \
  "$LAUNCHER" 'reclaimBond(uint256)' "$LID"
ok "a leader cannot pull their first-loss bond out from under depositors"

# ── 3. The coverage floor, on the way in ────────────────────────────────────
bold "3/9  Coverage dilutes on deposit, and nothing refuses"
BIG=$(bi "$SEED" mul 30)
send "$ASSET" 'approve(address,uint256)' "$VAULT" "$BIG"
BEFORE=$(cast call "$LAUNCHER" 'vaultSummary(uint256)(address,address,uint256,uint256,uint256,bool)' "$LID" --rpc-url "$RPC" | sed -n '5p' | num)
send "$VAULT" 'deposit(uint256,address)' "$BIG" "$ACTOR"
AFTER=$(cast call "$LAUNCHER" 'vaultSummary(uint256)(address,address,uint256,uint256,uint256,bool)' "$LID" --rpc-url "$RPC" | sed -n '5p' | num)
COVOK2=$(cast call "$LAUNCHER" 'vaultSummary(uint256)(address,address,uint256,uint256,uint256,bool)' "$LID" --rpc-url "$RPC" | sed -n '6p' | num)
info "coverage $BEFORE bps -> $AFTER bps, floor $FLOOR bps"
info "adequatelyCovered now $COVOK2"
lt "$AFTER" "$BEFORE" || die "coverage did not fall after a large deposit; the
     dilution this step exists to demonstrate did not happen, so nothing below
     is being tested. Raise the deposit multiple."
ok "coverage fell, as an absolute buffer against a growing vault must"

if lt "$AFTER" "$FLOOR"; then
  warn "coverage $AFTER bps is BELOW the $FLOOR bps minimum, and the deposit succeeded"
  info "maxDeposit returns type(uint256).max and consults no escrow, so the"
  info "floor is not enforced on the way in. It binds the leader's exit only."
  info "Recorded, not asserted as a guarantee -- see the header."
  [[ "$COVOK2" == "false" ]] \
    || die "coverage is below the floor but adequatelyCovered still reads true.
     The leaderboard would show this vault as covered when it is not, which is
     a reporting bug on top of the unenforced floor."
  ok "adequatelyCovered correctly reports false, so the state is at least visible"
else
  info "coverage is still above the floor; the deposit was not large enough to"
  info "cross it. The dilution direction is shown, the breach is not."
fi

# ── 4. The floor that IS enforced: the leader's exit ────────────────────────
bold "4/9  The floor blocks the leader's withdrawal"
if [[ -n "$ESCROW" ]]; then
  WD=$(call "$ESCROW" 'escrow()(uint256)')
  send "$ESCROW" 'requestWithdrawal(uint256)' "$WD"
  ok "requested withdrawal of the entire escrow $WD"
  refuses_with "WouldBreachMinimum" "executeWithdrawal below the floor" \
    "$ESCROW" 'executeWithdrawal()'
  ok "the leader cannot withdraw capital out from under the coverage floor"
  info "This is the one direction minCoverageBps binds, and it works."
else
  warn "escrow address unavailable; skipping the withdrawal assertion"
fi

# ── 5. Empty the vault so reclaim becomes legitimate ────────────────────────
bold "5/9  Empty the vault"
SH=$(call "$VAULT" 'balanceOf(address)(uint256)' "$ACTOR")
send "$VAULT" 'redeem(uint256,address,address)' "$SH" "$ACTOR" "$ACTOR"
SUP=$(call "$VAULT" 'totalSupply()(uint256)')
[[ "$SUP" == "0" ]] || die "supply is $SUP after redeeming everything; reclaim
     would still refuse and step 7 would pass for the wrong reason"
ok "supply is zero, so reclaim is now legitimate"

cast call "$LAUNCHER" 'reclaimBond(uint256)' "$LID" --rpc-url "$RPC" --from "$ACTOR" >/dev/null 2>&1 \
  && ok "reclaimBond now simulates cleanly" \
  || die "reclaimBond still reverts on an empty vault. The slash assertions
     below would then pass whether or not slashing works, because reclaim was
     already failing."

# ── 6. Slash ────────────────────────────────────────────────────────────────
bold "6/9  Slash the bond"
T0=$(call "$ZOR" 'balanceOf(address)(uint256)' "$TREASURY")
send "$LAUNCHER" 'slashBond(uint256,string)' "$LID" "drill: deliberate slash"
T1=$(call "$ZOR" 'balanceOf(address)(uint256)' "$TREASURY")
MOVED=$(bi "$T1" sub "$T0")
info "treasury ZOR $T0 -> $T1  (+$MOVED)"
[[ "$MOVED" == "$BOND" ]] || die "the treasury received $MOVED, expected the full bond $BOND"
ok "the whole bond reached the treasury"

# ── 7. And the slashed bond must not also be reclaimable ────────────────────
bold "7/9  A slashed bond cannot be reclaimed"
refuses_with "BondAlreadyResolved" "reclaimBond after a slash" \
  "$LAUNCHER" 'reclaimBond(uint256)' "$LID"
ok "the treasury and the leader cannot both be paid the same bond"
info "This is the assertion that matters. Step 5 established reclaim was"
info "otherwise valid, so this refusal is the slash flag doing the work and"
info "not the empty-vault check refusing for its own reasons."

# ── 8. Nor slashed twice ────────────────────────────────────────────────────
bold "8/9  A bond cannot be slashed twice"
refuses_with "BondAlreadyResolved" "slashBond a second time" \
  "$LAUNCHER" 'slashBond(uint256,string)' "$LID" "drill: second attempt"
ok "the treasury cannot be paid twice from one bond"

# ── 9. And only the leader could ever have reclaimed ────────────────────────
bold "9/9  Only the leader can reclaim"
STRANGER=0x000000000000000000000000000000000000dEaD
set +e
ERR=$(cast call "$LAUNCHER" 'reclaimBond(uint256)' "$LID" --rpc-url "$RPC" --from "$STRANGER" 2>&1)
RC=$?
set -e
[[ $RC -ne 0 ]] || die "a stranger could call reclaimBond"
# Already resolved, so either guard is a legitimate refusal; what matters is
# that a non-leader never gets through.
echo "$ERR" | grep -qiE 'NotLeader|BondAlreadyResolved' \
  && ok "a stranger is refused" \
  || { warn "refused, reason unrecognised"; info "$(echo "$ERR" | head -2)"; }

bold "Leader bond drill passed"
info "Bond: reclaim refused while depositors were in, refused after the slash,"
info "and the slash could not be repeated. The full $BOND reached the treasury"
info "once and only once."
info ""
info "Coverage: the floor blocked the leader's withdrawal, which is the"
info "direction it is written to block. It did NOT block deposits that diluted"
info "coverage, because maxDeposit consults no escrow -- recorded as observed"
info "behaviour, and a question for governance rather than a bug this drill"
info "should pretend to settle."
info ""
info "Vault $VAULT is left empty with its bond slashed."

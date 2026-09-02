#!/usr/bin/env bash
# Prove the yield vault charges its fee, and only its fee, on a live chain.
#
# Phase 3 of docs/LAUNCH-CHECKLIST.md, "Yield vault (zqUSD)". This is the vault
# that will hold real size, and the fee is the only revenue the protocol has:
# half of it funds the buyback, so a fee that silently does not accrue is also
# $ZOR value accrual that silently does not happen.
#
# What is asserted, in order:
#
#   circuit breaker  set -> a real deposit is refused -> unset -> accepted
#   deposit          shares minted at the opening NAV
#   accrue           the venue earns; NAV per share rises
#   redeem           the depositor gets the principal plus 90% of the gain.
#                    Getting all of it means fees are broken.
#   accrual          performanceFeeAccrued is non-zero WITHOUT anyone having
#                    called evaluateFees(). It accrues inside redeem itself.
#   claimFees        the accrued amount lands in the treasury, and the counter
#                    resets to zero.
#
# Usage:
#   ./script/testnet-yield-drill.sh zorpha-gov
#
# The account needs DEFAULT_ADMIN_ROLE (claimFees) and RISK_COUNCIL_ROLE
# (circuit breaker) on the vault. Governance holds both after the deploy.

set -euo pipefail

if ! command -v cast >/dev/null; then
  [[ -d "$HOME/.foundry/bin" ]] && { PATH="$HOME/.foundry/bin:$PATH"; export PATH; }
fi
command -v cast >/dev/null || { echo "ERROR: cast not found" >&2; exit 1; }
command -v node >/dev/null || { echo "ERROR: node not found" >&2; exit 1; }

ACCOUNT="${1:-}"
[[ -n "$ACCOUNT" ]] || { echo "usage: $0 <keystore-account-name>" >&2; exit 1; }

RPC="${RH_TESTNET_RPC_URL:-https://rpc.testnet.chain.robinhood.com/rpc}"
CHAIN_ID=46630
WEB_ENV="../../zorpha-web/.env.local"
VAULTS="broadcast/DeployVaultsV1.s.sol/$CHAIN_ID/run-latest.json"

bold() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m+\033[0m %s\n' "$1"; }
info() { printf '    %s\n' "$1"; }
die()  { printf '\n  \033[31mx %s\033[0m\n\n' "$1" >&2; exit 1; }

# All arithmetic through node BigInt. bc is absent from Git Bash and these
# values overflow shell integers.
bi()  { MSYS_NO_PATHCONV=1 node -e 'const [a,op,b]=process.argv.slice(1);const A=BigInt(a),B=BigInt(b);
  const f={add:()=>A+B,sub:()=>A-B,mul:()=>A*B,div:()=>A/B,
           min:()=>A<B?A:B,max:()=>A>B?A:B}[op];
  if(!f) throw new Error("unknown op: "+op);
  process.stdout.write(f().toString())' -- "$1" "$2" "$3"; }
lt()  { MSYS_NO_PATHCONV=1 node -e 'process.exit(BigInt(process.argv[1]) <  BigInt(process.argv[2]) ? 0 : 1)' -- "$1" "$2"; }
gt()  { MSYS_NO_PATHCONV=1 node -e 'process.exit(BigInt(process.argv[1]) >  BigInt(process.argv[2]) ? 0 : 1)' -- "$1" "$2"; }
eq()  { [[ "$1" == "$2" ]]; }

env_of() { grep -E "^$1=" "$WEB_ENV" | head -1 | cut -d= -f2-; }
num()    { awk '{print $1}'; }
call()   { cast call "$@" --rpc-url "$RPC" | num; }
send()   { cast send "$@" --rpc-url "$RPC" --account "$ACCOUNT" >/dev/null; }

[[ -f "$WEB_ENV" ]]  || die "no $WEB_ENV"
[[ -f "$VAULTS" ]]   || die "no $VAULTS"

# The yield vault is the CREATE2 child of the deploy whose firstLossEscrow is
# unset: the factory vault, not a leader's. Identified by behaviour, not by a
# hardcoded address that goes stale on the next deploy.
VAULT=$(node -e '
  const j = require(process.argv[1]);
  const seen = new Set();
  for (const t of j.transactions || [])
    for (const x of t.additionalContracts || [])
      if (x.address && !seen.has(x.address)) { seen.add(x.address); console.log(x.address); }
' "./$VAULTS" | while read -r a; do
  esc=$(cast call "$a" 'firstLossEscrow()(address)' --rpc-url "$RPC" 2>/dev/null | num || true)
  [[ "$esc" == "0x0000000000000000000000000000000000000000" ]] && { echo "$a"; break; }
done)
[[ -n "$VAULT" ]] || die "could not find the factory yield vault in $VAULTS"

ASSET=$(call "$VAULT" 'asset()(address)')

# Where "yield" has to be injected is decided by the ADAPTER the vault actually
# has installed, not by which fixture happens to be in the broadcast artifact.
#
# This drill used to read TestYieldTarget out of the fixtures file and accrue
# there unconditionally. The deployed vault is on a StubYieldAdapter, whose
# totalAssets() is its own token balance and which never touches a venue at
# all. So the accrual landed somewhere the vault could not see, rawAssets never
# moved, and the drill died at "NAV did not rise after the venue accrued" --
# pointing at the venue when the real answer was that nothing connected the two.
#
# Installing a real adapter from here is not an option, and correctly so:
# ADAPTER_SETTER_ROLE is held by the Timelock, not governance, so an adapter
# swap is a 48h queued action. That belongs in its own drill.
ADAPTER=$(call "$VAULT" 'adapter()(address)')
[[ -n "$ADAPTER" && "$ADAPTER" != "0x0000000000000000000000000000000000000000" ]]   || die "the vault has no adapter installed; nothing can hold its assets"

# An ERC4626YieldAdapter exposes `target()`. A stub does not, so a revert here
# identifies the stub positively rather than by name or address.
if TARGET=$(cast call "$ADAPTER" 'target()(address)' --rpc-url "$RPC" 2>/dev/null | num)    && [[ -n "$TARGET" && "$TARGET" != "0x0000000000000000000000000000000000000000" ]]; then
  ACCRUE_TO="$TARGET"
  ACCRUE_KIND="venue"
  # The venue must be denominated in the same asset, or the arithmetic below is
  # comparing two different tokens.
  VASSET=$(call "$TARGET" 'asset()(address)')
  [[ "$(printf '%s' "$VASSET" | tr 'A-Z' 'a-z')" == "$(printf '%s' "$ASSET" | tr 'A-Z' 'a-z')" ]]     || die "adapter target holds $VASSET but the vault's asset is $ASSET"
else
  # Stub adapter: its totalAssets() is its own balance, so minting underlying
  # straight to it raises the vault's NAV exactly as venue yield would.
  TARGET="$ADAPTER"
  ACCRUE_TO="$ADAPTER"
  ACCRUE_KIND="stub adapter (no venue integration exercised)"
fi

TREASURY=$(call "$VAULT" 'feeRecipient()(address)')
ACTOR=$(cast wallet address --account "$ACCOUNT")

DEPOSIT="${DEPOSIT_AMOUNT:-1000000000}"   # 1,000 USDG
YIELD="${YIELD_AMOUNT:-500000000}"        #   500 USDG, the checklist's figure
FEE_BPS=$(call "$VAULT" 'performanceFee()(uint256)')

bold "Yield vault drill"
info "vault     $VAULT"
info "adapter   $ADAPTER"
info "accrue to $ACCRUE_TO  ($ACCRUE_KIND)"
info "asset     $ASSET"
info "treasury  $TREASURY"
info "actor     $ACTOR"
info "deposit $DEPOSIT, yield $YIELD, fee $FEE_BPS bps"

# --- Preflight -------------------------------------------------------------
bold "Preflight"
Z0=0x0000000000000000000000000000000000000000000000000000000000000000
RISK=$(cast keccak "RISK_COUNCIL_ROLE")
eq "$(call "$VAULT" 'hasRole(bytes32,address)(bool)' "$Z0" "$ACTOR")" true \
  || die "$ACTOR is not DEFAULT_ADMIN on the vault; claimFees would revert"
eq "$(call "$VAULT" 'hasRole(bytes32,address)(bool)' "$RISK" "$ACTOR")" true \
  || die "$ACTOR is not RISK_COUNCIL on the vault; setCircuitBreaker would revert"
ok "actor holds DEFAULT_ADMIN and RISK_COUNCIL"

# A stale position from an earlier run has to be cleared, not just noted.
#
# Every figure from step 4 down is measured as `RECEIVED - DEPOSIT`, which is
# only the depositor's profit if the shares being redeemed correspond to
# exactly one $DEPOSIT. An aborted earlier run leaves the actor holding shares
# from a deposit that was never redeemed, and then redeeming everything returns
# BOTH principals -- so the drill reads the returned principal as profit and
# reports "received the ENTIRE gain. Fees are broken."
#
# That is what happened: 1e9 left over plus 1e9 fresh, 2e9 of principal plus
# 4.5e8 of net gain = 2449999999 received. The fee was 5e7 on a 5e8 gain, which
# is exactly the configured 1000 bps. Nothing was broken except the drill's
# assumption about whose money it was looking at.
#
# Clearing it also empties the vault, so the next deposit goes through the
# first-entry path and the mark is set from the price actually paid -- the
# equalisation fix, exercised rather than stepped around.
STALE=$(call "$VAULT" 'balanceOf(address)(uint256)' "$ACTOR")
if [[ "$STALE" != "0" ]]; then
  info "clearing a stale position of $STALE shares from an earlier run"
  send "$VAULT" 'redeem(uint256,address,address)' "$STALE" "$ACTOR" "$ACTOR"
  eq "$(call "$VAULT" 'balanceOf(address)(uint256)' "$ACTOR")" 0     || die "could not clear the actor's stale position"
  ok "cleared"
fi

SUPPLY0=$(call "$VAULT" 'totalSupply()(uint256)')
# Shares held by someone other than the actor break the same assumption and
# cannot be cleared from here, so say so rather than measuring against them.
eq "$SUPPLY0" 0 || info "note: $SUPPLY0 shares remain, held by someone else; profit below is measured against this actor's deposit only"

HAVE=$(call "$ASSET" 'balanceOf(address)(uint256)' "$ACTOR")
if lt "$HAVE" "$DEPOSIT"; then
  send "$ASSET" 'mint(address,uint256)' "$ACTOR" "$DEPOSIT"
  ok "minted $DEPOSIT"
fi
send "$ASSET" 'approve(address,uint256)' "$VAULT" "$DEPOSIT"
ok "approved"

# --- 1. Circuit breaker ----------------------------------------------------
# Tested against a real deposit attempt, not by reading the flag back.
bold "1/6  Circuit breaker"
send "$VAULT" 'setCircuitBreaker(bool)' true
eq "$(call "$VAULT" 'maxDeposit(address)(uint256)' "$ACTOR")" 0 || die "breaker set but maxDeposit is not 0"
if cast send "$VAULT" 'deposit(uint256,address)' "$DEPOSIT" "$ACTOR" \
     --rpc-url "$RPC" --account "$ACCOUNT" >/dev/null 2>&1; then
  die "a deposit SUCCEEDED with the circuit breaker active"
fi
ok "breaker on: deposit refused"
send "$VAULT" 'setCircuitBreaker(bool)' false
eq "$(call "$VAULT" 'isCircuitBreakerActive()(bool)')" false || die "breaker did not clear"
ok "breaker off"

# --- 2. Deposit ------------------------------------------------------------
bold "2/6  Deposit"
SH_BEFORE=$(call "$VAULT" 'balanceOf(address)(uint256)' "$ACTOR")
send "$VAULT" 'deposit(uint256,address)' "$DEPOSIT" "$ACTOR"
# The DELTA, not the balance. Redeeming a balance that includes shares this
# deposit did not mint returns principal the drill then scores as profit.
SHARES=$(bi "$(call "$VAULT" 'balanceOf(address)(uint256)' "$ACTOR")" sub "$SH_BEFORE")
NAV0=$(call "$VAULT" 'getNavPerShare()(uint256)')
RAW0=$(call "$VAULT" 'rawAssets()(uint256)')
FEE0=$(call "$VAULT" 'performanceFeeAccrued()(uint256)')
gt "$SHARES" 0 || die "no shares minted"
ok "shares $SHARES"
info "nav/share $NAV0, rawAssets $RAW0, feeAccrued $FEE0"

# --- 3. The venue earns ----------------------------------------------------
# The high-water mark survives a full redemption. A vault that has already
# earned once keeps its mark at the old NAV, so the same fixed yield that
# worked on a fresh vault clears nothing on the second run: _evaluateFees sees
# nav <= highWaterMark and returns before charging anything. The drill would
# then fail on "performanceFeeAccrued is ZERO" and look like a protocol bug.
#
# Top the yield up by whatever it takes to get back to the existing mark, so
# the requested YIELD is gain *above* the mark either way.
HWM=$(call "$VAULT" 'highWaterMark()(uint256)')
VDEC=$(call "$VAULT" 'decimals()(uint8)')
SUPPLY=$(call "$VAULT" 'totalSupply()(uint256)')
SHARE_UNIT=$(node -e 'process.stdout.write((10n ** BigInt(process.argv[1])).toString())' -- "$VDEC")
# rawAssets the mark implies at the current supply.
MARK_ASSETS=$(bi "$(bi "$HWM" mul "$SUPPLY")" div "$SHARE_UNIT")
CATCHUP=$(bi "$(bi "$MARK_ASSETS" sub "$RAW0")" max 0)
TOP_UP=$(bi "$CATCHUP" add "$YIELD")

if [[ "$CATCHUP" != "0" ]]; then
  info "existing high-water mark $HWM implies $MARK_ASSETS of assets;"
  info "adding $CATCHUP to reach it, then $YIELD of real gain on top"
fi

# The equalisation gap.
#
# _evaluateFees() runs BEFORE super.deposit() mints, so on an empty vault it
# hits `if (totalSupply() == 0) return` and never marks the incoming
# depositor's entry NAV. If the vault holds any assets while empty -- rounding
# dust, a donation, yield on a residue -- the ERC-4626 offset puts the entry
# NAV above the stale mark, and the fee at redemption is charged from the MARK
# rather than from where the depositor actually bought in.
#
# They then pay a performance fee on appreciation that happened before they
# arrived. This is the depositor-harming half of the classic pooled-fund
# equalisation problem; the other half (entry below the mark, depositor rides
# free and the leader underearns) is the better-known one.
ENTRY_ABOVE_MARK=$(bi "$(bi "$NAV0" sub "$HWM")" max 0)
if [[ "$ENTRY_ABOVE_MARK" != "0" ]]; then
  info ""
  info "!! entry NAV $NAV0 is ABOVE the high-water mark $HWM by $ENTRY_ABOVE_MARK."
  info "!! The fee will be charged from the mark, not from the entry price, so"
  info "!! this depositor pays for $ENTRY_ABOVE_MARK of NAV they never earned."
  info "!! See docs/FINDINGS-EQUALISATION.md"
  info ""
fi

bold "3/6  Venue accrues $TOP_UP"
if [[ "$ACCRUE_KIND" == "venue" ]]; then
  send "$ACCRUE_TO" 'accrue(uint256)' "$TOP_UP"
else
  # No venue in the path. Mint underlying to the stub adapter, whose
  # totalAssets() is its own balance -- the same NAV movement by the only
  # mechanism this configuration has.
  send "$ASSET" 'mint(address,uint256)' "$ACCRUE_TO" "$TOP_UP"
fi
NAV1=$(call "$VAULT" 'getNavPerShare()(uint256)')
RAW1=$(call "$VAULT" 'rawAssets()(uint256)')
# Everything below is measured against the mark, not against the deposit:
# the fee is charged on NAV above the high-water mark, so that is the only
# figure the arithmetic can use.
MOVED_TOTAL=$(bi "$RAW1" sub "$RAW0")
GAIN=$(bi "$MOVED_TOTAL" sub "$CATCHUP")
info "nav/share $NAV0 -> $NAV1"
info "rawAssets $RAW0 -> $RAW1  (+$MOVED_TOTAL, of which $GAIN is above the mark)"
gt "$NAV1" "$NAV0" || die "NAV did not rise after the venue accrued"
gt "$GAIN" 0       || die "this vault saw none of the gain"
ok "NAV per share rose"

# Nobody has called evaluateFees. The counter must still be zero here, because
# accrual happens on the next deposit/withdraw/redeem, not on the venue's move.
eq "$(call "$VAULT" 'performanceFeeAccrued()(uint256)')" "$FEE0" \
  || info "note: feeAccrued moved before redeem (another actor touched the vault)"

# --- 4. Redeem -------------------------------------------------------------
bold "4/6  Redeem everything"
SUPPLY_AT_REDEEM=$(call "$VAULT" 'totalSupply()(uint256)')
BEFORE=$(call "$ASSET" 'balanceOf(address)(uint256)' "$ACTOR")
send "$VAULT" 'redeem(uint256,address,address)' "$SHARES" "$ACTOR" "$ACTOR"
AFTER=$(call "$ASSET" 'balanceOf(address)(uint256)' "$ACTOR")
RECEIVED=$(bi "$AFTER" sub "$BEFORE")
PROFIT=$(bi "$(bi "$RECEIVED" sub "$DEPOSIT")" sub "$CATCHUP")
# Two different numbers, and the difference is the finding rather than a bug
# in the arithmetic here.
#
#   EXPECTED_FEE  what the contract charges:  (nav - highWaterMark) * supply
#   FAIR_FEE      what the depositor earned:  (nav - entryNav)      * supply
#
# They are equal on a vault whose mark was set by this depositor's own entry.
# They diverge exactly when ENTRY_ABOVE_MARK is non-zero.
FEE_ALPHA=$(bi "$NAV1" sub "$HWM")
FAIR_ALPHA=$(bi "$NAV1" sub "$NAV0")
EXPECTED_FEE=$(bi "$(bi "$(bi "$FEE_ALPHA" mul "$SUPPLY_AT_REDEEM")" mul "$FEE_BPS")" div "$(bi "$SHARE_UNIT" mul 10000)")
FAIR_FEE=$(bi "$(bi "$(bi "$FAIR_ALPHA" mul "$SUPPLY_AT_REDEEM")" mul "$FEE_BPS")" div "$(bi "$SHARE_UNIT" mul 10000)")
EXPECTED_NET=$(bi "$GAIN" sub "$EXPECTED_FEE")

info "received $RECEIVED for $SHARES shares"
info "profit   $PROFIT  (gain $GAIN, fee $EXPECTED_FEE, net $EXPECTED_NET)"
if [[ "$EXPECTED_FEE" != "$FAIR_FEE" ]]; then
  info "         contract charges on nav-mark   ($FEE_ALPHA) = $EXPECTED_FEE"
  info "         depositor earned  nav-entry    ($FAIR_ALPHA) = $FAIR_FEE"
  info "         overcharged by $(bi "$EXPECTED_FEE" sub "$FAIR_FEE")"
fi

gt "$RECEIVED" "$DEPOSIT" || die "received $RECEIVED, no more than deposited. The gain did not reach the depositor."
ok "depositor received the principal plus a gain"

# THE assertion. If the depositor got the whole gain, no fee was charged.
lt "$RECEIVED" "$(bi "$(bi "$DEPOSIT" add "$CATCHUP")" add "$GAIN")" \
  || die "received the ENTIRE gain ($RECEIVED). Fees are broken. See ERC4626YieldAdapter.t.sol."
ok "depositor received LESS than the full gain: a fee was taken"

# Direction first, magnitude second.
#
# ERC-4626 rounds against the user on every conversion, and it has to: the
# reverse is drainable, because anyone could deposit and redeem in a loop and
# come out ahead of the vault each time. So the depositor coming out a hair
# BELOW the idealised net is correct, and coming out ABOVE it is the finding.
# A symmetric "within N either way" check treats those two as equivalent, which
# is exactly backwards.
SHORTFALL=$(bi "$EXPECTED_NET" sub "$PROFIT")
if lt "$SHORTFALL" 0; then
  die "the depositor received MORE than the fee math allows ($PROFIT vs $EXPECTED_NET).
     Rounding favours the depositor here, which is drainable in a deposit/redeem loop."
fi
ok "rounding favours the vault, not the depositor"

# Five units, one per rounding conversion in a deposit/redeem round trip.
# Counted from the call path, not tuned until the run went green:
#
#   1  deposit  vault convertToShares       rounds down
#   2  deposit  _pushToAdapter -> venue     rounds down
#   3  redeem   vault convertToAssets       rounds down
#   4  redeem   _pullFromAdapter <- venue   rounds down
#   5  fee      integer division            rounds down
#
# An earlier revision said three, having counted only the vault's own two
# conversions and forgotten that the adapter converts again at the venue. A
# real run then landed on exactly three, at the edge of a bound that was too
# low for the wrong reason.
ROUNDING_BOUND=5
if lt "$ROUNDING_BOUND" "$SHORTFALL"; then
  die "depositor is short by $SHORTFALL, more than the $ROUNDING_BOUND units two ERC-4626
     conversions and one fee division can explain. Expected $EXPECTED_NET, got $PROFIT."
fi
ok "net gain $PROFIT is within $SHORTFALL of the $FEE_BPS bps expectation ($EXPECTED_NET)"

# --- 5. Fee accrued without a keeper ----------------------------------------
bold "5/6  Fee accrual"
ACCRUED=$(call "$VAULT" 'performanceFeeAccrued()(uint256)')
ACCRUED_DELTA=$(bi "$ACCRUED" sub "$FEE0")
[[ "$FEE0" == "0" ]] || info "note: $FEE0 was already accrued and unclaimed before this run"
info "performanceFeeAccrued $FEE0 -> $ACCRUED  (+$ACCRUED_DELTA, expected ~$EXPECTED_FEE)"
gt "$ACCRUED_DELTA" 0 || die "nothing accrued during this run. A profitable redeem charged no fee."
ok "fee accrued inside redeem, no evaluateFees() call anywhere"
# The fee is the protocol's only revenue and half of it funds the buyback, so
# this is checked tightly. On testnet it lands on the contract's own formula to
# the unit:  fee = (nav - highWaterMark) * totalSupply * bps / (shareUnit * 1e4)
DIFF=$(bi "$ACCRUED_DELTA" sub "$EXPECTED_FEE")
case "$DIFF" in
  0)    ok "accrued exactly $FEE_BPS bps of the gain ($ACCRUED_DELTA)";;
  -1|1) ok "accrued $FEE_BPS bps of the gain, off by $DIFF unit to integer division";;
  *)    die "accrued $ACCRUED_DELTA, expected $EXPECTED_FEE (off by $DIFF). Not rounding.";;
esac

# --- 6. Claim to the treasury -----------------------------------------------
bold "6/6  claimFees"
T0=$(call "$ASSET" 'balanceOf(address)(uint256)' "$TREASURY")
send "$VAULT" 'claimFees()'
T1=$(call "$ASSET" 'balanceOf(address)(uint256)' "$TREASURY")
MOVED=$(bi "$T1" sub "$T0")
info "treasury $T0 -> $T1  (+$MOVED)"
eq "$MOVED" "$ACCRUED" || die "treasury received $MOVED but $ACCRUED was accrued"
ok "the full accrued fee reached the treasury"
eq "$(call "$VAULT" 'performanceFeeAccrued()(uint256)')" 0 || die "performanceFeeAccrued did not reset"
ok "counter reset to 0"

bold "Drill passed"
echo "  Deposited $DEPOSIT, venue earned $GAIN, depositor took home $PROFIT,"
echo "  treasury took $MOVED. That is a $FEE_BPS bps performance fee working on"
echo "  a live chain, and it accrued without a keeper."
echo

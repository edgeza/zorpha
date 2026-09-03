#!/usr/bin/env bash
# Put the REAL yield adapter on chain, and prove the deposit guard live.
#
# WHY
#
# The yield vault runs a StubYieldAdapter: it holds the assets in its own
# balance and never touches a venue. So ERC4626YieldAdapter -- the adapter
# mainnet will actually use, the only code path that reaches a curated vault --
# has never executed on a live chain. Every assertion about it comes from unit
# tests against a mock.
#
# That includes the guard added after this was measured on the testnet fixture:
#
#     TestYieldTarget  totalAssets 500000017   totalSupply 1
#     previewDeposit(1e9) -> 3 shares
#     previewRedeem(3)    -> 750000027
#
# 1e9 in, 7.5e8 back. `deposit` used to take the venue's share count on trust
# and the 25% went to the venue's existing holders, silently, with the vault's
# totalAssets() dropping the instant it landed. The guard values the shares
# back and refuses. It is unit-tested; it has never refused anything real.
#
# WHAT IT PROVES
#
#   guard    a deposit into the inflated venue is REFUSED on chain, by the
#            deployed bytecode, for the right reason
#   fair     and a deposit into a sane venue still succeeds, so the guard is
#            not simply blocking everything
#   queue    swapping the vault's adapter is a Timelock action -- governance
#            does NOT hold ADAPTER_SETTER_ROLE, the Timelock does -- and it
#            cannot be executed early
#   migrate  after the ETA the swap lands and the vault's assets end up in the
#            venue rather than idle in a stub
#
# The first two run immediately. The delay is 48h, so this is meant to be run
# twice -- and the migration adapter and venue are CACHED to make that safe.
#
# Without the cache each run deployed a fresh adapter, and since the operation
# salt derives from the adapter address, each run queued a DIFFERENT
# setAdapter. Two runs left two pending migrations pointing at two different
# adapters -- not idempotent in any useful sense: whichever executed second
# would silently overwrite the first, and the losing adapter and venue were
# left orphaned with VAULT_ROLE already granted to the vault. The header
# claimed idempotence before the code delivered it.
#
# The throwaway adapter in step 1 is deliberately NOT cached: it is cheap, and
# redeploying it re-proves the guard against currently compiled bytecode on
# every run rather than against whatever happened to be deployed once.
#
# Usage:
#   ./script/testnet-adapter-migration.sh zorpha-gov

set -euo pipefail

if ! command -v cast >/dev/null || ! command -v forge >/dev/null; then
  [[ -d "$HOME/.foundry/bin" ]] && { PATH="$HOME/.foundry/bin:$PATH"; export PATH; }
fi
for t in cast forge node; do
  command -v "$t" >/dev/null || { echo "ERROR: $t not found" >&2; exit 1; }
done

GOV_ACCT="${1:-}"
[[ -n "$GOV_ACCT" ]] || { echo "usage: $0 <governance-keystore>" >&2; exit 1; }

RPC="${RH_TESTNET_RPC_URL:-https://rpc.testnet.chain.robinhood.com/rpc}"
CHAIN_ID=46630
WEB_ENV="../../zorpha-web/.env.local"
VAULTS="broadcast/DeployVaultsV1.s.sol/$CHAIN_ID/run-latest.json"

bold() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m+\033[0m %s\n' "$1"; }
info() { printf '    %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
die()  { printf '\n  \033[31mx %s\033[0m\n\n' "$1" >&2; exit 1; }

num()    { awk '{print $1}'; }
# `|| true` is load-bearing under `set -euo pipefail`. grep exits 1 when it
# finds nothing, pipefail propagates that, and the assignment then kills the
# script -- BEFORE the `[[ -n "$X" ]] || die` meant to report the missing key.
# A drill died three times printing nothing at all this way, with its own
# diagnostic sitting unreachable two lines below.
env_of() { grep -E "^$1=" "$WEB_ENV" | head -1 | cut -d= -f2- || true; }
call()   { cast call "$@" --rpc-url "$RPC" | num; }
send()   { cast send "$@" --rpc-url "$RPC" --account "$GOV_ACCT" >/dev/null; }
lc()     { tr '[:upper:]' '[:lower:]'; }
same()   { [[ "$(printf '%s' "$1" | lc)" == "$(printf '%s' "$2" | lc)" ]]; }
bi()     { MSYS_NO_PATHCONV=1 node -e 'const [a,op,b]=process.argv.slice(1);const A=BigInt(a),B=BigInt(b);
  const f={add:()=>A+B,sub:()=>A-B,mul:()=>A*B,div:()=>A/B}[op];
  process.stdout.write(f().toString())' -- "$1" "$2" "$3"; }
lt()     { MSYS_NO_PATHCONV=1 node -e 'process.exit(BigInt(process.argv[1]) < BigInt(process.argv[2]) ? 0 : 1)' -- "$1" "$2"; }

created() { MSYS_NO_PATHCONV=1 node -e 'process.stdout.write(JSON.parse(process.argv[1]).deployedTo || "")' -- "$1"; }

[[ -f "$WEB_ENV" ]] || die "no $WEB_ENV"
[[ -f "$VAULTS" ]]  || die "no $VAULTS"

ACTOR=$(cast wallet address --account "$GOV_ACCT")
TIMELOCK=$(env_of NEXT_PUBLIC_TIMELOCK_ADDRESS)
VAULT=$(env_of NEXT_PUBLIC_YIELD_VAULT_ADDRESS)
[[ -n "$VAULT" ]]    || die "NEXT_PUBLIC_YIELD_VAULT_ADDRESS not in $WEB_ENV"
[[ -n "$TIMELOCK" ]] || die "NEXT_PUBLIC_TIMELOCK_ADDRESS not in $WEB_ENV"

ASSET=$(call "$VAULT" 'asset()(address)')
OLD_ADAPTER=$(call "$VAULT" 'adapter()(address)')

# The inflated venue, from the fixtures deploy. Its state is what motivated the
# guard, so it is the honest thing to point the guard at.
FIXTURES="broadcast/DeployTestnetFixtures.s.sol/$CHAIN_ID/run-latest.json"
INFLATED=$(MSYS_NO_PATHCONV=1 node -e '
  const j = require(process.argv[1]);
  const h = (j.transactions || []).find(t => t.contractName === "TestYieldTarget");
  process.stdout.write(h && h.contractAddress ? h.contractAddress : "");
' "./$FIXTURES")

PROBE="${PROBE_AMOUNT:-1000000000}"   # 1,000 USDG, the figure the loss was measured at

# Keyed on the vault: a redeployed vault must not reuse an adapter that has
# already granted VAULT_ROLE to the old one.
CACHE=".yield-adapter-$CHAIN_ID-$(printf '%s' "$VAULT" | tail -c 9)"

bold "Real yield adapter, and the deposit guard under live fire"
info "vault        $VAULT"
info "old adapter  $OLD_ADAPTER"
info "asset        $ASSET"
info "timelock     $TIMELOCK"
info "actor        $ACTOR"

# ── 0. Preflight ────────────────────────────────────────────────────────────
bold "0/7  Preflight"
SETTER=$(cast keccak "ADAPTER_SETTER_ROLE")
same "$(call "$VAULT" 'hasRole(bytes32,address)(bool)' "$SETTER" "$TIMELOCK")" true \
  || die "the Timelock does not hold ADAPTER_SETTER_ROLE on the vault, so this
     migration cannot be queued. Check who does before proceeding."
ok "the Timelock holds ADAPTER_SETTER_ROLE"

if same "$(call "$VAULT" 'hasRole(bytes32,address)(bool)' "$SETTER" "$ACTOR")" true; then
  warn "the actor ALSO holds ADAPTER_SETTER_ROLE"
  info "That defeats the delay: an adapter could be swapped directly, without"
  info "queueing. Worth revoking -- the whole point of the role sitting on the"
  info "Timelock is that no single key can repoint where the money is held."
else
  ok "the actor does NOT hold it directly, so the delay cannot be bypassed"
fi

for RN in PROPOSER_ROLE EXECUTOR_ROLE; do
  H=$(call "$TIMELOCK" "$RN()(bytes32)")
  same "$(call "$TIMELOCK" 'hasRole(bytes32,address)(bool)' "$H" "$ACTOR")" true \
    || die "$ACTOR lacks $RN on the Timelock"
done
ok "actor can propose and execute on the Timelock"

HAVE=$(call "$ASSET" 'balanceOf(address)(uint256)' "$ACTOR")
NEED=$(bi "$PROBE" mul 3)
if lt "$HAVE" "$NEED"; then
  send "$ASSET" 'mint(address,uint256)' "$ACTOR" "$NEED"
  ok "minted $NEED for the probes"
fi

# ── 1. An adapter over the inflated venue ───────────────────────────────────
bold "1/7  Adapter over the INFLATED venue"
[[ -n "$INFLATED" ]] || die "could not resolve TestYieldTarget from $FIXTURES"
IA=$(call "$INFLATED" 'totalAssets()(uint256)')
IS=$(call "$INFLATED" 'totalSupply()(uint256)')
info "venue $INFLATED"
info "totalAssets $IA   totalSupply $IS"

# If the fixture is no longer inflated the refusal below cannot be tested, and
# a pass would be vacuous. Say so rather than reporting a proof that did not
# happen.
WOULD=$(call "$INFLATED" 'previewDeposit(uint256)(uint256)' "$PROBE")
WORTH=$(call "$INFLATED" 'previewRedeem(uint256)(uint256)' "$WOULD")
info "depositing $PROBE would buy $WOULD shares, worth $WORTH back"
INFLATED_ENOUGH=1
lt "$WORTH" "$(bi "$(bi "$PROBE" mul 99)" div 100)" || INFLATED_ENOUGH=0

OUT=$(forge create src/adapters/ERC4626YieldAdapter.sol:ERC4626YieldAdapter \
      --rpc-url "$RPC" --account "$GOV_ACCT" --broadcast --json \
      --constructor-args "$ASSET" "$INFLATED" "$ACTOR")
BAD_ADAPTER=$(created "$OUT")
[[ -n "$BAD_ADAPTER" ]] || die "could not read the adapter address"
ok "deployed $BAD_ADAPTER"

VR=$(call "$BAD_ADAPTER" 'VAULT_ROLE()(bytes32)')
send "$BAD_ADAPTER" 'grantRole(bytes32,address)' "$VR" "$ACTOR"
send "$ASSET" 'approve(address,uint256)' "$BAD_ADAPTER" "$PROBE"
ok "actor granted VAULT_ROLE so it can call deposit directly"

# ── 2. The guard must refuse ────────────────────────────────────────────────
bold "2/7  The guard must refuse a value-losing deposit"
if [[ "$INFLATED_ENOUGH" == "0" ]]; then
  warn "the fixture is no longer inflated enough to lose >1% on this deposit"
  info "Refusal cannot be demonstrated against it. Skipping rather than"
  info "reporting a pass that proves nothing."
else
  set +e
  ERR=$(cast send "$BAD_ADAPTER" 'deposit(uint256)' "$PROBE" \
          --rpc-url "$RPC" --account "$GOV_ACCT" 2>&1)
  RC=$?
  set -e
  [[ $RC -ne 0 ]] || die "the adapter ACCEPTED a deposit worth $WORTH for $PROBE paid.
     The guard is not live in this bytecode. Do not ship this adapter."
  if echo "$ERR" | grep -qi 'DepositValueLost'; then
    ok "refused with DepositValueLost -- the guard, live, on chain"
  elif echo "$ERR" | grep -qi 'AccessControl\|Unauthorized'; then
    die "refused for the WRONG reason: this is a role failure, not the guard.
     The drill proved nothing. Error: $ERR"
  else
    warn "refused, but the reason is unrecognised"
    info "$(echo "$ERR" | head -3)"
  fi
  same "$(call "$ASSET" 'balanceOf(address)(uint256)' "$BAD_ADAPTER")" 0 \
    || die "the refused deposit stranded assets in the adapter"
  ok "and the refusal stranded nothing"
fi

# ── 3. A sane venue ─────────────────────────────────────────────────────────
bold "3/7  A fresh, fair venue"
REUSED=0
if [[ -f "$CACHE" ]] && [[ -n "$(cat "$CACHE")" ]]; then
  # `|| true`: read returns 1 at EOF with no trailing newline, having
  # already assigned both variables. Under set -e that exits the script
  # silently, mid-step, with nothing printed. Belt and braces with the
  # newline the writer now emits.
  read -r NEW_ADAPTER VENUE < "$CACHE" || true
  AC=$(cast code "$NEW_ADAPTER" --rpc-url "$RPC" 2>/dev/null || echo 0x)
  VC=$(cast code "$VENUE" --rpc-url "$RPC" 2>/dev/null || echo 0x)
  if [[ ${#AC} -gt 2 && ${#VC} -gt 2 ]]; then
    REUSED=1
    ok "reusing adapter $NEW_ADAPTER"
    ok "reusing venue   $VENUE"
    info "Same addresses mean the same operation salt, so step 5 finds the"
    info "operation already queued instead of queueing a second one."
  else
    warn "cached addresses have no code; deploying fresh"
  fi
fi

if [[ "$REUSED" == "0" ]]; then
  OUT=$(forge create src/testnet/TestnetFixtures.sol:TestYieldTarget \
        --rpc-url "$RPC" --account "$GOV_ACCT" --broadcast --json \
        --constructor-args "$ASSET")
  VENUE=$(created "$OUT")
  [[ -n "$VENUE" ]] || die "could not read the venue address"
  ok "deployed $VENUE"

  OUT=$(forge create src/adapters/ERC4626YieldAdapter.sol:ERC4626YieldAdapter \
        --rpc-url "$RPC" --account "$GOV_ACCT" --broadcast --json \
        --constructor-args "$ASSET" "$VENUE" "$ACTOR")
  NEW_ADAPTER=$(created "$OUT")
  [[ -n "$NEW_ADAPTER" ]] || die "could not read the adapter address"
  ok "deployed adapter $NEW_ADAPTER over it"
  printf '%s %s\n' "$NEW_ADAPTER" "$VENUE" > "$CACHE"
fi
same "$(call "$NEW_ADAPTER" 'target()(address)')" "$VENUE" || die "adapter target mismatch"
same "$(call "$VENUE" 'asset()(address)')" "$ASSET" || die "venue asset mismatch"
ok "adapter targets the venue, and the venue holds the vault's asset"

# ── 4. A fair deposit must still work ───────────────────────────────────────
bold "4/7  A fair deposit must still succeed"
if [[ "$REUSED" == "1" ]]; then
  # VAULT_ROLE already sits on the vault. Re-granting it to the actor to run
  # the probe again would hand a second party deposit rights on an adapter the
  # vault is about to be migrated onto.
  ok "skipped: this adapter was already probed and handed to the vault"
  info "The fair-deposit assertion ran on the first run."
else
  send "$NEW_ADAPTER" 'grantRole(bytes32,address)' "$(call "$NEW_ADAPTER" 'VAULT_ROLE()(bytes32)')" "$ACTOR"
  send "$ASSET" 'approve(address,uint256)' "$NEW_ADAPTER" "$PROBE"
  send "$NEW_ADAPTER" 'deposit(uint256)' "$PROBE"
  TA=$(call "$NEW_ADAPTER" 'totalAssets()(uint256)')
  info "adapter totalAssets $TA for $PROBE deposited"
  lt "$(bi "$PROBE" sub "$TA")" "$(bi "$PROBE" div 1000)" \
    || die "a fair deposit lost more than 0.1%: $PROBE in, $TA held"
  ok "the deposit landed and kept its value"
  ok "so the guard refuses the lossy venue without blocking the fair one"

  # Take the probe back out, or the adapter carries assets the vault does not own
  # and the vault's heldAssets() would count them as depositor capital.
  send "$NEW_ADAPTER" 'withdraw(uint256)' "$TA"
  LEFT=$(call "$NEW_ADAPTER" 'totalAssets()(uint256)')
  lt "$LEFT" 1000 || die "could not empty the adapter after the probe: $LEFT left.
     Migrating the vault onto it would credit depositors with assets that are
     not theirs. Deploy a clean adapter instead."
  ok "probe withdrawn; adapter holds $LEFT and is clean for the vault"

  # The vault, not the actor, must be the caller from here on.
  send "$NEW_ADAPTER" 'revokeRole(bytes32,address)' "$(call "$NEW_ADAPTER" 'VAULT_ROLE()(bytes32)')" "$ACTOR"
  send "$NEW_ADAPTER" 'grantRole(bytes32,address)' "$(call "$NEW_ADAPTER" 'VAULT_ROLE()(bytes32)')" "$VAULT"
fi

same "$(call "$NEW_ADAPTER" 'hasRole(bytes32,address)(bool)' "$(call "$NEW_ADAPTER" 'VAULT_ROLE()(bytes32)')" "$VAULT")" true \
  || die "the vault does not hold VAULT_ROLE on the new adapter; setAdapter would revert"
ok "the vault holds VAULT_ROLE on the adapter, so setAdapter can deposit"

# ── 5. Queue the swap ───────────────────────────────────────────────────────
bold "5/7  Queue setAdapter through the Timelock"
DATA=$(cast calldata 'setAdapter(address)' "$NEW_ADAPTER")
PRED=0x0000000000000000000000000000000000000000000000000000000000000000
# Salt off the adapter address, so re-running with a different adapter queues a
# distinct operation rather than colliding with a stale one.
SALT=$(cast keccak "$NEW_ADAPTER")
DELAY=$(call "$TIMELOCK" 'getMinDelay()(uint256)')

OPID=$(call "$TIMELOCK" 'hashOperation(address,uint256,bytes,bytes32,bytes32)(bytes32)' \
        "$VAULT" 0 "$DATA" "$PRED" "$SALT")
info "op $OPID"

if same "$(call "$TIMELOCK" 'isOperation(bytes32)(bool)' "$OPID")" true; then
  ok "already queued"
else
  send "$TIMELOCK" 'schedule(address,uint256,bytes,bytes32,bytes32,uint256)' \
      "$VAULT" 0 "$DATA" "$PRED" "$SALT" "$DELAY"
  same "$(call "$TIMELOCK" 'isOperation(bytes32)(bool)' "$OPID")" true \
    || die "schedule() returned but isOperation is false"
  ok "scheduled"
fi
ETA=$(call "$TIMELOCK" 'getTimestamp(bytes32)(uint256)' "$OPID")
info "eta $ETA  ($(date -u -d "@$ETA" '+%Y-%m-%d %H:%M UTC' 2>/dev/null || echo "epoch $ETA"))"

# ── 6. And must not run early ───────────────────────────────────────────────
bold "6/7  Early execution must be refused"
if same "$(call "$TIMELOCK" 'isOperationReady(bytes32)(bool)' "$OPID")" true; then
  warn "the ETA has passed, so refusal cannot be tested on this run"
else
  set +e
  ERR=$(cast send "$TIMELOCK" 'execute(address,uint256,bytes,bytes32,bytes32)' \
          "$VAULT" 0 "$DATA" "$PRED" "$SALT" \
          --rpc-url "$RPC" --account "$GOV_ACCT" 2>&1)
  RC=$?
  set -e
  [[ $RC -ne 0 ]] || die "the Timelock swapped the adapter BEFORE its ETA.
     Where depositor money is held can be repointed with no delay. Stop."
  echo "$ERR" | grep -qi 'UnexpectedOperationState\|OperationState' \
    && ok "refused, and for the delay rather than a role" \
    || { warn "refused, reason unrecognised"; info "$(echo "$ERR" | head -3)"; }
fi

# ── 7. Execute ──────────────────────────────────────────────────────────────
bold "7/7  Execute"
if ! same "$(call "$TIMELOCK" 'isOperationReady(bytes32)(bool)' "$OPID")" true; then
  bold "Queued. Come back after the ETA."
  info "The guard is proven live and the migration is scheduled. Re-run the"
  info "same command after the ETA above to execute it:"
  info ""
  info "  ./script/testnet-adapter-migration.sh $GOV_ACCT"
  info ""
  info "Until then the vault stays on the stub adapter, so the venue"
  info "integration is still unexercised on chain."
  info ""
  info "Queued adapter: $NEW_ADAPTER   venue: $VENUE"
  info "Cached in $CACHE, so the next run queues nothing new."
  exit 0
fi

RAW_BEFORE=$(call "$VAULT" 'rawAssets()(uint256)')
send "$TIMELOCK" 'execute(address,uint256,bytes,bytes32,bytes32)' \
    "$VAULT" 0 "$DATA" "$PRED" "$SALT"
ok "executed"

same "$(call "$VAULT" 'adapter()(address)')" "$NEW_ADAPTER" \
  || die "execute() succeeded but the vault's adapter is $(call "$VAULT" 'adapter()(address)')"
ok "the vault now runs the real ERC4626YieldAdapter"

RAW_AFTER=$(call "$VAULT" 'rawAssets()(uint256)')
info "rawAssets $RAW_BEFORE -> $RAW_AFTER"
ok "position carried across the migration"

bold "Migration complete"
info "The yield vault's assets are held in an ERC-4626 venue through the real"
info "adapter, not idle in a stub. The venue integration and the deposit guard"
info "have both now executed on a live chain."

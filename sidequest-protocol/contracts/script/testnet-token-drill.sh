#!/usr/bin/env bash
# Prove the token layer's user-facing paths on a live chain.
#
# Phase 3 of docs/LAUNCH-CHECKLIST.md, "Token layer":
#
#   airdrop   an eligible address claims and receives exactly its allocation;
#             claiming again reverts; an ineligible address cannot claim
#   vesting   nothing is claimable before a schedule is funded, and the drill
#             says so rather than pretending to test a cliff it cannot reach
#
# The timelock item is deliberately not here. It is being exercised for real
# by the treasury handover, which is a better test than a synthetic one.
#
# Usage:
#   ./script/testnet-token-drill.sh zorpha-gov
#
# The account must be in the airdrop tree. Proofs are read from the file the
# portal serves, so this also checks that what the site would hand a user is
# what the contract accepts.

set -euo pipefail

if ! command -v cast >/dev/null; then
  [[ -d "$HOME/.foundry/bin" ]] && { PATH="$HOME/.foundry/bin:$PATH"; export PATH; }
fi
command -v cast >/dev/null || { echo "ERROR: cast not found" >&2; exit 1; }
command -v node >/dev/null || { echo "ERROR: node not found" >&2; exit 1; }

ACCOUNT="${1:-}"
[[ -n "$ACCOUNT" ]] || { echo "usage: $0 <keystore-account-name>" >&2; exit 1; }

# Optional non-interactive signing.
#
# This drill unlocks a keystore once per governance send, plus an address
# lookup and a signature per instruction, and every one of them prompts. A
# single mistyped password aborts the run partway through -- after it may
# already have spent gas, which is how testnet-spot-lifecycle.sh lost a run
# with two contracts already deployed.
#
# ETH_PASSWORD is NOT the fix, despite being cast's own env var for this. Set
# it and clap marks --password-file as supplied for EVERY subcommand, so plain
# reads start failing:
#
#     cast call ... -> error: the following required arguments were not
#                      provided: --keystore <PATH>
#
# because --password-file "is used with --keystore" and cast call has neither.
# Passing the flag explicitly, only where a keystore is actually opened, has no
# such effect. --account and --password-file are a legal pair.
#
# Opt-in and empty by default, so nothing changes unless it is set:
#     ZORPHA_PASSWORD_FILE=/path/to/pw ./script/...
PW=()
[[ -n "${ZORPHA_PASSWORD_FILE:-}" ]] && {
  [[ -r "$ZORPHA_PASSWORD_FILE" ]] || { echo "ERROR: cannot read $ZORPHA_PASSWORD_FILE" >&2; exit 1; }
  [[ -s "$ZORPHA_PASSWORD_FILE" ]] || { echo "ERROR: $ZORPHA_PASSWORD_FILE is empty. A shell that captures a
       passphrase without echoing it will happily write a zero-byte file, and
       cast then reports an unhelpful decryption failure instead." >&2; exit 1; }
  PW=(--password-file "$ZORPHA_PASSWORD_FILE")
}

RPC="${RH_TESTNET_RPC_URL:-https://rpc.testnet.chain.robinhood.com/rpc}"
WEB_ENV="../../zorpha-web/.env.local"
PROOFS="../../zorpha-web/data/airdrop/proofs.json"

bold() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m+\033[0m %s\n' "$1"; }
info() { printf '    %s\n' "$1"; }
die()  { printf '\n  \033[31mx %s\033[0m\n\n' "$1" >&2; exit 1; }

bi()  { MSYS_NO_PATHCONV=1 node -e 'const [a,op,b]=process.argv.slice(1);const A=BigInt(a),B=BigInt(b);
  const f={add:()=>A+B,sub:()=>A-B,mul:()=>A*B,div:()=>A/B,
           min:()=>A<B?A:B,max:()=>A>B?A:B}[op];
  if(!f) throw new Error("unknown op: "+op);
  process.stdout.write(f().toString())' -- "$1" "$2" "$3"; }
eq()  { [[ "$1" == "$2" ]]; }

# `|| true` is load-bearing under `set -euo pipefail`. grep exits 1 when it
# finds nothing, pipefail propagates that, and the assignment then kills the
# script -- BEFORE the `[[ -n "$X" ]] || die` meant to report the missing key.
# A drill died three times printing nothing at all this way, with its own
# diagnostic sitting unreachable two lines below.
env_of() { grep -E "^$1=" "$WEB_ENV" | head -1 | cut -d= -f2- || true; }
num()    { awk '{print $1}'; }
call()   { cast call "$@" --rpc-url "$RPC" | num; }

[[ -f "$WEB_ENV" ]] || die "no $WEB_ENV"
[[ -f "$PROOFS" ]]  || die "no $PROOFS -- run the airdrop generator"

ZOR=$(env_of NEXT_PUBLIC_ZOR_ADDRESS)
DIST=$(env_of NEXT_PUBLIC_MERKLE_DISTRIBUTOR_ADDRESS)
VEST=$(env_of NEXT_PUBLIC_VESTING_ADDRESS)
ACTOR=$(cast wallet address --account "$ACCOUNT" "${PW[@]}")
KEY=$(printf '%s' "$ACTOR" | tr 'A-F' 'a-f' | sed 's/^0x//')

bold "Token layer drill"
info "ZOR          $ZOR"
info "distributor  $DIST"
info "vesting      $VEST"
info "actor        $ACTOR"

# --- Airdrop ---------------------------------------------------------------
bold "1/4  Airdrop: read this address's proof from the portal's file"
read -r INDEX AMOUNT PROOF < <(node -e '
  const p = require(process.argv[1])[process.argv[2]];
  if (!p) process.exit(3);
  // console.log, not stdout.write: `read` returns non-zero at EOF without a
  // trailing newline, and the caller treats that as "not in the tree".
  console.log([p.index, p.amount, "[" + p.proof.join(",") + "]"].join(" "));
' "$PROOFS" "$KEY") || die "$ACTOR is not in $PROOFS. Pick an account that is in the tree."
info "index $INDEX, amount $AMOUNT"
ok "proof found ($(printf '%s' "$PROOF" | tr ',' '\n' | wc -l | num) nodes)"

DEADLINE=$(call "$DIST" 'claimDeadline()(uint256)')
NOW=$(cast block latest --field timestamp --rpc-url "$RPC")
[[ "$NOW" -lt "$DEADLINE" ]] || die "claim window closed at $DEADLINE (now $NOW)"
ok "claim window open until $(date -u -d "@$DEADLINE" '+%Y-%m-%d %H:%M UTC' 2>/dev/null || echo "$DEADLINE")"

bold "2/4  Airdrop: claim"
if eq "$(call "$DIST" 'isClaimed(uint256)(bool)' "$INDEX")" true; then
  info "index $INDEX already claimed on a previous run; skipping to the double-claim check"
else
  B0=$(call "$ZOR" 'balanceOf(address)(uint256)' "$ACTOR")
  cast send "$DIST" 'claim(uint256,address,uint256,bytes32[])' "$INDEX" "$ACTOR" "$AMOUNT" "$PROOF" \
    --rpc-url "$RPC" --account "$ACCOUNT" "${PW[@]}" >/dev/null
  B1=$(call "$ZOR" 'balanceOf(address)(uint256)' "$ACTOR")
  GOT=$(bi "$B1" sub "$B0")
  eq "$GOT" "$AMOUNT" || die "received $GOT ZOR, allocation was $AMOUNT"
  ok "received exactly $(cast to-unit "$GOT" ether) ZOR"
  eq "$(call "$DIST" 'isClaimed(uint256)(bool)' "$INDEX")" true || die "isClaimed still false after a successful claim"
  ok "isClaimed($INDEX) is now true"
fi

bold "3/4  Airdrop: the two reverts that matter"
# Same proof again. Must fail.
if cast send "$DIST" 'claim(uint256,address,uint256,bytes32[])' "$INDEX" "$ACTOR" "$AMOUNT" "$PROOF" \
     --rpc-url "$RPC" --account "$ACCOUNT" "${PW[@]}" >/dev/null 2>/tmp/zorpha-claim-err; then
  die "a SECOND claim succeeded. The airdrop can be drained."
fi
ok "second claim reverted: $(grep -oE '[A-Z][A-Za-z]+\(\)' /tmp/zorpha-claim-err | head -1 || echo reverted)"

# A valid proof presented for the wrong account. Must fail.
STRANGER=0x000000000000000000000000000000000000BEEF
if cast send "$DIST" 'claim(uint256,address,uint256,bytes32[])' "$INDEX" "$STRANGER" "$AMOUNT" "$PROOF" \
     --rpc-url "$RPC" --account "$ACCOUNT" "${PW[@]}" >/dev/null 2>/tmp/zorpha-claim-err; then
  die "a claim for an address NOT in the tree succeeded"
fi
ok "ineligible address reverted: $(grep -oE '[A-Z][A-Za-z]+\(\)' /tmp/zorpha-claim-err | head -1 || echo reverted)"
rm -f /tmp/zorpha-claim-err

# --- Vesting ---------------------------------------------------------------
bold "4/4  Vesting"
N=$(call "$VEST" 'beneficiaryCount()(uint256)')
CLAIMABLE=$(call "$VEST" 'claimable(address)(uint256)' "$ACTOR")
info "beneficiaries funded: $N"
info "claimable by $ACTOR: $CLAIMABLE"
eq "$CLAIMABLE" 0 || die "claimable is non-zero with no schedule funded"
if eq "$N" 0; then
  ok "nothing vests before a schedule exists"
  echo
  echo "  The cliff and linear-release checks need a funded schedule. That is a"
  echo "  governance action with real people's addresses and amounts"
  echo "  (docs/DEPLOY-ENV.md section 4.2), not something a drill should invent."
  echo "  Fund one, then re-run this to exercise the cliff."
else
  ok "$N schedule(s) funded; cliff behaviour for $ACTOR: claimable $CLAIMABLE"
fi

bold "Drill passed"

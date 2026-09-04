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
  # Verified, not assumed.
  #
  # "already claimed on a previous run" was a guess. isClaimed only says the
  # index is spent -- it does not say WHO spent it or for how much, and those
  # are the two things that distinguish an earlier run of this drill from
  # someone else having taken this address allocation. The Claimed event
  # carries both, so read it.
  CLAIM_TOPIC=$(cast keccak 'Claimed(uint256,address,uint256)')
  INDEX_TOPIC=$(cast to-uint256 "$INDEX")
  LOG=$(cast rpc eth_getLogs "{\"address\":\"$DIST\",\"topics\":[\"$CLAIM_TOPIC\",\"$INDEX_TOPIC\"],\"fromBlock\":\"0x0\",\"toBlock\":\"latest\"}" --rpc-url "$RPC")
  read -r GOT_ACCT GOT_AMT <<<"$(MSYS_NO_PATHCONV=1 node -e '
    const logs = JSON.parse(process.argv[1]);
    if (!logs.length) { process.stdout.write("none 0"); process.exit(0); }
    const l = logs[logs.length - 1];
    process.stdout.write("0x" + l.topics[2].slice(26) + " " + BigInt(l.data).toString());
  ' -- "$LOG")"

  [[ "$GOT_ACCT" != "none" ]] || die "isClaimed($INDEX) is true but there is no Claimed
     event for it. The bitmap and the event disagree, which no ordinary claim
     can produce."
  eq "${GOT_ACCT,,}" "${ACTOR,,}" || die "index $INDEX was claimed by $GOT_ACCT, NOT by
     $ACTOR. This address allocation has been taken by someone else -- that is a
     stolen airdrop, not a previous run of this drill."
  eq "$GOT_AMT" "$AMOUNT" || die "index $INDEX was claimed for $GOT_AMT, but the proof
     file allocates $AMOUNT. The tree the distributor verifies against is not the
     tree the portal is serving."
  ok "already claimed, and by this address for exactly its allocation"
  info "$(cast to-unit "$GOT_AMT" ether) ZOR to $GOT_ACCT -- an earlier run of this drill"
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
# Matched on the SELECTOR each time, not on whether cast happened to print a name.
#
# Both checks used to report "reverted" and pass on any failure whatsoever. These
# are the two security properties of an airdrop -- it cannot be drained twice and
# it cannot be claimed by someone outside the tree -- and a claim failing for an
# unrelated reason (a closed window, a paused token, a bad nonce) satisfied them
# both. InvalidProof() takes no arguments, so its revert data is four bytes and
# cast has nothing to decode it against; AlreadyClaimed(uint256) did not match the
# zero-argument pattern the old grep looked for. Neither was ever going to print.
ERRFILE=$(mktemp)
trap 'rm -f "$ERRFILE"' EXIT
SIG_ALREADY=$(cast sig 'AlreadyClaimed(uint256)')
SIG_BADPROOF=$(cast sig 'InvalidProof()')

reverted_with() {   # reverted_with <selector> <name>
  grep -qi "${1#0x}" "$ERRFILE" && return 0
  grep -q "$2" "$ERRFILE" && return 0
  return 1
}

# Same proof again. Must fail, and must fail because it is already claimed.
if cast send "$DIST" 'claim(uint256,address,uint256,bytes32[])' "$INDEX" "$ACTOR" "$AMOUNT" "$PROOF" \
     --rpc-url "$RPC" --account "$ACCOUNT" "${PW[@]}" >/dev/null 2>"$ERRFILE"; then
  die "a SECOND claim succeeded. The airdrop can be drained."
fi
reverted_with "$SIG_ALREADY" AlreadyClaimed \
  || die "the second claim was refused, but not with AlreadyClaimed ($SIG_ALREADY).
     Something else stopped it, so the double-claim guard is still unproven:
     $(head -2 "$ERRFILE" | tr '\n' ' ' | cut -c1-160)"
ok "second claim reverted with AlreadyClaimed"

# A valid proof presented for the wrong account. Must fail ON THE PROOF.
#
# This is the check that was doing nothing, and the reason is the order inside
# claim():
#
#     if (isClaimed(index)) revert AlreadyClaimed(index);
#     ...verify the leaf...  revert InvalidProof();
#
# The claimed check comes FIRST. The old version of this step reused $INDEX --
# the drill own index, which step 2 has just spent -- so every run reverted
# AlreadyClaimed before the proof was looked at, and the assertion of the day was
# "something reverted", which AlreadyClaimed satisfies. The eligibility guard has
# never been exercised on chain by this drill. It only became visible when the
# check was tightened to name the error it expects.
#
# So the substitution has to be made against an UNCLAIMED index, which reaches
# the proof check and fails there because the leaf commits to the account.
ALL_INDEXES=$(MSYS_NO_PATHCONV=1 node -e 'const j=require(process.argv[1]);process.stdout.write(Object.values(j).map(p=>p.index).join(" "))' -- "$PROOFS")
ALT_INDEX=""
for i in $ALL_INDEXES; do
  if [[ "$(call "$DIST" 'isClaimed(uint256)(bool)' "$i")" == "false" ]]; then ALT_INDEX="$i"; break; fi
done

if [[ -z "$ALT_INDEX" ]]; then
  printf '  \033[33m~\033[0m %s\n' "every index in the tree is claimed, so there is none left to"
  info "present for the wrong account without AlreadyClaimed firing first."
  info "Eligibility is NOT tested on this run. Re-deploy the distributor to"
  info "restore the check rather than reading this as a pass."
else
  read -r ALT_AMOUNT ALT_PROOF < <(MSYS_NO_PATHCONV=1 node -e '
    const j = require(process.argv[1]);
    const p = Object.values(j).find(x => x.index === Number(process.argv[2]));
    console.log([p.amount, "[" + p.proof.join(",") + "]"].join(" "));
  ' -- "$PROOFS" "$ALT_INDEX")

  STRANGER=0x000000000000000000000000000000000000BEEF
  info "presenting index $ALT_INDEX (unclaimed) for $STRANGER, who is not its leaf"
  if cast send "$DIST" 'claim(uint256,address,uint256,bytes32[])' "$ALT_INDEX" "$STRANGER" "$ALT_AMOUNT" "$ALT_PROOF" \
       --rpc-url "$RPC" --account "$ACCOUNT" "${PW[@]}" >/dev/null 2>"$ERRFILE"; then
    die "a claim for an address NOT in the tree succeeded"
  fi
  reverted_with "$SIG_BADPROOF" InvalidProof \
    || die "the ineligible claim was refused, but not with InvalidProof ($SIG_BADPROOF).
     If it stopped at AlreadyClaimed the index was spent between the check above
     and this send, and eligibility is again untested:
     $(head -2 "$ERRFILE" | tr '\n' ' ' | cut -c1-160)"
  ok "ineligible address reverted with InvalidProof, at the leaf check"
fi

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
  echo "  The LIVE contract has no schedule, and funding one is a governance"
  echo "  action with real people's addresses and amounts"
  echo "  (docs/DEPLOY-ENV.md section 4.2), not something a drill should invent."
  echo
  echo "  The cliff, the linear release and revocation are covered instead by"
  echo "  ./script/testnet-vesting-drill.sh, which funds its own contract on a"
  echo "  backdated timescale. This step stays as a statement about the live"
  echo "  deployment: nothing is vesting here yet."
else
  ok "$N schedule(s) funded; cliff behaviour for $ACTOR: claimable $CLAIMABLE"
fi

bold "Drill passed"

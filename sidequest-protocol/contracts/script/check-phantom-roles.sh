#!/usr/bin/env bash
# Find role grants that do not correspond to any role this protocol defines.
#
# `grantRole` has no notion of an unknown role. OpenZeppelin's AccessControl
# stores a mapping from bytes32 to a member set, and `getRoleAdmin` on a hash
# nobody has ever used returns bytes32(0) -- DEFAULT_ADMIN_ROLE. So an admin
# who pastes a mistyped role hash creates a brand-new role, becomes its only
# member, and gets a successful transaction back. Nothing reverts, nothing
# warns, and the receipt looks exactly like a real grant.
#
# That happened on testnet 46630: a governance transaction granted
# 0x1a19cce4b8be31d4a3ba9c0d7dd1d0b2b7a45a2f4b2f66d1f0dfc86f1c4c4b78 on the
# StrategyExecutor. It is inert -- no function is gated on it -- but an
# unexplained role grant is where a security review stops, and "someone typed
# it wrong once" is not provable after the fact without a check like this.
#
# So: read every RoleGranted event ever emitted by every deployed contract,
# collect the distinct role hashes, and compare each against the roles the
# protocol actually declares. Anything left over is a phantom.
#
# Usage:
#   ./script/check-phantom-roles.sh
#
# Read-only. No keys, no transactions. Exits non-zero if a phantom is found.

set -euo pipefail

if ! command -v cast >/dev/null; then
  [[ -d "$HOME/.foundry/bin" ]] && { PATH="$HOME/.foundry/bin:$PATH"; export PATH; }
fi
command -v cast >/dev/null || { echo "ERROR: cast not found" >&2; exit 1; }
command -v node >/dev/null || { echo "ERROR: node not found" >&2; exit 1; }

RPC="${RH_TESTNET_RPC_URL:-https://rpc.testnet.chain.robinhood.com/rpc}"
WEB_ENV="../../zorpha-web/.env.local"

bold() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m+\033[0m %-12s %s\n' "$1" "$2"; }
bad()  { printf '  \033[31mPHANTOM\033[0m %-12s %s\n' "$1" "$2"; }
die()  { printf '\n  \033[31mx %s\033[0m\n\n' "$1" >&2; exit 1; }

[[ -f "$WEB_ENV" ]] || die "no $WEB_ENV"
env_of() { grep -E "^$1=" "$WEB_ENV" | head -1 | cut -d= -f2-; }

# Extract topic1 of every RoleGranted, distinct.
#
# From --json, not by counting lines of the human-readable output. The first
# attempt grepped the indented topic lines and took every third: there are FOUR
# topics per log because topic0 is the event signature, so it read the
# signature hash and padded addresses as role hashes and reported sixteen
# phantoms that were all artefacts of the parser. Counting positions in someone
# else's output format is guessing; asking for structured data is not.
role_hashes() {
  cast logs --rpc-url "$RPC" --address "$1" --from-block 0 \
       'RoleGranted(bytes32,address,address)' --json 2>/dev/null \
  | MSYS_NO_PATHCONV=1 node -e '
      let s = "";
      process.stdin.on("data", d => s += d).on("end", () => {
        try {
          const logs = JSON.parse(s || "[]");
          const seen = new Set(logs.map(l => l.topics[1]));
          if (seen.size) console.log([...seen].join("\n"));
        } catch { /* no logs, or not an AccessControl contract */ }
      });
    ' || true
}

# Role names, read out of the contracts rather than listed here.
#
# The hand-written version of this list was wrong twice over: it invented
# ORACLE_UPDATER_ROLE, which does not exist -- the real name is UPDATER_ROLE --
# and it omitted SWEEPER_ROLE, which is what gates sweeping the airdrop. So the
# phantom check reported an ordinary deploy-time grant as a finding, and the
# burned-key check would have called a key clear while it held the sweeper role.
#
# A list of things the code already declares will drift from the code, and the
# drift shows up as false findings, which is the fastest way to make a check
# worth ignoring. Every role here is a keccak256("NAME") literal in src/, so
# read them from there.
mapfile -t ROLE_NAMES < <(
  grep -rhoE 'keccak256\("[A-Z_]+"\)' src     | sed -E 's/^keccak256\("//; s/"\)$//'     | sort -u
)

# TimelockController's roles come from OpenZeppelin rather than a literal in
# src/, so they are the one part that must still be named.
ROLE_NAMES+=(PROPOSER_ROLE EXECUTOR_ROLE CANCELLER_ROLE TIMELOCK_ADMIN_ROLE)

[[ ${#ROLE_NAMES[@]} -gt 4 ]]   || die "no role declarations found in src/ -- the grep is broken, not the chain"

declare -A KNOWN
KNOWN["0x0000000000000000000000000000000000000000000000000000000000000000"]="DEFAULT_ADMIN_ROLE"
for nm in "${ROLE_NAMES[@]}"; do
  KNOWN["$(cast keccak "$nm")"]="$nm"
done

CONTRACTS=(
  "ZOR:NEXT_PUBLIC_ZOR_ADDRESS"
  "Timelock:NEXT_PUBLIC_TIMELOCK_ADDRESS"
  "Treasury:NEXT_PUBLIC_TREASURY_ADDRESS"
  "Buyback:NEXT_PUBLIC_BUYBACK_ADDRESS"
  "Insurance:NEXT_PUBLIC_INSURANCE_ADDRESS"
  "Distributor:NEXT_PUBLIC_MERKLE_DISTRIBUTOR_ADDRESS"
  "Vesting:NEXT_PUBLIC_VESTING_ADDRESS"
  "Factory:NEXT_PUBLIC_VAULT_FACTORY_ADDRESS"
  "Executor:NEXT_PUBLIC_STRATEGY_EXECUTOR_ADDRESS"
  "Reputation:NEXT_PUBLIC_REPUTATION_REGISTRY_ADDRESS"
  "Launcher:NEXT_PUBLIC_VAULT_LAUNCHER_ADDRESS"
)

bold "Phantom role audit against chain $(cast chain-id --rpc-url "$RPC")"
echo "  ${#KNOWN[@]} declared role hashes, ${#CONTRACTS[@]} contracts"

PHANTOMS=0
for c in "${CONTRACTS[@]}"; do
  CNAME="${c%%:*}"; CADDR=$(env_of "${c##*:}")
  [[ -z "$CADDR" || "$CADDR" == "0x0000000000000000000000000000000000000000" ]] && continue

  while read -r r; do
    [[ -z "$r" ]] && continue
    if [[ -n "${KNOWN[$r]:-}" ]]; then
      ok "$CNAME" "${KNOWN[$r]}"
    else
      bad "$CNAME" "$r"
      PHANTOMS=$((PHANTOMS + 1))
    fi
  done < <(role_hashes "$CADDR")
done

bold "Result"
if [[ "$PHANTOMS" == "0" ]]; then
  echo "  Every role ever granted on this deployment maps to a declared role."
  exit 0
fi
echo "  $PHANTOMS phantom grant(s). Each is a hash somebody granted that"
echo "  corresponds to no role name in this protocol -- almost certainly a"
echo "  mistyped bytes32 in a governance transaction, which grantRole accepts"
echo "  in silence. Revoke it, or add its name to src/ if it is real."
die "$PHANTOMS phantom role grant(s)"

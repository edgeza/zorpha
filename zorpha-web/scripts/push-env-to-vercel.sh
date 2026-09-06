#!/usr/bin/env bash
# Push the app's env vars from .env.local into Vercel production.
#
# WHY THIS IS NEEDED
#
# The production deploy of zorpha.xyz has SEVEN app env vars set. It is missing
# all twelve contract addresses and both Supabase credentials. The symptom on
# the live site:
#
#   CIRCULATING SUPPLY   , 
#   BURNED TO DATE       , 
#   USDG SPENT           , 
#   $ZOR BURNED          , 
#   TRIGGER THRESHOLD    , 
#   Bond, $ZOR      (on /portal/leaders/launch)
#
# Every on-chain read is dead. And the site LOOKS healthy, because the
# database-backed panels -- "3 vaults live", the vault list with correct
# symbols -- are baked into prerendered HTML at build time and keep displaying.
# A broken site that looks fine is worse than one that looks broken.
#
# NEXT_PUBLIC_ variables are INLINED AT BUILD TIME, so setting them is not
# enough. The site must be rebuilt afterwards. That is why this script ends by
# telling you to redeploy rather than pretending it is done.
#
# WHAT IT DOES NOT DO
#
# It does not print any value. Contract addresses are public, but the Supabase
# anon key goes through the same path and there is no reason to put it on a
# terminal. Names only.
#
# Usage, from zorpha-web/:
#   ./scripts/push-env-to-vercel.sh            # show what would change
#   ./scripts/push-env-to-vercel.sh --apply    # actually set them

set -euo pipefail

APPLY=0
[[ "${1:-}" == "--apply" ]] && APPLY=1

ENV_FILE=".env.local"
TARGET="production"

command -v vercel >/dev/null || { echo "ERROR: vercel CLI not found. npm i -g vercel" >&2; exit 1; }
[[ -f "$ENV_FILE" ]] || { echo "ERROR: no $ENV_FILE here. Run from zorpha-web/." >&2; exit 1; }

# Everything the app reads at build time. Deliberately explicit rather than
# "every NEXT_PUBLIC_ in the file": a stray local-only value pushed to
# production is how NEXT_PUBLIC_SITE_URL=http://localhost:3000 would end up in
# a wallet approval dialog.
VARS=(
  NEXT_PUBLIC_ZOR_ADDRESS
  NEXT_PUBLIC_VESTING_ADDRESS
  NEXT_PUBLIC_MERKLE_DISTRIBUTOR_ADDRESS
  NEXT_PUBLIC_BUYBACK_ADDRESS
  NEXT_PUBLIC_TREASURY_ADDRESS
  NEXT_PUBLIC_INSURANCE_ADDRESS
  NEXT_PUBLIC_TIMELOCK_ADDRESS
  NEXT_PUBLIC_VAULT_FACTORY_ADDRESS
  NEXT_PUBLIC_STRATEGY_EXECUTOR_ADDRESS
  NEXT_PUBLIC_REPUTATION_REGISTRY_ADDRESS
  NEXT_PUBLIC_VAULT_LAUNCHER_ADDRESS
  NEXT_PUBLIC_LEADER_FAUCET_ADDRESS
  NEXT_PUBLIC_ORACLE_ADDRESS
  NEXT_PUBLIC_SPOT_VAULT_ADDRESS
  NEXT_PUBLIC_ROTATION_VAULT_ADDRESS
  NEXT_PUBLIC_YIELD_VAULT_ADDRESS
  NEXT_PUBLIC_SUPABASE_URL
  NEXT_PUBLIC_SUPABASE_ANON_KEY
)

# NOT pushed, on purpose. SITE_URL is already correct on Vercel and the local
# value is http://localhost:3000 -- pushing it would put localhost in the
# wallet approval dialog, which is the exact failure scripts/check-env.mjs
# exists to refuse.
SKIP_NOTE="NEXT_PUBLIC_SITE_URL, NEXT_PUBLIC_RPC_URL, NEXT_PUBLIC_EXPLORER_URL, NEXT_PUBLIC_CHAIN_ID"

value_of() {
  grep -E "^$1=" "$ENV_FILE" | head -1 | cut -d= -f2- || true
}

echo ""
echo "  Target: Vercel $TARGET"
echo "  Source: $ENV_FILE"
echo "  Skipped deliberately: $SKIP_NOTE"
echo ""

SET=0
MISSING=0
for v in "${VARS[@]}"; do
  val=$(value_of "$v")
  if [[ -z "$val" ]]; then
    printf '  %-46s not in %s, skipping\n' "$v" "$ENV_FILE"
    MISSING=$((MISSING + 1))
    continue
  fi

  if [[ "$APPLY" == "0" ]]; then
    printf '  %-46s would set (%d chars)\n' "$v" "${#val}"
    SET=$((SET + 1))
    continue
  fi

  # Remove any existing value first: `vercel env add` on an existing name
  # prompts, and a prompt in a loop is a hang.
  vercel env rm "$v" "$TARGET" --yes >/dev/null 2>&1 || true
  printf '%s' "$val" | vercel env add "$v" "$TARGET" >/dev/null 2>&1
  printf '  %-46s set\n' "$v"
  SET=$((SET + 1))
done

echo ""
if [[ "$APPLY" == "0" ]]; then
  echo "  Dry run. $SET would be set, $MISSING absent locally."
  echo "  Re-run with --apply to push them."
else
  echo "  $SET pushed, $MISSING absent locally."
  echo ""
  echo "  NOT LIVE YET. NEXT_PUBLIC_ values are inlined at build time, so the"
  echo "  running site still has the old (empty) ones until it is rebuilt:"
  echo ""
  echo "      vercel --prod"
  echo ""
  echo "  Then confirm on https://www.zorpha.xyz/portal that CIRCULATING SUPPLY"
  echo "  shows a number rather than an em dash. That single field is the"
  echo "  fastest check that the on-chain layer is alive."
fi
echo ""

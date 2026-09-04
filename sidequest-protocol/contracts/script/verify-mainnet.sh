#!/usr/bin/env bash
#
# Verify the mainnet deployment on the block explorer.
#
# mainnet-launch.sh broadcasts without --verify, so everything it deploys lands
# unverified. For most contracts that is untidy. For the TOKEN it is material:
# an unverified contract shows no source, no read tab, and no way for anyone to
# confirm the supply is capped or that no mint function exists. On a screener it
# is the loudest scam signal there is, and it is the first thing a careful buyer
# checks.
#
# Reads addresses and constructor arguments out of the broadcast files rather
# than taking them as parameters, because those are the values actually sent.
# Retyping nine addresses is a way to verify the wrong thing and believe you are
# finished.
#
# Safe to re-run: anything already verified reports as such and is counted.
set -euo pipefail

RPC="${RH_MAINNET_RPC_URL:-https://rpc.mainnet.chain.robinhood.com}"
export RH_EXPLORER_URL="${RH_EXPLORER_URL:-https://robinhoodchain.blockscout.com}"
EXPLORER="$RH_EXPLORER_URL"
CHAIN_ID=4663

bold() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m+\033[0m %s\n' "$1"; }
info() { printf '    %s\n' "$1"; }
warn() { printf '  \033[33m~\033[0m %s\n' "$1"; }

declare -A SRC=(
  [Zorpha]=src/Zorpha.sol:Zorpha
  [Timelock]=src/governance/Timelock.sol:Timelock
  [ZorphaBuyback]=src/ZorphaBuyback.sol:ZorphaBuyback
  [InsuranceFund]=src/InsuranceFund.sol:InsuranceFund
  [ProtocolTreasury]=src/ProtocolTreasury.sol:ProtocolTreasury
  [MerkleDistributor]=src/MerkleDistributor.sol:MerkleDistributor
  [ZorphaVesting]=src/ZorphaVesting.sol:ZorphaVesting
  [VaultFactory]=src/VaultFactory.sol:VaultFactory
  [VaultLauncher]=src/leadership/VaultLauncher.sol:VaultLauncher
)

declare -A CTOR=(
  [Zorpha]="constructor(address)"
  [Timelock]="constructor(uint256,address[],address[],address)"
  [ZorphaBuyback]="constructor(address,address,uint256,address)"
  [InsuranceFund]="constructor(address)"
  [ProtocolTreasury]="constructor(address,address)"
  [MerkleDistributor]="constructor(address,bytes32,uint256,address)"
  [ZorphaVesting]="constructor(address,address)"
  [VaultFactory]="constructor(address)"
  [VaultLauncher]="constructor(address,address,address,address,address)"
)

bold "Verifying the mainnet deployment"
info "explorer $EXPLORER"
info "chain    $CHAIN_ID"

KEY_ARGS=()
[[ -n "${RH_EXPLORER_API_KEY:-}" ]] && KEY_ARGS=(--etherscan-api-key "$RH_EXPLORER_API_KEY")

DONE=0
FAILED=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

for script in DeployZorphaToken DeployMinimal; do
  BC="broadcast/$script.s.sol/$CHAIN_ID/run-latest.json"
  if [[ ! -f "$BC" ]]; then warn "no broadcast for $script, skipping"; continue; fi

  bold "$script"
  node -e '
    const j=require(process.argv[1]);
    for (const t of (j.transactions||[])) {
      if (t.transactionType!=="CREATE") continue;
      console.log(t.contractName + " " + t.contractAddress);
    }
  ' "./$BC" > "$TMP/list.txt"

  while read -r NAME ADDR; do
    [[ -n "$NAME" ]] || continue
    TARGET="${SRC[$NAME]:-}"
    if [[ -z "$TARGET" ]]; then warn "$NAME has no source mapping, skipping"; continue; fi

    CODE=$(cast code "$ADDR" --rpc-url "$RPC" 2>/dev/null || echo 0x)
    if [[ ${#CODE} -le 2 ]]; then warn "$NAME at $ADDR has no code, skipping"; continue; fi

    # Arguments one per line, so array values keep their bracket syntax intact
    # and nothing depends on a separator that could appear inside a value.
    node -e '
      const j=require(process.argv[1]);
      const t=(j.transactions||[]).find(x=>x.contractAddress&&x.contractAddress.toLowerCase()===process.argv[2].toLowerCase());
      for (const a of (t && t.arguments ? t.arguments : [])) console.log(String(a));
    ' "./$BC" "$ADDR" > "$TMP/args.txt"

    ENC=""
    if [[ -s "$TMP/args.txt" && -n "${CTOR[$NAME]:-}" ]]; then
      mapfile -t ARR < "$TMP/args.txt"
      ENC=$(cast abi-encode "${CTOR[$NAME]}" "${ARR[@]}" 2>/dev/null || echo "")
    fi

    OUT=$(forge verify-contract "$ADDR" "$TARGET" \
            --chain-id "$CHAIN_ID" \
            --verifier blockscout \
            --verifier-url "$EXPLORER/api" \
            "${KEY_ARGS[@]}" \
            ${ENC:+--constructor-args "$ENC"} \
            --watch 2>&1) || true

    # Trust what the verifier SAYS, not only its exit code. forge exits non-zero
    # when --watch times out against a slow explorer while the verification
    # lands anyway -- that happened twice on testnet and sent the operator off
    # to redo work already done.
    if grep -qiE 'already verified|successfully verified|is verified' <<<"$OUT"; then
      ok "$NAME  $ADDR"
      DONE=$((DONE+1))
    else
      warn "$NAME  $ADDR"
      info "$(head -3 <<<"$OUT" | tr '\n' ' ' | cut -c1-150)"
      FAILED=$((FAILED+1))
    fi
  done < "$TMP/list.txt"
done

bold "Result"
echo "  verified: $DONE"
echo "  failed:   $FAILED"
if [[ "$FAILED" -gt 0 ]]; then
  echo
  echo "  A failure here is usually the explorer being slow rather than a source"
  echo "  mismatch. Re-run; anything already verified is reported as such."
fi
echo
echo "  Token: $EXPLORER/token/0x9684AFe2422a0B03719201c78959b6B70e8d4ae8"

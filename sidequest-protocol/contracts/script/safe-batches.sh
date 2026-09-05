#!/usr/bin/env bash
# Generates Safe Transaction Builder JSON batches for the Zorpha mainnet (4663)
# hand-over and supply lock. Import each file at app.safe.global -> Transaction
# Builder -> "Drag and drop a JSON file".
#
# Nothing here signs or sends. It only encodes calldata.
#
#   ./safe-batches.sh                       # defaults below
#   LOCK_ZOR=750000000 CLIFF_DAYS=365 ./safe-batches.sh
#   NEW_SAFE_OWNER=0xabc... ./safe-batches.sh
set -euo pipefail

RPC=${RH_MAINNET_RPC_URL:-https://rpc.mainnet.chain.robinhood.com/rpc}
OUT=${OUT:-safe-batches}

ZOR=0x9684AFe2422a0B03719201c78959b6B70e8d4ae8
SAFE=0xC75E64Ccf3ce6E2F40939Ab58255681769BcF8C4
TIMELOCK=0x813D69B8e1DBE2E08bcB892BE203A6BCE99b36Fc
TREASURY=0x3D9FE37DC0D08BeD0CD48c74Cb344064df9fB3C6
VESTING=0x81613D9914F7b4c02c897941757a99BC191De88e

LOCK_ZOR=${LOCK_ZOR:-800000000}          # whole tokens to lock in vesting
CLIFF_DAYS=${CLIFF_DAYS:-180}
VEST_DAYS=${VEST_DAYS:-1095}             # 3 years
REVOCABLE=${REVOCABLE:-false}            # MUST be false for a credible lock
SALT=${SALT:-0x0000000000000000000000000000000000000000000000000000000000000000}
PREDECESSOR=0x0000000000000000000000000000000000000000000000000000000000000000

mkdir -p "$OUT"
NOW=$(cast block latest --rpc-url "$RPC" -f timestamp)
DELAY=$(cast call "$TIMELOCK" 'getMinDelay()(uint256)' --rpc-url "$RPC" | awk '{print $1}')
START=${START:-$NOW}
CLIFF=$((CLIFF_DAYS * 86400))
VEST=$((VEST_DAYS * 86400))
AMT=$(cast to-wei "$LOCK_ZOR" ether)

emit () { # emit <file> <name> <description> <to:value:data>...
  local f="$1" name="$2" desc="$3"; shift 3
  { printf '{\n  "version": "1.0",\n  "chainId": "4663",\n  "createdAt": %s000,\n' "$NOW"
    printf '  "meta": { "name": %s, "description": %s, "txBuilderVersion": "1.16.5" },\n' "\"$name\"" "\"$desc\""
    printf '  "transactions": [\n'
    local first=1
    for t in "$@"; do
      local to=${t%%:*}; local rest=${t#*:}; local val=${rest%%:*}; local data=${rest#*:}
      [ $first -eq 0 ] && printf ',\n'; first=0
      printf '    { "to": "%s", "value": "%s", "data": "%s", "contractMethod": null, "contractInputsValues": null }' "$to" "$val" "$data"
    done
    printf '\n  ]\n}\n'
  } > "$OUT/$f"
  echo "  wrote $OUT/$f"
}

ACCEPT=$(cast calldata 'acceptOwnership()')
SCHED=$(cast calldata 'schedule(address,uint256,bytes,bytes32,bytes32,uint256)' "$TREASURY" 0 "$ACCEPT" "$PREDECESSOR" "$SALT" "$DELAY")
EXECD=$(cast calldata 'execute(address,uint256,bytes,bytes32,bytes32)' "$TREASURY" 0 "$ACCEPT" "$PREDECESSOR" "$SALT")
APPROVE=$(cast calldata 'approve(address,uint256)' "$VESTING" "$AMT")
FUND=$(cast calldata 'fund(address[],uint256[],uint64[],uint64[],bool[],uint64)' \
        "[$SAFE]" "[$AMT]" "[$CLIFF]" "[$VEST]" "[$REVOCABLE]" "$START")

echo "Zorpha Safe batches  (now=$NOW  timelock delay=${DELAY}s)"
emit 1-treasury-schedule.json "1 - Timelock schedules Treasury handover" \
  "Queues ProtocolTreasury.acceptOwnership() on the Timelock. Executable after ${DELAY}s." \
  "$TIMELOCK:0:$SCHED"
emit 2-vesting-lock.json "2 - Lock ${LOCK_ZOR} ZOR in vesting" \
  "Approve + fund: ${LOCK_ZOR} ZOR to the Safe on a ${CLIFF_DAYS}d cliff / ${VEST_DAYS}d linear schedule, revocable=${REVOCABLE}." \
  "$ZOR:0:$APPROVE" "$VESTING:0:$FUND"
emit 3-treasury-execute.json "3 - Execute Treasury handover (after delay)" \
  "Run only after the ${DELAY}s timelock has elapsed. Salt must match batch 1." \
  "$TIMELOCK:0:$EXECD"

if [ -n "${NEW_SAFE_OWNER:-}" ]; then
  ADD=$(cast calldata 'addOwnerWithThreshold(address,uint256)' "$NEW_SAFE_OWNER" 2)
  emit 0-add-safe-owner.json "0 - Add second Safe owner (2-of-2)" \
    "Adds $NEW_SAFE_OWNER and raises threshold to 2." "$SAFE:0:$ADD"
else
  echo "  (skipped 0-add-safe-owner.json -- set NEW_SAFE_OWNER=0x... to generate)"
fi
echo
echo "Lock: $LOCK_ZOR ZOR  start=$START  cliff=${CLIFF}s  vest=${VEST}s  revocable=$REVOCABLE"
echo "Float left in Safe: $((880000000 - LOCK_ZOR)) ZOR"

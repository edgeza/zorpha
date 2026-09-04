#!/usr/bin/env bash
#
# Create the governance Safe.
#
# GOVERNANCE cannot be the deploy key -- both deploy scripts refuse that
# outright -- and LIQUIDITY_RECIPIENT must be a contract, because
# MainnetSafety.checkTokenLaunch refuses a bare EOA on 4663. One Safe satisfies
# both, and nothing in either script pairs them, so this is the only Safe the
# launch needs.
#
# Written as a script rather than two cast commands because the initializer is a
# hand-encoded call to setup() with eight arguments, three of which are
# addresses that must be right for the chain. A malformed one produces a proxy
# that deploys, looks fine, and cannot execute a transaction -- discovered when
# governance first tries to use it, which is the worst possible moment.
#
# It predicts the address first, deploys, then reads the owners and threshold
# back off chain. If any of that disagrees it stops rather than reporting an
# address that might not work.
set -euo pipefail

# ONE owner, deliberately. A launch Safe with a single owner is the smallest
# thing that satisfies both requirements, and more owners are added afterwards
# through the Safe app, which handles the multi-owner transaction properly. A
# script that took an owner list would encode the initializer for a
# configuration nobody had reviewed in a UI first.
OWNER="${1:-}"
THRESHOLD="${2:-1}"
ACCOUNT="${3:-mainnet-deploy}"

[[ -n "$OWNER" ]] || {
  echo "usage: $0 <owner-address> [threshold] [keystore]" >&2
  echo "  e.g. $0 0x070E3c6766CB6C7DEce7401A9e562a0C8D25f8eF 1 mainnet-deploy" >&2
  exit 1
}

RPC="${RH_MAINNET_RPC_URL:-https://rpc.mainnet.chain.robinhood.com}"

# Safe 1.4.1, verified present on 4663 before this script was written.
FACTORY=0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67
SINGLETON=0x29fcB43b46531BcA003ddC8FCB67FFE91900C762
FALLBACK=0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99
ZERO=0x0000000000000000000000000000000000000000

bold() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m+\033[0m %s\n' "$1"; }
info() { printf '    %s\n' "$1"; }
die()  { printf '\n  \033[31mx %s\033[0m\n' "$1" >&2; exit 1; }

PW=()
[[ -n "${ZORPHA_PASSWORD_FILE:-}" ]] && {
  [[ -r "$ZORPHA_PASSWORD_FILE" ]] || { echo "ERROR: cannot read $ZORPHA_PASSWORD_FILE" >&2; exit 1; }
  [[ -s "$ZORPHA_PASSWORD_FILE" ]] || { echo "ERROR: $ZORPHA_PASSWORD_FILE is empty." >&2; exit 1; }
  PW=(--password-file "$ZORPHA_PASSWORD_FILE")
}

# A mistyped owner is unrecoverable: the Safe deploys, and nobody can sign for
# it. cast normalises the checksum, so comparing against the input catches a
# wrong character rather than merely a wrong case.
CHECKED=$(cast to-check-sum-address "$OWNER" 2>/dev/null) || die "$OWNER is not a valid address"
[[ "${CHECKED,,}" == "${OWNER,,}" ]] || die "address mismatch: $OWNER vs $CHECKED"

CHAIN=$(cast chain-id --rpc-url "$RPC")
bold "Create Safe"
info "chain      $CHAIN"
info "owner      $CHECKED"
info "threshold  $THRESHOLD of 1 owner"
info "deployer   $(cast wallet address --account "$ACCOUNT" "${PW[@]}")"

for pair in "$FACTORY|SafeProxyFactory" "$SINGLETON|Safe singleton" "$FALLBACK|fallback handler"; do
  a="${pair%%|*}"; n="${pair##*|}"
  code=$(cast code "$a" --rpc-url "$RPC")
  [[ ${#code} -gt 2 ]] || die "$n has no code at $a on chain $CHAIN. Safe is not deployed here."
done
ok "Safe 1.4.1 factory, singleton and fallback handler all present on $CHAIN"

# --- The initializer ------------------------------------------------------
#
# setup() is delegatecalled by the proxy on creation. The three trailing zero
# arguments are the payment mechanism Safe supports for relayed deployments and
# which we are not using; `to` and `data` are the optional setup module call,
# also unused. The fallback handler is NOT optional -- a Safe without one cannot
# receive ERC-721/1155 transfers or answer EIP-1271 signature checks, which is
# exactly what this Safe will be asked to do once it becomes authorizedSigner.
INIT=$(cast calldata \
  "setup(address[],uint256,address,bytes,address,address,uint256,address)" \
  "[$CHECKED]" "$THRESHOLD" "$ZERO" 0x "$FALLBACK" "$ZERO" 0 "$ZERO")

# A salt fixed to the owner, so re-running this produces the same address rather
# than a second Safe. Deploying twice by accident is easy and the second one is
# indistinguishable from the first except that it holds nothing.
SALT=$(cast to-uint256 "$(cast keccak "zorpha-governance-$CHECKED")")

bold "Predicting"
PREDICTED=$(cast call "$FACTORY" \
  "createProxyWithNonce(address,bytes,uint256)(address)" \
  "$SINGLETON" "$INIT" "$SALT" --rpc-url "$RPC" | awk '{print $1}')
[[ -n "$PREDICTED" && "$PREDICTED" != "$ZERO" ]] || die "the factory would not create a proxy with these arguments"
info "the Safe will be deployed at $PREDICTED"

EXISTING=$(cast code "$PREDICTED" --rpc-url "$RPC")
if [[ ${#EXISTING} -gt 2 ]]; then
  ok "a Safe already exists at this address -- nothing to do"
  info "owners:    $(cast call "$PREDICTED" 'getOwners()(address[])' --rpc-url "$RPC")"
  info "threshold: $(cast call "$PREDICTED" 'getThreshold()(uint256)' --rpc-url "$RPC" | awk '{print $1}')"
  echo
  echo "  GOVERNANCE=$PREDICTED"
  echo "  LIQUIDITY_RECIPIENT=$PREDICTED"
  exit 0
fi

bold "Deploying"
cast send "$FACTORY" \
  "createProxyWithNonce(address,bytes,uint256)" \
  "$SINGLETON" "$INIT" "$SALT" \
  --rpc-url "$RPC" --account "$ACCOUNT" "${PW[@]}" >/dev/null
ok "sent"

# --- Verify, rather than trust the prediction -----------------------------
bold "Verifying"
CODE=$(cast code "$PREDICTED" --rpc-url "$RPC")
[[ ${#CODE} -gt 2 ]] || die "nothing was deployed at $PREDICTED"
ok "there is a contract at $PREDICTED"

GOT_OWNERS=$(cast call "$PREDICTED" 'getOwners()(address[])' --rpc-url "$RPC")
echo "$GOT_OWNERS" | grep -qi "${CHECKED:2}" || die "the Safe owners are $GOT_OWNERS, which does not include $CHECKED.
     Do not use this Safe -- nobody you control can sign for it."
ok "owner is $CHECKED"

GOT_THRESHOLD=$(cast call "$PREDICTED" 'getThreshold()(uint256)' --rpc-url "$RPC" | awk '{print $1}')
[[ "$GOT_THRESHOLD" == "$THRESHOLD" ]] || die "threshold is $GOT_THRESHOLD, expected $THRESHOLD"
ok "threshold is $GOT_THRESHOLD"

# The fallback handler lives in a fixed storage slot, per Safe. Reading it back
# is the only way to know the initializer was encoded correctly -- a Safe with a
# zero handler deploys and works for plain transactions, and fails the first
# time it is asked for an EIP-1271 signature.
SLOT=0x6c9a6c4a39284e37ed1cf53d337577d14212a4870fb976a4366c693b939918d5
HANDLER=$(cast storage "$PREDICTED" "$SLOT" --rpc-url "$RPC")
HANDLER_ADDR="0x${HANDLER: -40}"
[[ "${HANDLER_ADDR,,}" == "${FALLBACK,,}" ]] || die "fallback handler is $HANDLER_ADDR, expected $FALLBACK.
     This Safe cannot answer EIP-1271, so it could not act as authorizedSigner."
ok "fallback handler is set, so EIP-1271 will work"

bold "Done"
echo "  Use this address for BOTH roles -- nothing in either deploy script"
echo "  pairs them, and governance is the natural holder of the liquidity"
echo "  tranche it is expected to deploy into a pool:"
echo
echo "    GOVERNANCE=$PREDICTED"
echo "    LIQUIDITY_RECIPIENT=$PREDICTED"
echo
echo "  Add it to Rabby as a watch-only address to see it, and to the Safe app"
echo "  at app.safe.global to sign with it."

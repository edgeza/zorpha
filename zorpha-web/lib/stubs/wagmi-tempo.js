/**
 * Build stub for `@wagmi/core/tempo`.
 *
 * `@wagmi/core@3.5.5` ships Tempo-chain support whose actions import
 * `viem/tempo/zones` and `Actions.zone.getDepositStatus` from `viem/tempo`.
 * Neither exists in any published viem: 2.56.1 is the latest release and its
 * exports map stops at `./tempo`, `./tempo/actions` and `./tempo/chains`. The
 * package is simply ahead of its own peer.
 *
 * That would be someone else's problem except that `@wagmi/connectors`'s barrel
 * re-exports `tempoWallet` from it, and `@lifi/widget-provider-ethereum` imports
 * `safe` from the `wagmi/connectors` barrel. So building the bridge page drags
 * in an unresolvable module through a connector nothing here registers.
 *
 * `lib/wagmi.ts` avoids the barrel with per-connector subpath imports, but the
 * LI.FI provider is third-party code and cannot be changed. Aliasing this
 * entrypoint to a stub cuts the subtree at exactly one place.
 *
 * Aliasing to `false` would leave the barrel re-exporting a binding that no
 * longer exists, so the exports are kept and made to throw instead. Nothing in
 * this app registers a Tempo connector; if that ever changes, the throw says
 * why it did not work rather than failing as an undefined connector deep inside
 * wagmi.
 *
 * Remove this once viem publishes `./tempo/zones`.
 */

function unavailable(name) {
  return () => {
    throw new Error(
      `${name} is not available: @wagmi/core/tempo is stubbed out at build time ` +
        'because it imports viem/tempo/zones, which no published viem exports. ' +
        'See lib/stubs/wagmi-tempo.js.',
    );
  };
}

export const tempoWallet = unavailable('tempoWallet');
export const dangerous_secp256k1 = unavailable('dangerous_secp256k1');
export const webAuthn = unavailable('webAuthn');
export const Actions = {};

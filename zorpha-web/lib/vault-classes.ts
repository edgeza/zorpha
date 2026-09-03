/**
 * The three vault mandates shipping at V1, in one place.
 *
 * WHY THIS FILE EXISTS
 *
 * The same three vaults were described in two marketing pages with symbols
 * hardcoded in each, and they drifted from the chain:
 *
 *     site said          deployed
 *     zqEQ               zqtAAPL
 *     zqROT              zqROT      (the only match)
 *     zqUSD              zqtUSDG
 *
 * Two of the three symbols on the front page belonged to no contract. For a
 * product whose entire pitch is "read the chain rather than our summary", a
 * summary that disagrees with the chain is the worst available bug, and
 * duplicating the list across pages is what let it happen quietly.
 *
 * THE TESTNET PREFIX IS REAL AND DELIBERATE
 *
 * Testnet vaults hold Robinhood's own test tokens, so their symbols carry a
 * `t`: tAAPL, tUSDG. That prefix disappears on mainnet, where the underlying
 * is the real Stock Token. Both are recorded here so the mainnet rename is a
 * one-line change with a visible diff, rather than a search for string
 * literals across pages the day of the deploy.
 */

export type VaultClass = {
  /** Symbol as deployed on testnet, chain 46630. Verified on chain. */
  symbolTestnet: string;
  /** Symbol planned for mainnet, chain 4663, once the `t` prefix drops. */
  symbolMainnet: string;
  /** Human name for the mandate, stable across networks. */
  name: string;
  mandate: string;
  detail: string;
};

export const VAULT_CLASSES: readonly VaultClass[] = [
  {
    symbolTestnet: 'zqtAAPL',
    symbolMainnet: 'zqAAPL',
    name: 'Long / Flat Equity',
    mandate: 'Moves a single Stock Token between full exposure and cash.',
    detail: 'Oracle-gated · 1% max slippage · 20% performance fee',
  },
  {
    symbolTestnet: 'zqROT',
    symbolMainnet: 'zqROT',
    name: 'RWA Rotation',
    mandate: 'Reweights a basket of Stock Tokens against a USDG base.',
    detail: 'Per-asset oracles · basket weights onchain · 20% performance fee',
  },
  {
    symbolTestnet: 'zqtUSDG',
    symbolMainnet: 'zqUSDG',
    name: 'USDG Yield',
    mandate: 'Routes idle USDG through a pluggable yield adapter.',
    detail: 'Adapter swaps are timelocked · 10% performance fee',
  },
] as const;

/**
 * Which symbol to show. Mainnet is not deployed, so this reads testnet today
 * and flips on one environment variable rather than an edit.
 */
export function vaultSymbol(v: VaultClass): string {
  return process.env.NEXT_PUBLIC_NETWORK === 'mainnet' ? v.symbolMainnet : v.symbolTestnet;
}

/** Marketing shape: what the pages actually render. */
export const VAULTS_FOR_DISPLAY = VAULT_CLASSES.map((v) => ({
  symbol: vaultSymbol(v),
  name: v.name,
  mandate: v.mandate,
  detail: v.detail,
}));

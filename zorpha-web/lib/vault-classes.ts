import { CHAIN_ID, MAINNET_CHAIN_ID } from '@/lib/contracts';

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
    // zqNVDA, not zqAAPL. Testnet ran this class over AAPL; mainnet deployed it
    // over NVDA on 6 September 2026, because NVDA/USDG is both the deepest
    // Uniswap V3 pool on the chain and the one with the longest observation
    // history, and the price feed needs both.
    symbolMainnet: 'zqNVDA',
    name: 'Long / Flat Equity',
    mandate: 'Moves a single Stock Token between full exposure and cash.',
    // Read off the deployed vault: performanceFee() is 1000 bps, not 2000.
    // "Oracle-gated" was true of the design and is not true of the deployment:
    // there is no oracle, there is a 30-minute average of the pool the vault
    // trades in.
    detail: 'Priced from its own pool · 1% max slippage · 10% performance fee',
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
 * Which symbol to show, decided by the chain the app is pointed at.
 *
 * This used to read `NEXT_PUBLIC_NETWORK === 'mainnet'`, and that variable is
 * not set in production. So the marketing pages served the TESTNET symbol,
 * zqtAAPL, to mainnet visitors, and did it silently: there is no error state
 * for "fell back to the other branch", and the wrong symbol looks exactly as
 * confident as the right one.
 *
 * The deeper problem was two sources of truth for one fact. NEXT_PUBLIC_CHAIN_ID
 * already says which network this is, it is set, and every contract read
 * depends on it being right. NEXT_PUBLIC_NETWORK was a second copy that could
 * disagree, and did. Deriving from the chain id removes the copy.
 */
export function vaultSymbol(v: VaultClass): string {
  return CHAIN_ID === MAINNET_CHAIN_ID ? v.symbolMainnet : v.symbolTestnet;
}

/** Marketing shape: what the pages actually render. */
export const VAULTS_FOR_DISPLAY = VAULT_CLASSES.map((v) => ({
  symbol: vaultSymbol(v),
  name: v.name,
  mandate: v.mandate,
  detail: v.detail,
}));

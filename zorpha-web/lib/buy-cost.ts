/**
 * What a ZOR purchase actually costs, measured against the live pool.
 *
 * WHY THIS EXISTS SEPARATELY FROM THE WIDGET
 *
 * LI.FI quotes a route and prints how much ZOR you receive. That number is
 * correct and it is also unhelpful on its own: a buyer cannot tell whether a
 * poor rate came from the bridge, the aggregator, or the pool. On 6 September
 * the answer was overwhelmingly the pool. Bridging 100 USDC to Robinhood Chain
 * cost 44 basis points; the swap into ZOR cost 17%.
 *
 * So the page states the split. The bridge fee is the aggregator's to report;
 * this module computes the pool's share from its own reserves, which anyone can
 * verify with two balanceOf calls.
 *
 * The pool is a full-range Uniswap V3 position, which over a single swap is
 * arithmetically the same as a constant product pool: full range means the
 * liquidity is spread across every tick, so there is no concentrated band to
 * fall out of and no tick crossing to model. Concentrated positions would need
 * the tick math; this one does not, and pretending otherwise would add error
 * rather than remove it.
 */

/** Uniswap V3 fee tier on the ZOR/USDG pool, in hundredths of a basis point. */
export const POOL_FEE_PIPS = 3000n; // 0.3%
const PIPS = 1_000_000n;

export interface PoolReserves {
  /** ZOR held by the pool, 18 decimals. */
  zor: bigint;
  /** USDG held by the pool, 6 decimals. */
  usdg: bigint;
}

export interface BuyQuote {
  /** ZOR received, 18 decimals. */
  out: bigint;
  /** Spot price before the trade, USDG per ZOR, as a float for display only. */
  spot: number;
  /** Price actually paid across the whole fill, USDG per ZOR. */
  effective: number;
  /**
   * How much worse the fill is than spot, as a fraction. 0.17 means the buyer
   * pays 17% above the quoted price purely because of pool depth.
   */
  slippage: number;
}

/**
 * Quote a buy against the pool.
 *
 * Returns null rather than a misleading zero when the inputs cannot produce a
 * meaningful answer: an empty pool has no price, and a zero buy has no cost.
 * A caller that renders `0%` for an empty pool would be claiming the trade is
 * free, which is the opposite of true.
 */
export function quoteBuy(reserves: PoolReserves, usdgIn: bigint): BuyQuote | null {
  if (reserves.zor <= 0n || reserves.usdg <= 0n || usdgIn <= 0n) return null;

  // The pool fee is taken off the input before it touches the curve.
  const inAfterFee = (usdgIn * (PIPS - POOL_FEE_PIPS)) / PIPS;
  if (inAfterFee <= 0n) return null;

  // Constant product: out = x - k / (y + dy), computed without leaving bigint.
  const k = reserves.zor * reserves.usdg;
  const out = reserves.zor - k / (reserves.usdg + inAfterFee);
  if (out <= 0n) return null;

  // Prices are for display, so a float is honest here. Both sides are scaled
  // out of their token decimals first, or the ratio would be off by 1e12.
  const zorFloat = Number(reserves.zor) / 1e18;
  const usdgFloat = Number(reserves.usdg) / 1e6;
  const outFloat = Number(out) / 1e18;
  const inFloat = Number(usdgIn) / 1e6;

  const spot = usdgFloat / zorFloat;
  const effective = inFloat / outFloat;

  return { out, spot, effective, slippage: effective / spot - 1 };
}

/**
 * The quote depth at which a given buy stays within a slippage budget.
 *
 * Used to state the release condition for the buy page in concrete terms
 * rather than as a feeling. For a constant product pool the slippage on a buy
 * is approximately the buy divided by the quote reserve, so the depth needed
 * is the buy divided by the budget. Approximate on purpose: it is a threshold
 * for a human decision, not an invariant.
 *
 * @param usdBuy the buy size to protect, in whole dollars
 * @param budget acceptable slippage as a fraction, so 0.02 for 2%
 * @returns quote depth in whole dollars
 */
export function depthForSlippage(usdBuy: number, budget: number): number {
  if (usdBuy <= 0 || budget <= 0) return 0;
  return usdBuy / budget;
}

/**
 * Whether the pool is deep enough to open the buy page.
 *
 * The page is gated because a frictionless funnel into a thin pool gives every
 * buyer a bad fill, and the easier the funnel the more people it reaches. This
 * is the one place that decision is encoded, so turning the page on is a
 * measurement rather than an opinion.
 */
export const BUY_PAGE_MIN_DEPTH_USD = 5_000;

export function poolIsDeepEnough(reserves: PoolReserves): boolean {
  return Number(reserves.usdg) / 1e6 >= BUY_PAGE_MIN_DEPTH_USD;
}

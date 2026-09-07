'use client';

import { useReadContracts } from 'wagmi';
import { formatUnits } from 'viem';
import { erc20Abi } from '@/lib/contracts';
import { robinhoodMainnet } from '@/lib/chains';
import { quoteBuy, poolIsDeepEnough, BUY_PAGE_MIN_DEPTH_USD } from '@/lib/buy-cost';

/**
 * Addresses as literals, not environment variables, and deliberately so.
 *
 * lib/contracts.ts reads every address from NEXT_PUBLIC_* because those are
 * contracts the app SIGNS transactions against, and audit finding M-01 turns
 * on that discipline. These two are read only: the component calls balanceOf
 * and renders a number. Routing them through the environment would add a
 * variable that must also be set in Vercel, and an unset one would blank this
 * panel in production while the rest of the page rendered perfectly, which is
 * the failure mode this project has already been bitten by twice.
 *
 * components/tools/BridgeWidget.tsx carries the USDG address the same way.
 */
const POOL = '0x42AeA5CF1534498Db2f66F14bB9B9BeD2aB98d8d' as const;
const ZOR = '0x9684AFe2422a0B03719201c78959b6B70e8d4ae8' as const;
const USDG = '0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168' as const;

/**
 * What the pool will actually charge you, read from the pool.
 *
 * The widget above this reports one number: how much ZOR a route returns. That
 * is true and it hides the thing a buyer most needs to know, because it does
 * not say WHERE the cost came from. Bridging a hundred dollars onto Robinhood
 * Chain costs about forty basis points. The swap into ZOR, against the depth
 * this pool currently has, costs about seventeen percent. Those are different
 * problems with different fixes, and a single blended figure lets the larger
 * one hide behind the smaller.
 *
 * Both reserves are read in ONE useReadContracts call so they come from the
 * same block. Reading them separately would let a swap land between the two
 * requests and produce a price that never existed.
 */

const SIZES = [25, 100, 500, 1000] as const;

export function BuyCost() {
  const { data, isLoading } = useReadContracts({
    contracts: [
      { address: ZOR, abi: erc20Abi, functionName: 'balanceOf', args: [POOL], chainId: robinhoodMainnet.id },
      { address: USDG, abi: erc20Abi, functionName: 'balanceOf', args: [POOL], chainId: robinhoodMainnet.id },
    ],
    query: { refetchInterval: 30_000 },
  });

  if (isLoading || !data || data[0]?.status !== 'success' || data[1]?.status !== 'success') {
    return (
      <div className="card p-5" role="status">
        <p className="text-sm text-ink-400">Reading pool depth...</p>
      </div>
    );
  }

  const reserves = { zor: data[0].result as bigint, usdg: data[1].result as bigint };
  const depth = Number(formatUnits(reserves.usdg, 6));
  const deep = poolIsDeepEnough(reserves);

  const pct = (n: number) =>
    n >= 10 ? `${Math.round(n * 100)}%` : `${(n * 100).toFixed(n < 0.1 ? 1 : 0)}%`;

  return (
    <div className="card p-5">
      <div className="flex flex-wrap items-baseline justify-between gap-2">
        <h2 className="text-sm font-semibold">What the pool charges</h2>
        <span className="font-mono text-2xs text-ink-500">
          ${depth.toLocaleString(undefined, { maximumFractionDigits: 0 })} of depth, live
        </span>
      </div>

      <p className="mt-3 text-sm leading-relaxed text-ink-400">
        Read from the ZOR/USDG pool just now. This is the cost of the swap alone; the bridge onto
        Robinhood Chain adds roughly half a percent on top, and the route above shows that part.
      </p>

      <table className="mt-4 w-full text-sm">
        <thead>
          <tr className="text-left text-2xs uppercase tracking-wide text-ink-500">
            <th className="pb-2 font-medium">You spend</th>
            <th className="pb-2 text-right font-medium">You receive</th>
            <th className="pb-2 text-right font-medium">Cost vs quoted price</th>
          </tr>
        </thead>
        <tbody className="font-mono tabular-nums">
          {SIZES.map((usd) => {
            const q = quoteBuy(reserves, BigInt(usd) * 10n ** 6n);
            if (!q) return null;
            const bad = q.slippage >= 0.1;
            return (
              <tr key={usd} className="border-t border-void-700">
                <td className="py-2">${usd}</td>
                <td className="py-2 text-right">
                  {(Number(q.out) / 1e18).toLocaleString(undefined, { maximumFractionDigits: 0 })} ZOR
                </td>
                <td className={`py-2 text-right ${bad ? 'text-amber-400' : 'text-ink-300'}`}>
                  {pct(q.slippage)}
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>

      {!deep ? (
        <p className="mt-4 text-sm leading-relaxed text-amber-400">
          This pool is thin. At ${depth.toLocaleString(undefined, { maximumFractionDigits: 0 })} of
          depth a larger purchase moves the price against you substantially, and the figures above
          are what you would actually pay, not a worst case. Buying in smaller amounts costs less.
          The page opens fully once depth passes $
          {BUY_PAGE_MIN_DEPTH_USD.toLocaleString()}.
        </p>
      ) : null}
    </div>
  );
}

'use client';

import { useReadContracts } from 'wagmi';
import { formatUnits } from 'viem';
import { erc20Abi } from '@/lib/contracts';
import { robinhoodMainnet } from '@/lib/chains';
import { CountUp } from '@/components/motion/CountUp';
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
 * The widget reports one number: how much ZOR a route returns. That is true,
 * and on its own it is unhelpful, because it does not say WHERE the cost came
 * from. Bridging a hundred dollars onto Robinhood Chain costs about forty
 * basis points. The swap into ZOR, against the depth this pool currently has,
 * costs about seventeen percent. Those are different problems with different
 * fixes, and a single blended figure lets the larger one hide behind the
 * smaller.
 *
 * Both reserves are read in ONE useReadContracts call so they come from the
 * same block. Reading them separately would let a swap land between the two
 * requests and produce a price that never existed.
 *
 * This band is the second loudest thing on the page, behind the headline and
 * ahead of the widget, which is the point: a cost disclosure a reader has to
 * hunt for is a disclosure designed not to be read.
 */

const SIZES = [25, 100, 500, 1000] as const;

/** The size the lead figure is quoted at, and the row it emphasises. */
const LEAD_USD = 100;

const usdgUnits = (dollars: number) => BigInt(dollars) * 10n ** 6n;
const toWhole = (amount: bigint) => Number(amount) / 1e18;
const round = (n: number) => n.toLocaleString('en-US', { maximumFractionDigits: 0 });

/**
 * Holds the band's height while the reserves load, so the page does not jump
 * when they arrive. A spinner in a void would say nothing about what is coming.
 */
function Skeleton() {
  return (
    <div
      className="grid gap-x-16 gap-y-10 lg:grid-cols-[minmax(0,1fr),minmax(0,1.25fr)]"
      role="status"
      aria-label="Reading pool depth"
    >
      <div className="animate-pulse">
        <div className="h-3 w-28 rounded bg-void-700" />
        <div className="mt-5 h-9 w-56 rounded bg-void-800" />
        <div className="mt-4 h-3 w-full rounded bg-void-800" />
      </div>
      <div className="animate-pulse space-y-4 pt-2">
        {SIZES.map((s) => (
          <div key={s} className="h-3 w-full rounded bg-void-800" />
        ))}
      </div>
    </div>
  );
}

export function BuyCost() {
  const { data, isError, isLoading } = useReadContracts({
    contracts: [
      {
        address: ZOR,
        abi: erc20Abi,
        functionName: 'balanceOf',
        args: [POOL],
        chainId: robinhoodMainnet.id,
      },
      {
        address: USDG,
        abi: erc20Abi,
        functionName: 'balanceOf',
        args: [POOL],
        chainId: robinhoodMainnet.id,
      },
    ],
    query: { refetchInterval: 30_000 },
  });

  if (isLoading) return <Skeleton />;

  /**
   * A failed read says so rather than falling back to zeros. A table of 0%
   * would claim the trade is free, which is the opposite of true and is
   * precisely the number somebody would act on.
   */
  if (isError || !data || data[0]?.status !== 'success' || data[1]?.status !== 'success') {
    return (
      <div role="alert" className="max-w-xl">
        <p className="stat-label">Pool unreachable</p>
        <p className="mt-3 text-sm leading-relaxed text-ink-300">
          The pool did not answer, so the cost of a purchase cannot be shown right now. The route in
          the panel above still quotes a real price, and that quote already includes this cost.
          Reload to try again.
        </p>
      </div>
    );
  }

  const reserves = { zor: data[0].result as bigint, usdg: data[1].result as bigint };
  const depth = Number(formatUnits(reserves.usdg, 6));
  const deep = poolIsDeepEnough(reserves);

  /**
   * The lead figure is what a hundred dollars actually returns, net of the
   * pool fee and net of the price the order moves itself. Quoting the spot
   * rate instead would be the more flattering number, and nobody can transact
   * at it.
   */
  const lead = quoteBuy(reserves, usdgUnits(LEAD_USD));

  const pct = (n: number) => (n >= 0.1 ? Math.round(n * 100) + '%' : (n * 100).toFixed(1) + '%');

  return (
    <div className="grid gap-x-16 gap-y-10 lg:grid-cols-[minmax(0,1fr),minmax(0,1.25fr)]">
      {/* ─── The one figure worth reading twice ──────────────────────────── */}
      <div>
        <p className="stat-label flex items-center gap-2">
          <span
            className="inline-block h-1.5 w-1.5 animate-pulse-dot rounded-full bg-zor-500"
            aria-hidden="true"
          />
          Live, read from the pool
        </p>

        {lead ? (
          <>
            <p className="mt-5 font-mono text-3xl leading-none text-zor-300 sm:text-4xl">
              <CountUp to={toWhole(lead.out)} format={round} />
            </p>
            <p className="mt-4 max-w-md text-sm leading-relaxed text-ink-300">
              is what ${LEAD_USD} buys from the pool today, after its fee and after the price your
              own order moves. Getting there costs more: quotes measured on 7 September delivered
              about 5% less than this, because the route swaps once on the chain you are paying from
              before it bridges. The panel shows the real number for your own route, and it is the
              one to trust.
            </p>
          </>
        ) : null}

        <dl className="mt-8 flex flex-wrap gap-x-12 gap-y-6">
          {/*
            Not counted up, unlike the lead figure. CountUp animates from zero,
            and a depth reading its way up through numbers that were never true
            is the one kind of motion this page cannot afford: the figure is
            small enough to look static, so a reader catches it mid-flight and
            reads a wrong number as the answer. The lead figure gets away with
            it because it is visibly animating. One moving number, not three.
          */}
          <div>
            <dt className="stat-label">Pool depth</dt>
            <dd className="mt-2 font-mono text-lg text-ink-100">${round(depth)}</dd>
          </div>
          <div>
            <dt className="stat-label">Opens fully at</dt>
            <dd className="mt-2 font-mono text-lg text-ink-400">
              ${round(BUY_PAGE_MIN_DEPTH_USD)}
            </dd>
          </div>
        </dl>
      </div>

      {/* ─── And what it costs at every size ─────────────────────────────── */}
      <div>
        <div className="scroll-x">
          <table className="w-full text-sm">
            <thead>
              <tr className="text-left text-2xs uppercase tracking-[0.14em] text-ink-500">
                <th scope="col" className="pb-3 font-medium">
                  You spend
                </th>
                <th scope="col" className="pb-3 text-right font-medium">
                  You receive
                </th>
                <th scope="col" className="pb-3 text-right font-medium">
                  Cost of depth
                </th>
              </tr>
            </thead>
            <tbody>
              {SIZES.map((usd) => {
                const q = quoteBuy(reserves, usdgUnits(usd));
                if (!q) return null;
                const steep = q.slippage >= 0.1;
                /*
                  Every row the same weight, including the one the lead figure
                  quotes. Emphasising that row too would put the band's two
                  loudest elements on the same number, which is both redundant
                  and the place where the lead figure's count-up is briefly
                  visible as a disagreement rather than as a value arriving.
                */
                return (
                  <tr key={usd} className="border-t border-void-700">
                    <td className="py-3.5 font-mono text-ink-400">${usd}</td>
                    <td className="py-3.5 text-right font-mono text-ink-300">
                      {round(toWhole(q.out))}
                    </td>
                    <td
                      className={`py-3.5 text-right font-mono font-medium ${
                        steep ? 'text-amber-400' : 'text-ink-300'
                      }`}
                    >
                      {pct(q.slippage)}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>

        {!deep ? (
          <p className="mt-6 border-l-2 border-amber-500/60 pl-4 text-sm leading-relaxed text-amber-400">
            Those are the prices you get, not a worst case. At this depth a larger order moves the
            price against itself, so several small purchases cost less than one large one.
          </p>
        ) : null}
      </div>
    </div>
  );
}

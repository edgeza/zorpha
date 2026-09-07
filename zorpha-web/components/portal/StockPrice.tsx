'use client';

import { useMemo } from 'react';
import { useReadContract, useReadContracts } from 'wagmi';
import type { Address } from 'viem';
import { activeChain } from '@/lib/chains';
import { twapAdapterAbi } from '@/lib/twap-adapter-abi';
import { Mono } from '@/components/ui/Primitives';

/**
 * The price of a vault's underlying, read from the pool that vault trades in.
 *
 * WHY THE SERIES COMES FROM THE CONTRACT
 *
 * Uniswap stores a ring buffer of tick cumulatives, and turning those into a
 * price means tick maths: a 2^128 fixed-point exponentiation over twenty magic
 * constants, then a 512-bit multiply-divide to apply the decimal scaling. A
 * second copy of that in TypeScript would be the protocol's most error-prone
 * arithmetic implemented twice, and the two would diverge silently into a chart
 * that disagrees with NAV. So the adapter exposes `answersOverWindows` and this
 * draws what the vault itself would price. There is one implementation, and a
 * fork test asserts the chart and `latestRoundData` return the same number for
 * the same window.
 *
 * WHY IT KEEPS DRAWING WHEN THE VAULT WILL NOT TRADE
 *
 * `answersOverWindows` runs none of the five guards. A manager whose rebalance
 * has just been refused because spot diverged from the average is precisely the
 * person who needs to see what the price did, and a guarded view would go blank
 * at that moment. The banner below says when NAV is refusing; the chart carries
 * on regardless.
 *
 * WHERE THE HISTORY COMES FROM
 *
 * Entirely from pool state at the current block. No indexer, and no archive
 * node, which is not a preference: this chain's public RPC prunes archive state
 * within a few blocks and cannot answer a historical call at all. An
 * indexer-free chart is the only kind a browser can draw here. The horizon is
 * whatever the pool's observation buffer reaches back to, measured at 62 hours
 * when this was built, clamped to 24.
 */

const POINTS = 48;
const MAX_HORIZON_SECONDS = 24 * 60 * 60;
const REFRESH_MS = 30_000;

/**
 * Trimmed off the reported buffer depth before asking for it.
 *
 * `observe` reverts with a bare "OLD" for any secondsAgo past the ring's
 * oldest entry, and that entry can be overwritten between this read and the
 * next block on a pool that is trading. Asking for exactly the reported depth
 * is a chart that intermittently goes blank for no reason a user could guess.
 */
const HORIZON_MARGIN_SECONDS = 120;

type Series =
  | { state: 'loading' }
  | { state: 'unreadable' }
  | { state: 'too-shallow'; depthSeconds: number }
  | {
      state: 'ready';
      prices: number[];
      horizonSeconds: number;
      navRefusing: boolean;
      latest: number | null;
    };

function useStockPrice(oracle: Address | undefined): Series {
  // The buffer depth first, because `observe` reverts past the ring's reach.
  // Asking and clamping beats guessing a horizon and retrying on failure.
  const depth = useReadContract({
    abi: twapAdapterAbi,
    address: oracle,
    functionName: 'oldestObservationSecondsAgo',
    chainId: activeChain.id,
    query: { enabled: Boolean(oracle), refetchInterval: REFRESH_MS },
  });

  const horizon = useMemo(() => {
    if (depth.data === undefined) return 0;
    const usable = Math.max(0, Number(depth.data) - HORIZON_MARGIN_SECONDS);
    return Math.min(usable, MAX_HORIZON_SECONDS);
  }, [depth.data]);

  // Strictly decreasing and ending at zero, which is what the contract
  // requires. A step below one second would produce duplicate entries and be
  // rejected, hence the POINTS floor on the horizon.
  const secondsAgos = useMemo(() => {
    if (horizon < POINTS) return undefined;
    const step = Math.floor(horizon / POINTS);
    const out: number[] = [];
    for (let i = POINTS; i >= 1; i--) out.push(step * i);
    out.push(0);
    return out;
  }, [horizon]);

  const reads = useReadContracts({
    contracts: [
      {
        abi: twapAdapterAbi,
        address: oracle,
        functionName: 'answersOverWindows',
        args: secondsAgos ? [secondsAgos] : undefined,
        chainId: activeChain.id,
      },
      {
        abi: twapAdapterAbi,
        address: oracle,
        functionName: 'latestRoundData',
        chainId: activeChain.id,
      },
    ],
    query: { enabled: Boolean(oracle && secondsAgos), refetchInterval: REFRESH_MS },
  });

  if (!oracle) return { state: 'unreadable' };
  if (depth.isLoading) return { state: 'loading' };
  if (depth.isError) return { state: 'unreadable' };
  // `horizon > 0` was the condition here, and it left a hole: a buffer under
  // HORIZON_MARGIN_SECONDS clamps the horizon to exactly zero, skipped this
  // branch, fell through to `!secondsAgos` below and rendered a loading
  // skeleton that never resolved. A fresh pool, or one at cardinality 1 like
  // ZOR/USDG today, would have pulsed forever instead of saying why.
  if (depth.data !== undefined && horizon < POINTS) {
    return { state: 'too-shallow', depthSeconds: Number(depth.data) };
  }
  if (!secondsAgos || reads.isLoading) return { state: 'loading' };
  if (reads.isError) return { state: 'unreadable' };

  const [seriesRead, navRead] = reads.data ?? [];
  if (seriesRead?.status !== 'success') return { state: 'unreadable' };

  const prices = (seriesRead.result as readonly bigint[]).map((v) => Number(v) / 1e8);
  if (prices.length === 0 || prices.some((p) => !Number.isFinite(p) || p <= 0)) {
    return { state: 'unreadable' };
  }

  // A reverting `latestRoundData` is INFORMATION here, not an error: it means
  // one of the five guards is refusing, so the vault cannot rebalance right
  // now. Worth saying out loud rather than swallowing.
  const navRefusing = navRead?.status !== 'success';
  const latest =
    navRead?.status === 'success'
      ? Number((navRead.result as readonly [bigint, bigint, bigint, bigint, bigint])[1]) / 1e8
      : null;

  return { state: 'ready', prices, horizonSeconds: horizon, navRefusing, latest };
}

function describeHorizon(seconds: number): string {
  if (seconds < 7200) return `${Math.round(seconds / 60)} minutes`;
  return `${Math.round(seconds / 3600)} hours`;
}

/**
 * A sparkline. No chart library: it is one polyline over a normalised range,
 * which is the whole of what this needs and avoids shipping a charting bundle
 * to draw 48 points.
 */
function Spark({ prices }: { prices: number[] }) {
  const width = 640;
  const height = 128;
  const min = Math.min(...prices);
  const max = Math.max(...prices);
  // A flat series has zero span. Without this the whole line divides by zero
  // and vanishes, which is exactly what a quiet market produces.
  const span = max - min || 1;

  const points = prices
    .map((p, i) => {
      const x = (i / (prices.length - 1 || 1)) * width;
      const y = height - ((p - min) / span) * height;
      return `${x.toFixed(1)},${y.toFixed(1)}`;
    })
    .join(' ');

  const first = prices[0];
  const last = prices[prices.length - 1];
  const rising = last >= first;

  return (
    <svg
      viewBox={`0 0 ${width} ${height}`}
      className="mt-4 h-32 w-full overflow-visible"
      role="img"
      aria-label={`Price across the charted window, from ${first.toFixed(2)} to ${last.toFixed(2)}`}
      preserveAspectRatio="none"
    >
      <polyline
        points={points}
        fill="none"
        strokeWidth={2}
        strokeLinejoin="round"
        vectorEffect="non-scaling-stroke"
        className={rising ? 'stroke-verified-400' : 'stroke-ink-400'}
      />
    </svg>
  );
}

export function StockPrice({
  oracleAddress,
  symbol,
}: {
  oracleAddress: Address | undefined;
  symbol: string;
}) {
  const s = useStockPrice(oracleAddress);
  const label = symbol ? `${symbol} price` : 'Underlying price';

  return (
    <div className="card-pad">
      <div className="flex items-baseline justify-between gap-3">
        <div className="stat-label">{label}</div>
        {s.state === 'ready' && s.latest !== null ? (
          <span className="font-mono text-2xl tabular-nums">
            {s.latest.toLocaleString('en-US', {
              style: 'currency',
              currency: 'USD',
              maximumFractionDigits: 2,
            })}
          </span>
        ) : null}
      </div>

      {s.state === 'loading' ? (
        <div
          className="mt-4 h-32 w-full animate-pulse rounded bg-void-700"
          role="status"
          aria-label="Reading the pool's price history"
        />
      ) : null}

      {s.state === 'unreadable' ? (
        <>
          <div className="stat-value mt-2 text-ink-500">&mdash;</div>
          <p className="mt-2 text-xs leading-relaxed text-ink-400">
            This vault&rsquo;s price feed did not answer. The figure is unavailable rather than
            zero, and those are different things.
          </p>
        </>
      ) : null}

      {s.state === 'too-shallow' ? (
        <>
          <div className="stat-value mt-2 text-ink-500">&mdash;</div>
          <p className="mt-2 text-xs leading-relaxed text-ink-400">
            The pool&rsquo;s observation history reaches back only{' '}
            {s.depthSeconds < 120 ? `${s.depthSeconds} seconds` : describeHorizon(s.depthSeconds)},
            which is not enough to plot. It deepens as the pool trades.
          </p>
        </>
      ) : null}

      {s.state === 'ready' ? (
        <>
          <Spark prices={s.prices} />
          <p className="mt-3 text-xs leading-relaxed text-ink-400">
            The last {describeHorizon(s.horizonSeconds)}, read from the Uniswap pool&rsquo;s own
            observation history at the current block. Each point is a time-weighted average over
            its interval, computed by the same contract that prices this vault &mdash; not by this
            page, and not from an index.
          </p>
          {s.navRefusing ? (
            <p className="mt-3 text-xs leading-relaxed text-amber-400">
              The vault will not rebalance right now: one of the price feed&rsquo;s guards is
              refusing, most often because spot has moved more than 2% away from the 30-minute
              average. The chart above still reads, because <Mono>answersOverWindows</Mono> runs
              none of those checks. Signing a rebalance in this state only spends gas.
            </p>
          ) : null}
        </>
      ) : null}
    </div>
  );
}

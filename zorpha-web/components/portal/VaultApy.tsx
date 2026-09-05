'use client';

import { useReadContract, useReadContracts } from 'wagmi';
import {
  vaultAbi,
  yieldAdapterAbi,
  morphoVaultV2Abi,
  multicall3TimestampAbi,
  MULTICALL3_ADDRESS,
} from '@/lib/contracts';
import { apyFromAccrual, formatApy, type VaultApy } from '@/lib/apy';
import { bpsToPct } from '@/lib/format';

/**
 * The live yield on a vault, measured from chain state on every render.
 *
 * There is no APY anywhere in this codebase that is typed in by hand, and there
 * should not be: a rate committed to the repo is stale the next day, and this
 * is the single number a depositor decides on. Everything below is derived from
 * contract reads, so the page cannot claim a rate the chain is not paying.
 *
 * The measurement walks three hops, because a Zorpha vault does not earn
 * anything itself -- it routes capital to a venue that does:
 *
 *     vault.adapter()  ->  adapter.target()  ->  the venue's accrual state
 *
 * The venue's rate then comes from its own pending interest: the gap between
 * what it has booked and what it would book right now, over the seconds
 * between. See lib/apy.ts for why that method is used instead of comparing
 * share prices across two blocks (the public RPCs for this chain prune archive
 * state and time out on full-range log queries, so historical share prices are
 * simply not readable from the browser).
 */

/** How often to re-measure. The venue accrues continuously; this is cosmetic. */
const REFRESH_MS = 15_000;

type Measurement =
  | { state: 'not-a-yield-vault' }
  | { state: 'loading' }
  | { state: 'unmeasurable' }
  | { state: 'ready'; apy: VaultApy; feeBps: number; elapsedSeconds: bigint };

function useVaultApy(vaultAddress: `0x${string}`): Measurement {
  // Hop 1. Both are immutable on the vault, so they are read together and
  // never refetched. `adapter` reverting is meaningful rather than an error:
  // the spot and rotation vaults have no adapter, and that is how this
  // component knows it has nothing to say about them.
  const vault = useReadContracts({
    contracts: [
      { abi: vaultAbi, address: vaultAddress, functionName: 'adapter' },
      { abi: vaultAbi, address: vaultAddress, functionName: 'performanceFee' },
    ],
  });

  const adapterRead = vault.data?.[0];
  const feeRead = vault.data?.[1];
  const adapter =
    adapterRead?.status === 'success' ? (adapterRead.result as `0x${string}`) : undefined;

  // Hop 2.
  const { data: target } = useReadContract({
    abi: yieldAdapterAbi,
    address: adapter,
    functionName: 'target',
    query: { enabled: Boolean(adapter) },
  });

  // Hop 3. These four MUST stay in one `useReadContracts` call: viem batches a
  // group into a single multicall, which is what makes the timestamp and the
  // balances describe the same block. Split them and the elapsed time is
  // measured against a different block than the interest, which at ~0.15s
  // blocks overstates the rate on short windows.
  const accrual = useReadContracts({
    contracts: [
      { abi: morphoVaultV2Abi, address: target, functionName: '_totalAssets' },
      { abi: morphoVaultV2Abi, address: target, functionName: 'lastUpdate' },
      { abi: morphoVaultV2Abi, address: target, functionName: 'accrueInterestView' },
      {
        abi: multicall3TimestampAbi,
        address: MULTICALL3_ADDRESS,
        functionName: 'getCurrentBlockTimestamp',
      },
    ],
    query: { enabled: Boolean(target), refetchInterval: REFRESH_MS },
  });

  if (vault.isLoading) return { state: 'loading' };
  // A reverting `adapter` arrives as a per-call failure, not an error, because
  // `allowFailure` defaults on. So `isError` here means the request itself did
  // not land -- RPC down, rate limited, offline. Saying so beats a skeleton
  // that pulses forever, which is what this did before.
  if (vault.isError || accrual.isError) return { state: 'unmeasurable' };
  if (adapterRead && adapterRead.status !== 'success') return { state: 'not-a-yield-vault' };
  if (!adapter || !target || accrual.isLoading) return { state: 'loading' };

  const [stored, last, accrued, now] = accrual.data ?? [];
  if (
    stored?.status !== 'success' ||
    last?.status !== 'success' ||
    accrued?.status !== 'success' ||
    now?.status !== 'success' ||
    feeRead?.status !== 'success'
  ) {
    // A venue that is not a Morpho V2 vault reverts on all three accrual
    // reads. There is no way to quote its rate from the browser, and inventing
    // one is worse than admitting it.
    return { state: 'unmeasurable' };
  }

  const feeBps = Number(feeRead.result as bigint);
  const nowTs = now.result as bigint;
  const lastTs = last.result as bigint;

  const apy = apyFromAccrual(
    {
      storedAssets: stored.result as bigint,
      // accrueInterestView returns (newTotalAssets, perfFeeShares, mgmtFeeShares).
      accruedAssets: (accrued.result as readonly bigint[])[0],
      lastUpdate: lastTs,
      now: nowTs,
    },
    feeBps
  );

  // Null here is usually transient: the venue accrued in this very block, so
  // no time has passed to measure across yet. The next poll fixes it.
  if (!apy) return { state: 'unmeasurable' };

  return { state: 'ready', apy, feeBps, elapsedSeconds: nowTs - lastTs };
}

/** How long a window the quoted rate was measured over, in words. */
function describeWindow(seconds: bigint): string {
  if (seconds < 120n) return `${seconds}s`;
  if (seconds < 7200n) return `${seconds / 60n}m`;
  return `${seconds / 3600n}h`;
}

/**
 * The full panel, for a vault's own page. Renders nothing at all for a vault
 * that has no yield venue behind it, rather than an empty card.
 */
export function VaultApyPanel({ vaultAddress }: { vaultAddress: `0x${string}` }) {
  const m = useVaultApy(vaultAddress);
  if (m.state === 'not-a-yield-vault') return null;

  return (
    <div className="card-pad">
      <div className="flex items-baseline justify-between gap-3">
        <div className="stat-label">Net yield</div>
        {m.state === 'ready' ? (
          <span className="flex items-center gap-1.5 text-2xs text-ink-500">
            <span
              className="h-1.5 w-1.5 rounded-full bg-verified-400 motion-safe:animate-pulse"
              aria-hidden="true"
            />
            Live
          </span>
        ) : null}
      </div>

      {m.state === 'ready' ? (
        <>
          <div className="stat-value mt-2 text-verified-400">{formatApy(m.apy.net)}</div>
          <p className="mt-2 text-xs leading-relaxed text-ink-400">
            Annualised, after the {bpsToPct(m.feeBps)} performance fee. Measured from the
            venue&rsquo;s own interest accrual, not a published figure.
          </p>
          <dl className="mt-4 divide-hair border-t border-void-700 pt-4 text-xs">
            <div className="flex items-baseline justify-between py-1.5">
              <dt className="text-ink-500">Venue rate</dt>
              <dd className="font-mono text-ink-300">{formatApy(m.apy.gross)}</dd>
            </div>
            <div className="flex items-baseline justify-between py-1.5">
              <dt className="text-ink-500">Performance fee</dt>
              <dd className="font-mono text-ink-300">{bpsToPct(m.feeBps)} of gains</dd>
            </div>
            <div className="flex items-baseline justify-between py-1.5">
              <dt className="text-ink-500">Measured over</dt>
              <dd className="font-mono text-ink-300">{describeWindow(m.elapsedSeconds)}</dd>
            </div>
          </dl>
        </>
      ) : null}

      {m.state === 'loading' ? (
        <div
          className="mt-2 h-8 w-28 animate-pulse rounded bg-void-700"
          role="status"
          aria-label="Measuring yield"
        />
      ) : null}

      {m.state === 'unmeasurable' ? (
        <>
          <div className="stat-value mt-2 text-ink-500">&mdash;</div>
          <p className="mt-2 text-xs leading-relaxed text-ink-400">
            No rate to quote yet. This vault&rsquo;s venue has not accrued interest across a
            measurable window, or does not expose one this page can read. Nothing is being
            estimated in the meantime.
          </p>
        </>
      ) : null}
    </div>
  );
}

/**
 * The one-line version, for a card in a list. Renders nothing until there is a
 * real number -- a list is the wrong place to explain an absence, and a row of
 * "&mdash;" placeholders reads as a broken page rather than an honest one.
 */
export function VaultApyInline({ vaultAddress }: { vaultAddress: `0x${string}` }) {
  const m = useVaultApy(vaultAddress);
  if (m.state !== 'ready') return null;
  return (
    <span className="font-mono text-2xs text-verified-400">{formatApy(m.apy.net)} APY</span>
  );
}

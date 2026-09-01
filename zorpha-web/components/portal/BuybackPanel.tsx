'use client';

import { useReadContract } from 'wagmi';
import { contracts, buybackAbi, isDeployed, explorerAddress } from '@/lib/contracts';
import { formatUnits, formatCompactUnits, formatAddress } from '@/lib/format';
import { TOKEN } from '@/lib/tokenomics';

/**
 * Buyback ledger.
 *
 * Both figures come from cumulative counters the contract increments from
 * measured balance deltas, not from summing event parameters. The previous
 * buyback implementation emitted a `usdcSpent` equal to its whole balance while
 * performing no swap at all, so a dashboard built on the event log would have
 * shown large and entirely fictional buyback volume.
 */
export function BuybackPanel() {
  const deployed = isDeployed('buyback');

  const { data: usdcSpent } = useReadContract({
    abi: buybackAbi,
    address: contracts.buyback,
    functionName: 'totalUsdcSpent',
    query: { enabled: deployed },
  });

  const { data: zorBurned } = useReadContract({
    abi: buybackAbi,
    address: contracts.buyback,
    functionName: 'totalZorBurned',
    query: { enabled: deployed },
  });

  const { data: threshold } = useReadContract({
    abi: buybackAbi,
    address: contracts.buyback,
    functionName: 'minBuybackThreshold',
    query: { enabled: deployed },
  });

  return (
    <div className="card-pad">
      <div className="flex items-start justify-between gap-4">
        <div>
          <div className="stat-label">Buyback and burn</div>
          <p className="mt-2 max-w-md text-xs leading-relaxed text-ink-400">
            Half of every performance fee is used to buy {TOKEN.ticker} on the open market and burn
            it. Anyone can trigger a buyback once the threshold is met.
          </p>
        </div>
        {deployed ? (
          <a
            href={explorerAddress(contracts.buyback)}
            target="_blank"
            rel="noreferrer noopener"
            className="badge shrink-0 font-mono hover:border-zor-600/70"
          >
            {formatAddress(contracts.buyback)} ↗
          </a>
        ) : null}
      </div>

      {!deployed ? (
        <p className="mt-5 border-t border-void-700 pt-5 text-sm text-ink-400">
          The buyback contract address is not configured in this environment.
        </p>
      ) : (
        <dl className="mt-5 grid grid-cols-2 gap-4 border-t border-void-700 pt-5 sm:grid-cols-3">
          <div>
            <dt className="stat-label">USDC spent</dt>
            <dd className="mt-1.5 font-mono text-sm text-ink-200">
              {usdcSpent === undefined ? '—' : `$${formatUnits(usdcSpent as bigint, 6, 2)}`}
            </dd>
          </div>
          <div>
            <dt className="stat-label">{TOKEN.ticker} burned</dt>
            <dd className="mt-1.5 font-mono text-sm text-verified-400">
              {formatCompactUnits(zorBurned as bigint | undefined)}
            </dd>
          </div>
          <div>
            <dt className="stat-label">Trigger threshold</dt>
            <dd className="mt-1.5 font-mono text-sm text-ink-200">
              {threshold === undefined ? '—' : `$${formatUnits(threshold as bigint, 6, 0)}`}
            </dd>
          </div>
        </dl>
      )}
    </div>
  );
}

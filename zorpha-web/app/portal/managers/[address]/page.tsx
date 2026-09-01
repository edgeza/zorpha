import Link from 'next/link';
import { notFound } from 'next/navigation';
import type { Metadata } from 'next';
import { getManager, listRebalancesForManager, listReputationForManager } from '@/lib/queries';
import { ReceiptCard } from '@/components/portal/ReceiptCard';
import { EmptyState, Stat } from '@/components/ui/Primitives';
import { explorerAddress, explorerTx } from '@/lib/contracts';
import { formatAddress, formatDate, formatRelative } from '@/lib/format';

export const revalidate = 30;

export async function generateMetadata({
  params,
}: {
  params: Promise<{ address: string }>;
}): Promise<Metadata> {
  const { address } = await params;
  return { title: `Manager ${formatAddress(address)}` };
}

export default async function ManagerPage({
  params,
}: {
  params: Promise<{ address: string }>;
}) {
  const { address } = await params;
  if (!/^0x[0-9a-fA-F]{40}$/.test(address)) notFound();

  const [manager, receipts, reputation] = await Promise.all([
    getManager(address),
    listRebalancesForManager(address, 100),
    listReputationForManager(address),
  ]);

  const firstSeen = manager?.first_seen_at ?? receipts.at(-1)?.block_timestamp;

  return (
    <div className="flex flex-col gap-8">
      <nav aria-label="Breadcrumb" className="text-xs text-ink-500">
        <Link href="/portal/leaderboard" className="hover:text-ink-300">
          Managers
        </Link>
        <span className="mx-2" aria-hidden="true">
          /
        </span>
        <span className="font-mono text-ink-300">{formatAddress(address)}</span>
      </nav>

      <header className="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <div className="stat-label">Manager</div>
          <h1 className="mt-2 font-mono text-xl font-semibold tracking-tight sm:text-2xl">
            {manager?.label ?? formatAddress(address, 8, 6)}
          </h1>
          <p className="mt-3 max-w-2xl text-sm leading-relaxed text-ink-400">
            The complete signed history for this key. Nothing on this page is curated or
            filtered — a bad rebalance appears exactly like a good one.
          </p>
        </div>
        <a
          href={explorerAddress(address)}
          target="_blank"
          rel="noreferrer noopener"
          className="badge shrink-0 font-mono hover:border-zor-600/70"
        >
          {formatAddress(address)} ↗
        </a>
      </header>

      <section className="grid grid-cols-2 gap-5 sm:grid-cols-3">
        <Stat label="Signed receipts" value={receipts.length.toLocaleString('en-US')} />
        <Stat label="First seen" value={firstSeen ? formatDate(firstSeen) : '—'} />
        <Stat
          label="Last active"
          value={
            manager?.last_active_at
              ? formatRelative(manager.last_active_at)
              : receipts[0]
                ? formatRelative(receipts[0].block_timestamp)
                : '—'
          }
        />
      </section>

      {reputation.length > 0 ? (
        <section>
          <h2 className="mb-4 text-lg font-semibold">Published stats commitments</h2>
          <div className="card scroll-x overflow-hidden">
            <table className="w-full min-w-[36rem] text-sm">
              <thead>
                <tr className="border-b border-void-700 bg-void-850 text-left">
                  {['Window', 'Commitment', 'Status', 'Tx'].map((h) => (
                    <th
                      key={h}
                      scope="col"
                      className="px-4 py-3 text-2xs font-medium uppercase tracking-[0.12em] text-ink-500"
                    >
                      {h}
                    </th>
                  ))}
                </tr>
              </thead>
              <tbody className="divide-y divide-void-700">
                {reputation.map((row) => (
                  <tr key={row.id}>
                    <td className="px-4 py-3 font-mono text-xs text-ink-300">
                      {formatDate(row.window_start)} → {formatDate(row.window_end)}
                    </td>
                    <td className="px-4 py-3 font-mono text-xs text-ink-400">
                      {formatAddress(row.commitment, 8, 6)}
                    </td>
                    <td className="px-4 py-3">
                      {row.challenged ? (
                        row.upheld ? (
                          <span className="badge-verified">Upheld</span>
                        ) : (
                          <span className="badge-danger">Overturned</span>
                        )
                      ) : (
                        <span className="badge">Unchallenged</span>
                      )}
                    </td>
                    <td className="px-4 py-3">
                      <a
                        href={explorerTx(row.tx_hash)}
                        target="_blank"
                        rel="noreferrer noopener"
                        className="font-mono text-2xs text-ink-400 hover:text-zor-300"
                      >
                        view ↗
                      </a>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </section>
      ) : null}

      <section>
        <h2 className="mb-4 text-lg font-semibold">Full receipt history</h2>
        {receipts.length === 0 ? (
          <EmptyState
            title="No receipts for this address"
            body="This key has not signed a rebalance that the indexer has seen."
          />
        ) : (
          <div className="grid gap-4 lg:grid-cols-2">
            {receipts.map((row) => (
              <ReceiptCard key={row.id} row={row} />
            ))}
          </div>
        )}
      </section>
    </div>
  );
}

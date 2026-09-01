import Link from 'next/link';
import { listVaults, listLatestRebalances, listManagers } from '@/lib/queries';
import { TokenPanel } from '@/components/portal/TokenPanel';
import { BuybackPanel } from '@/components/portal/BuybackPanel';
import { ReceiptCard } from '@/components/portal/ReceiptCard';
import { EmptyState, Stat } from '@/components/ui/Primitives';

export const revalidate = 30;

export default async function PortalDashboard() {
  const [vaults, receipts, managers] = await Promise.all([
    listVaults(),
    listLatestRebalances(6),
    listManagers(),
  ]);

  return (
    <div className="flex flex-col gap-8">
      <header>
        <h1 className="text-2xl font-semibold tracking-tight sm:text-3xl">Dashboard</h1>
        <p className="mt-2 max-w-2xl text-sm leading-relaxed text-ink-400">
          Everything here is read from contracts or from the indexer that follows them. No figure
          on this page is hand-maintained.
        </p>
      </header>

      <section className="grid gap-5 lg:grid-cols-2">
        <TokenPanel />
        <BuybackPanel />
      </section>

      <section className="grid grid-cols-2 gap-5 sm:grid-cols-4">
        <Stat label="Vaults live" value={vaults.length} />
        <Stat label="Managers" value={managers.length} />
        <Stat
          label="Receipts indexed"
          value={managers.reduce((sum, m) => sum + m.total_rebalances, 0).toLocaleString('en-US')}
        />
        <Stat label="Network" value="Testnet" tone="warn" size="md" sub="Mainnet is not deployed" />
      </section>

      <section>
        <div className="mb-4 flex items-baseline justify-between gap-4">
          <h2 className="text-lg font-semibold">Latest receipts</h2>
          <Link href="/portal/receipts" className="link-quiet text-xs">
            View all
          </Link>
        </div>

        {receipts.length === 0 ? (
          <EmptyState
            title="No receipts yet"
            body="Once a manager signs their first rebalance, it appears here within a block. If the indexer is not running, this stays empty rather than showing placeholder data."
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

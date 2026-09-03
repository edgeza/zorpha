import type { Metadata } from 'next';
import { listLatestRebalances } from '@/lib/queries';
import { ReceiptCard } from '@/components/portal/ReceiptCard';
import Link from 'next/link';
import { EmptyState } from '@/components/ui/Primitives';

export const metadata: Metadata = { title: 'Receipts' };
export const revalidate = 20;

export default async function ReceiptsPage() {
  const receipts = await listLatestRebalances(100);

  return (
    <div className="flex flex-col gap-8">
      <header>
        <h1 className="text-2xl font-semibold tracking-tight sm:text-3xl">Receipts</h1>
        <p className="mt-3 max-w-2xl text-sm leading-relaxed text-ink-400">
          Every rebalance any manager has signed, newest first. Each one is an event emitted by the
          vault contract, so this list exists independently of this website. You can rebuild it
          from the chain yourself.
        </p>
      </header>

      {receipts.length === 0 ? (
        <EmptyState
          title="No rebalance has been signed yet"
          body="Every vault reports rebalanceCount 0 on chain, so this is the protocol's real state rather than a gap in the index. The first manager instruction ever signed will appear here, and it cannot be edited or removed afterwards."
          action={
            <Link href="/portal/manage" className="btn-primary btn-sm">
              Open the terminal
            </Link>
          }
        />
      ) : (
        <div className="grid gap-4 lg:grid-cols-2">
          {receipts.map((row) => (
            <ReceiptCard key={row.id} row={row} />
          ))}
        </div>
      )}
    </div>
  );
}

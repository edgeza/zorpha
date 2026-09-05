import type { Metadata } from 'next';
import Link from 'next/link';
import { listVaults, listLatestRebalances, listManagers } from '@/lib/queries';
import { TokenPanel } from '@/components/portal/TokenPanel';
import { BuybackPanel } from '@/components/portal/BuybackPanel';
import { ReceiptCard } from '@/components/portal/ReceiptCard';
import { EmptyState, Stat } from '@/components/ui/Primitives';
import { isMainnet } from '@/lib/chains';

// The page's own title. Without one it fell through to the root default and
// the dashboard rendered in the browser tab as the site tagline, while every
// other portal page carried its own name.
export const metadata: Metadata = { title: 'Dashboard' };

export const revalidate = 30;

export default async function PortalDashboard() {
  const [vaults, receipts, managers] = await Promise.all([
    listVaults(),
    listLatestRebalances(6),
    listManagers(),
  ]);

  const totalRebalances = managers.reduce((sum, m) => sum + m.total_rebalances, 0);

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

      {/*
        A zero next to a label reads as a broken feed unless something says
        otherwise. "Vaults live 3 / Managers 0 / Receipts indexed 0" is the
        protocol's true state -- three vaults deployed, nobody deposited,
        nothing rebalanced -- but presented bare it looks like an indexer that
        fell over, which is exactly the wrong conclusion. Each zero now carries
        the condition that would change it.
      */}
      <section className="grid grid-cols-2 gap-5 sm:grid-cols-4">
        <Stat label="Vaults live" value={vaults.length} sub="Deployed and verified" />
        <Stat
          label="Managers"
          value={managers.length}
          sub={managers.length === 0 ? 'Counted from signed rebalances' : undefined}
        />
        <Stat
          label="Receipts indexed"
          value={totalRebalances.toLocaleString('en-US')}
          sub={totalRebalances === 0 ? 'None signed yet' : undefined}
        />
        {/* Derived, not asserted. This tile said "Testnet / Mainnet is not
            deployed" as a literal, which is true today and becomes a false
            statement on the launch day it most needs to be right -- printed on
            the portal landing page, in a warning tone. */}
        <Stat
          label="Network"
          value={isMainnet ? 'Mainnet' : 'Testnet'}
          tone={isMainnet ? 'verified' : 'warn'}
          size="md"
          sub={isMainnet ? undefined : 'Mainnet is not deployed'}
        />
      </section>

      {totalRebalances === 0 && (
        <div className="card flex flex-col gap-3 p-5 sm:flex-row sm:items-center sm:justify-between">
          <div>
            <h2 className="text-sm font-semibold">Where this stands</h2>
            <p className="mt-1 max-w-prose text-sm leading-relaxed text-ink-400">
              The contracts are live and the vaults are open, but nothing has been deposited and
              no manager has signed a rebalance, so the record below is genuinely empty rather
              than unavailable. The first instruction anyone signs starts it.
            </p>
          </div>
          <Link href="/portal/manage" className="btn-primary btn-sm shrink-0 self-start sm:self-auto">
            Open the terminal
          </Link>
        </div>
      )}

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
            body="Once a manager signs their first rebalance it appears here within a block. Nothing is placeholdered while this is empty."
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
      </section>
    </div>
  );
}

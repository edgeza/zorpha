import Link from 'next/link';
import { notFound } from 'next/navigation';
import type { Metadata } from 'next';
import { getVault, listRebalancesForVault } from '@/lib/queries';
import { ReceiptCard } from '@/components/portal/ReceiptCard';
import { VaultActions } from '@/components/portal/VaultActions';
import { VaultApyPanel } from '@/components/portal/VaultApy';
import { EmptyState, SpecRow } from '@/components/ui/Primitives';
import { explorerAddress } from '@/lib/contracts';
import { formatAddress, formatDate } from '@/lib/format';

export const revalidate = 30;

export async function generateMetadata({
  params,
}: {
  params: Promise<{ id: string }>;
}): Promise<Metadata> {
  const { id } = await params;
  const vault = await getVault(id);
  return { title: vault?.name ?? 'Vault' };
}

export default async function VaultDetailPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  if (!/^0x[0-9a-fA-F]{40}$/.test(id)) notFound();

  const vault = await getVault(id);
  if (!vault) notFound();

  const receipts = await listRebalancesForVault(id, 50);
  const asset = vault.base_asset ?? vault.cash ?? vault.asset;

  return (
    <div className="flex flex-col gap-8">
      <nav aria-label="Breadcrumb" className="text-xs text-ink-500">
        <Link href="/portal/vaults" className="hover:text-ink-300">
          Vaults
        </Link>
        <span className="mx-2" aria-hidden="true">
          /
        </span>
        <span className="text-ink-300">{vault.symbol}</span>
      </nav>

      {/*
        Unlisted vaults stay reachable by address on purpose -- the contract
        exists on chain whether or not the index advertises it, and hiding it
        from the storefront should not mean pretending it is not there.
        Somebody arriving from a stale link does need to know it is not a
        product, though, which is what this says.
      */}
      {vault.listed === false && (
        <div
          role="note"
          className="rounded-md border border-amber-500/40 bg-amber-500/10 px-4 py-3 text-sm text-amber-200"
        >
          <strong className="font-semibold">Not a listed vault.</strong>{' '}
          This contract was deployed for testing or as a protocol drill. It is
          shown because the address resolves on chain, not because it is
          offered as a product. Do not deposit into it.
        </div>
      )}

      <header className="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <div className="stat-label">{vault.vault_type} vault</div>
          <h1 className="mt-2 text-2xl font-semibold tracking-tight sm:text-3xl">{vault.name}</h1>
          <p className="mt-3 max-w-2xl text-sm leading-relaxed text-ink-400">{vault.strategy}</p>
        </div>
        <a
          href={explorerAddress(vault.address)}
          target="_blank"
          rel="noreferrer noopener"
          className="badge shrink-0 font-mono hover:border-zor-600/70"
        >
          {formatAddress(vault.address)} ↗
        </a>
      </header>

      <div className="grid gap-6 lg:grid-cols-3">
        <div className="lg:col-span-2">
          <div className="card-pad">
            <h2 className="text-sm font-semibold text-ink-100">Vault specification</h2>
            <dl className="mt-3 divide-hair">
              <SpecRow label="Share token">
                <span className="font-mono">{vault.symbol}</span>
              </SpecRow>
              <SpecRow label="Underlying">
                <a
                  href={explorerAddress(vault.asset)}
                  target="_blank"
                  rel="noreferrer noopener"
                  className="link-quiet font-mono"
                >
                  {formatAddress(vault.asset)}
                </a>
              </SpecRow>
              {vault.cash ? (
                <SpecRow label="Cash asset">
                  <span className="font-mono">{formatAddress(vault.cash)}</span>
                </SpecRow>
              ) : null}
              {vault.oracle ? (
                <SpecRow label="Price oracle">
                  <a
                    href={explorerAddress(vault.oracle)}
                    target="_blank"
                    rel="noreferrer noopener"
                    className="link-quiet font-mono"
                  >
                    {formatAddress(vault.oracle)}
                  </a>
                </SpecRow>
              ) : null}
              <SpecRow label="Manager">
                <Link
                  href={`/portal/managers/${vault.manager_address}`}
                  className="link-quiet font-mono"
                >
                  {formatAddress(vault.manager_address)}
                </Link>
              </SpecRow>
              <SpecRow label="Deployed">{formatDate(vault.deployed_at)}</SpecRow>
            </dl>
          </div>
        </div>

        <div className="flex flex-col gap-6">
          {/* The rate sits above the deposit box because it is the thing being
              decided on. It reads live from the venue rather than from any
              figure stored here -- see components/portal/VaultApy.tsx. */}
          <VaultApyPanel vaultAddress={vault.address} />

          {/* No assetSymbol or assetDecimals: VaultActions reads both from the
              token. This used to pass
              `assetSymbol={vault.vault_type === 'yield' ? 'USDC' : 'USDC'}` --
              a ternary whose branches were identical, so every vault was
              labelled USDC including the two that hold an 18-decimal equity
              token. */}
          <VaultActions vaultAddress={vault.address} assetAddress={asset} />
        </div>
      </div>

      <section>
        <h2 className="mb-4 text-lg font-semibold">
          Receipts{' '}
          <span className="font-mono text-sm font-normal text-ink-500">({receipts.length})</span>
        </h2>
        {receipts.length === 0 ? (
          <EmptyState
            title="No rebalances yet"
            body="This vault has not been rebalanced. When it is, the instruction and its result appear here permanently."
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

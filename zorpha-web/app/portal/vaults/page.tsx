import Link from 'next/link';
import type { Metadata } from 'next';
import { listVaults } from '@/lib/queries';
import { EmptyState, Callout } from '@/components/ui/Primitives';
import { VAULT_DEPOSITS_ENABLED } from '@/lib/contracts';
import { formatAddress, formatDate } from '@/lib/format';

export const metadata: Metadata = { title: 'Vaults' };
export const revalidate = 60;

export default async function VaultsPage() {
  const vaults = await listVaults();

  return (
    <div className="flex flex-col gap-8">
      <header>
        <h1 className="text-2xl font-semibold tracking-tight sm:text-3xl">Vaults</h1>
        <p className="mt-3 max-w-2xl text-sm leading-relaxed text-ink-400">
          Each vault is an ERC-4626 contract with a fixed mandate. Managers can request rebalances
          within the vault&rsquo;s limits; they cannot withdraw your funds, change the mandate, or
          raise the fee.
        </p>
      </header>

      {!VAULT_DEPOSITS_ENABLED ? (
        <Callout tone="warn" title="Deposits are paused for this deployment">
          <p>
            This is a manual kill switch rather than a known defect. The vault-layer audit findings
            are closed and the contract suite is green. Everything below still reads live from the
            contracts.
          </p>
        </Callout>
      ) : null}

      {vaults.length === 0 ? (
        <EmptyState
          title="No vaults indexed"
          body="Vaults appear here once the deploy pipeline has run and the indexer has picked up the factory events."
        />
      ) : (
        <div className="grid gap-5 md:grid-cols-2 xl:grid-cols-3">
          {vaults.map((vault) => (
            <Link
              key={vault.address}
              href={`/portal/vaults/${vault.address}`}
              className="card-pad card-hover flex flex-col"
            >
              <div className="flex items-start justify-between gap-3">
                <div>
                  <div className="stat-label">{vault.vault_type}</div>
                  <h2 className="mt-1.5 text-base font-semibold text-ink-100">{vault.name}</h2>
                </div>
                <span className="badge shrink-0 font-mono">{vault.symbol}</span>
              </div>

              <p className="mt-3 flex-1 text-sm leading-relaxed text-ink-400">{vault.strategy}</p>

              <dl className="mt-4 grid grid-cols-2 gap-3 border-t border-void-700 pt-4">
                <div>
                  <dt className="stat-label">Manager</dt>
                  <dd className="mt-1 font-mono text-2xs text-ink-300">
                    {formatAddress(vault.manager_address)}
                  </dd>
                </div>
                <div>
                  <dt className="stat-label">Deployed</dt>
                  <dd className="mt-1 font-mono text-2xs text-ink-300">
                    {formatDate(vault.deployed_at)}
                  </dd>
                </div>
              </dl>
            </Link>
          ))}
        </div>
      )}
    </div>
  );
}

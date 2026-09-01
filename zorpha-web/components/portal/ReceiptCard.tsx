import Link from 'next/link';
import type { RebalanceRow } from '@/lib/supabase';
import { explorerTx } from '@/lib/contracts';
import { formatAddress, formatRelative, formatUnits, bpsToPct } from '@/lib/format';

function targetLabel(row: RebalanceRow): string {
  if (row.vault_type === 'rotation' && row.target_weights?.length) {
    return row.target_weights.map((w) => bpsToPct(w, 0)).join(' / ');
  }
  if (row.target_bps !== null && row.target_bps !== undefined) {
    return bpsToPct(row.target_bps, 0);
  }
  return '—';
}

export function ReceiptCard({ row }: { row: RebalanceRow }) {
  return (
    <article className="card card-hover overflow-hidden">
      <header className="flex flex-wrap items-center justify-between gap-3 border-b border-void-700 bg-void-850 px-4 py-3">
        <div className="flex items-center gap-2.5">
          <span className="h-1.5 w-1.5 rounded-full bg-verified-400" />
          <span className="font-mono text-xs text-ink-200">Rebalanced</span>
          <span className="badge">{row.vault_type}</span>
        </div>
        <div className="flex items-center gap-3 font-mono text-2xs text-ink-500">
          <span>nonce {row.nonce}</span>
          <span aria-hidden="true">·</span>
          <time dateTime={row.block_timestamp}>{formatRelative(row.block_timestamp)}</time>
        </div>
      </header>

      <dl className="grid grid-cols-2 gap-4 px-4 py-4 sm:grid-cols-4">
        <div>
          <dt className="stat-label">Target</dt>
          <dd className="mt-1 font-mono text-sm text-ink-100">{targetLabel(row)}</dd>
        </div>
        <div>
          <dt className="stat-label">NAV / share</dt>
          <dd className="mt-1 font-mono text-sm text-ink-100">
            {row.nav_per_share ? formatUnits(row.nav_per_share, 18, 5) : '—'}
          </dd>
        </div>
        <div>
          <dt className="stat-label">Manager</dt>
          <dd className="mt-1 font-mono text-sm">
            <Link href={`/portal/managers/${row.manager}`} className="text-zor-300 hover:text-zor-200">
              {formatAddress(row.manager)}
            </Link>
          </dd>
        </div>
        <div>
          <dt className="stat-label">Vault</dt>
          <dd className="mt-1 font-mono text-sm">
            <Link
              href={`/portal/vaults/${row.vault_address}`}
              className="text-ink-200 hover:text-ink-100"
            >
              {formatAddress(row.vault_address)}
            </Link>
          </dd>
        </div>
      </dl>

      <footer className="flex flex-wrap items-center justify-between gap-2 border-t border-void-700 px-4 py-2.5">
        <span className="truncate font-mono text-2xs text-ink-500">
          {row.commitment ? `commitment ${formatAddress(row.commitment, 8, 6)}` : 'no commitment'}
        </span>
        <a
          href={explorerTx(row.tx_hash)}
          target="_blank"
          rel="noreferrer noopener"
          className="font-mono text-2xs text-ink-400 hover:text-zor-300"
        >
          block {row.block_number.toLocaleString('en-US')} ↗
        </a>
      </footer>
    </article>
  );
}

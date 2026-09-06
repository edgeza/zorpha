import Link from 'next/link';
import type { ManagerRow } from '@/lib/supabase';
import { formatAddress, formatRelative, formatDate } from '@/lib/format';

export function LeaderboardTable({ managers }: { managers: ManagerRow[] }) {
  return (
    <div className="card scroll-x overflow-hidden">
      <table className="w-full min-w-[42rem] text-sm">
        <caption className="sr-only">
          Vault managers ranked by number of signed rebalances
        </caption>
        <thead>
          <tr className="border-b border-void-700 bg-void-850 text-left">
            <th scope="col" className="px-4 py-3 text-2xs font-medium uppercase tracking-[0.12em] text-ink-500">
              #
            </th>
            <th scope="col" className="px-4 py-3 text-2xs font-medium uppercase tracking-[0.12em] text-ink-500">
              Manager
            </th>
            <th scope="col" className="px-4 py-3 text-right text-2xs font-medium uppercase tracking-[0.12em] text-ink-500">
              Receipts
            </th>
            <th scope="col" className="px-4 py-3 text-right text-2xs font-medium uppercase tracking-[0.12em] text-ink-500">
              First seen
            </th>
            <th scope="col" className="px-4 py-3 text-right text-2xs font-medium uppercase tracking-[0.12em] text-ink-500">
              Last active
            </th>
          </tr>
        </thead>
        <tbody className="divide-y divide-void-700">
          {managers.map((manager, i) => (
            <tr key={manager.address} className="transition-colors hover:bg-void-850/60">
              <td className="px-4 py-3.5 font-mono text-xs text-ink-500">{i + 1}</td>
              <td className="px-4 py-3.5">
                <Link
                  href={`/portal/managers/${manager.address}`}
                  className="font-mono text-zor-300 hover:text-zor-200"
                >
                  {manager.label ?? formatAddress(manager.address)}
                </Link>
                {manager.label ? (
                  <div className="mt-0.5 font-mono text-2xs text-ink-500">
                    {formatAddress(manager.address)}
                  </div>
                ) : null}
              </td>
              <td className="px-4 py-3.5 text-right font-mono text-ink-100">
                {manager.total_rebalances.toLocaleString('en-US')}
              </td>
              <td className="px-4 py-3.5 text-right font-mono text-xs text-ink-400">
                {formatDate(manager.first_seen_at)}
              </td>
              <td className="px-4 py-3.5 text-right font-mono text-xs text-ink-400">
                {manager.last_active_at ? formatRelative(manager.last_active_at) : ', '}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

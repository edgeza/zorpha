import type { Metadata } from 'next';
import { listManagers } from '@/lib/queries';
import { LeaderboardTable } from '@/components/portal/LeaderboardTable';
import Link from 'next/link';
import { EmptyState, Callout } from '@/components/ui/Primitives';

export const metadata: Metadata = { title: 'Managers' };
export const revalidate = 60;

export default async function LeaderboardPage() {
  const managers = await listManagers();

  return (
    <div className="flex flex-col gap-8">
      <header>
        <h1 className="text-2xl font-semibold tracking-tight sm:text-3xl">Managers</h1>
        <p className="mt-3 max-w-2xl text-sm leading-relaxed text-ink-400">
          Ranked by how many rebalances they have signed, which measures activity rather than skill.
        </p>
      </header>

      <Callout tone="info" title="Why there is no return column">
        <p>
          Ranking managers by realised return would reward whoever took the most risk in the
          luckiest window, and V1 does not have enough history for any performance statistic to
          mean anything. Open a manager to read their receipts and judge the decisions directly.
        </p>
      </Callout>

      {managers.length === 0 ? (
        <EmptyState
          title="Nobody has a record here yet"
          body="A manager earns a row by signing a rebalance, not by launching a vault, so this stays empty until the first instruction is signed. That is the whole point of the ranking: it cannot be joined by announcement."
          action={
            <Link href="/portal/leaders/launch" className="btn-primary btn-sm">
              Launch a vault
            </Link>
          }
        />
      ) : (
        <LeaderboardTable managers={managers} />
      )}
    </div>
  );
}

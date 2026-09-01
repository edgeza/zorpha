import type { Metadata } from 'next';
import { listManagers } from '@/lib/queries';
import { LeaderboardTable } from '@/components/portal/LeaderboardTable';
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
          title="No managers indexed"
          body="Managers appear here after their first signed rebalance is indexed."
        />
      ) : (
        <LeaderboardTable managers={managers} />
      )}
    </div>
  );
}

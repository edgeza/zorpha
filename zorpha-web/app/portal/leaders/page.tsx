import type { Metadata } from 'next';
import { LaunchLink, VaultLeaderboard } from '@/components/portal/VaultLeaderboard';
import { Callout } from '@/components/ui/Primitives';

export const metadata: Metadata = { title: 'Vault leaders' };

export default function LeadersPage() {
  return (
    <div className="flex flex-col gap-8">
      <header>
        <h1 className="text-2xl font-semibold tracking-tight sm:text-3xl">Vault leaders</h1>
        <p className="mt-3 max-w-2xl text-sm leading-relaxed text-ink-400">
          Anyone can launch a vault here. Doing so costs a $ZOR bond and requires the leader to
          post their own capital, which is subordinated to yours: it absorbs losses first, and
          your deposit is not touched until it is gone.
        </p>
        <LaunchLink className="mt-5" />
      </header>

      <VaultLeaderboard />

      <Callout tone="info" title="Reading the coverage column">
        <p>
          Coverage is the leader&rsquo;s own capital as a share of the vault&rsquo;s deposits. At
          5% coverage, the first 5% of any loss falls on the leader before it reaches you. It is
          read live from the escrow contract, not reported by the leader.
        </p>
        <p>
          Higher is safer, but it is not the whole picture: a small, well-covered vault is easy
          to back with a few thousand dollars. Read the receipts as well as the ratio.
        </p>
      </Callout>

      <Callout tone="warn" title="What coverage does not protect against">
        <p>
          The buffer is finite. A loss larger than the leader&rsquo;s capital reaches depositors
          for the remainder, and a vault can still lose more than the leader has posted. Coverage
          changes the order in which losses land, not whether they can happen.
        </p>
      </Callout>
    </div>
  );
}

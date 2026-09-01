import type { Metadata } from 'next';
import { TokenPanel } from '@/components/portal/TokenPanel';
import { Callout, SpecRow } from '@/components/ui/Primitives';
import { contracts, isDeployed, explorerAddress } from '@/lib/contracts';
import { formatAddress } from '@/lib/format';
import { TOKEN } from '@/lib/tokenomics';

export const metadata: Metadata = { title: 'Governance' };

const ROLES: { contract: string; key: keyof typeof contracts | null; holder: string; powers: string }[] =
  [
    {
      contract: 'Zorpha token',
      key: 'zor',
      holder: 'nobody',
      powers: 'No owner, no admin, no pause, no mint. Nothing to hold.',
    },
    {
      contract: 'Timelock',
      key: 'timelock',
      holder: 'Governance Safe',
      powers: 'Queues and executes every privileged action after a 48-hour delay.',
    },
    {
      contract: 'Buyback',
      key: 'buyback',
      holder: 'Timelock',
      powers: 'Set swap route, set threshold, withdraw undeployed fee revenue.',
    },
    {
      contract: 'Treasury',
      key: 'treasury',
      holder: 'Timelock',
      powers: 'Rescue misrouted tokens. Fee splitting itself is not discretionary.',
    },
    {
      contract: 'Insurance fund',
      key: 'insurance',
      holder: 'Timelock',
      powers: 'Pay out against a verified shortfall.',
    },
    {
      contract: 'Airdrop distributor',
      key: 'merkleDistributor',
      holder: 'Timelock',
      powers: 'Sweep unclaimed tokens, but only after the published deadline.',
    },
    {
      contract: 'Vesting',
      key: 'vesting',
      holder: 'Governance Safe',
      powers: 'Create schedules, revoke revocable schedules. Cannot touch vested tokens.',
    },
  ];

export default function GovernancePage() {
  return (
    <div className="flex flex-col gap-8">
      <header>
        <h1 className="text-2xl font-semibold tracking-tight sm:text-3xl">Governance</h1>
        <p className="mt-3 max-w-2xl text-sm leading-relaxed text-ink-400">
          {TOKEN.ticker} carries real, checkpointed voting weight. Being straight about what that
          does and does not currently buy you matters more than the feature itself.
        </p>
      </header>

      <Callout tone="warn" title="No on-chain proposal system is live in V1">
        <p>
          The token implements ERC-5805 voting with timestamp-keyed checkpoints, so voting weight is
          measurable and historically queryable today. What does not exist yet is a Governor
          contract: there is no on-chain venue in which to submit or execute a proposal, and
          protocol changes currently move through a multisig behind the 48-hour Timelock.
        </p>
        <p>
          Delegating now is still worth doing. It establishes your voting weight from the block you
          delegate, which is what a future Governor will measure against.
        </p>
      </Callout>

      <section className="grid gap-5 lg:grid-cols-2">
        <TokenPanel />
        <div className="card-pad">
          <h2 className="text-sm font-semibold text-ink-100">Voting mechanics</h2>
          <dl className="mt-3 divide-hair">
            <SpecRow label="Standard">ERC-5805 (ERC20Votes)</SpecRow>
            <SpecRow label="Clock">
              Timestamp, not block number (ERC-6372 <span className="font-mono">mode=timestamp</span>)
            </SpecRow>
            <SpecRow label="Delegation">
              Required. An undelegated balance has zero voting weight.
            </SpecRow>
            <SpecRow label="Unvested tokens">
              Zero weight — the vesting contract never delegates.
            </SpecRow>
            <SpecRow label="Quorum / thresholds">Not set. No Governor deployed.</SpecRow>
          </dl>
          <p className="mt-4 border-t border-void-700 pt-4 text-xs leading-relaxed text-ink-500">
            A timestamp clock was chosen deliberately. Robinhood Chain does not guarantee a stable
            block interval, and a block-numbered voting period drifts in wall-clock terms — a
            &ldquo;three day&rdquo; vote can quietly become five.
          </p>
        </div>
      </section>

      <section>
        <h2 className="mb-4 text-lg font-semibold">Who can do what</h2>
        <div className="card scroll-x overflow-hidden">
          <table className="w-full min-w-[44rem] text-sm">
            <thead>
              <tr className="border-b border-void-700 bg-void-850 text-left">
                {['Contract', 'Address', 'Controlled by', 'Powers'].map((h) => (
                  <th
                    key={h}
                    scope="col"
                    className="px-4 py-3 text-2xs font-medium uppercase tracking-[0.12em] text-ink-500"
                  >
                    {h}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody className="divide-y divide-void-700">
              {ROLES.map((role) => (
                <tr key={role.contract}>
                  <td className="px-4 py-3.5 text-ink-100">{role.contract}</td>
                  <td className="px-4 py-3.5">
                    {role.key && isDeployed(role.key) ? (
                      <a
                        href={explorerAddress(contracts[role.key])}
                        target="_blank"
                        rel="noreferrer noopener"
                        className="font-mono text-2xs text-ink-400 hover:text-zor-300"
                      >
                        {formatAddress(contracts[role.key])} ↗
                      </a>
                    ) : (
                      <span className="font-mono text-2xs text-ink-600">not set</span>
                    )}
                  </td>
                  <td className="px-4 py-3.5 text-xs text-ink-300">{role.holder}</td>
                  <td className="px-4 py-3.5 text-xs leading-relaxed text-ink-400">
                    {role.powers}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>
    </div>
  );
}

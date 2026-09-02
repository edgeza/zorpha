import type { Metadata } from 'next';
import { SectionHeading, Callout } from '@/components/ui/Primitives';

export const metadata: Metadata = {
  alternates: { canonical: '/roadmap' },
  title: 'Roadmap',
  description:
    'What Zorpha ships next, in order, with the gate that has to close before each phase can start.',
};

type Phase = {
  label: string;
  state: 'done' | 'active' | 'next' | 'later';
  title: string;
  body: string;
  items: string[];
  gate?: string;
};

const PHASES: Phase[] = [
  {
    label: 'Phase 0',
    state: 'done',
    title: 'Token layer, audited and green',
    body: 'The token, vesting, airdrop distributor, treasury and buyback are written, internally audited, fixed and covered by a passing test suite.',
    items: [
      'Fixed-supply token with no mint, no owner, no pause',
      'Buyback rewritten to perform a real swap and a real burn',
      'Vesting cliff mathematics corrected and pinned by tests',
      'Deploy script distributes the whole supply atomically and asserts the deploy key ends with nothing',
      'Every finding published, including the unresolved ones',
    ],
  },
  {
    label: 'Phase 1',
    state: 'active',
    title: 'Vault layer remediation',
    body: 'The vault contracts have one critical and two high findings open. Nothing else ships until they are closed, because everything else depends on deposits being safe.',
    items: [
      'Fix the yield vault so deposits reach the adapter its share price is measured against',
      'Repair the EIP-712 signed rebalance path and its four failing tests',
      'Repair the reputation registry publish and challenge flows',
      'Make the invariant suite fail on a 100% revert rate instead of passing vacuously',
      'Re-enable deposits in the portal only once the suite is green',
    ],
    gate: 'Full test suite green, zero critical or high findings open.',
  },
  {
    label: 'Phase 2',
    state: 'next',
    title: 'Third-party audit and testnet launch',
    body: 'Before any real money is involved, the contracts go to an external firm, and those findings get published in full the same way the internal ones were.',
    items: [
      'External audit of the token and vault layers',
      'Public testnet with real managers signing real rebalances',
      'Seat a multi-key oracle updater set and raise the median quorum',
      'Season 1 snapshot criteria published before the snapshot is taken',
    ],
    gate: 'External audit report published, including any accepted risks.',
  },
  {
    label: 'Phase 3',
    state: 'next',
    title: 'Mainnet and token launch',
    body: 'Deployment, distribution, and liquidity. The float is set at launch and the insider tranches do not begin unlocking for twelve months.',
    items: [
      'Mainnet deployment with governance handover asserted in the deploy transaction',
      'Season 1 airdrop claims open',
      'Protocol-owned liquidity paired into the primary market',
      'Buyback swap route configured and the burn ledger live in the portal',
    ],
    gate: 'Audit remediation complete, governance Safe signers confirmed.',
  },
  {
    label: 'Phase 4',
    state: 'later',
    title: 'Governance and open vaults',
    body: 'Voting weight exists from day one, but a token that can vote without anywhere to vote is only half the feature. This phase builds the other half.',
    items: [
      'Governor contract wired to the existing timestamp-keyed checkpoints',
      'Season-by-season ecosystem emissions voted rather than assumed',
      'Manager bonding — live on testnet ahead of schedule as the vault launcher: a 10,000 $ZOR bond plus first-loss capital that absorbs losses before any depositor',
      'Permissionless yield-vault creation behind that bond — live on testnet; spot and rotation vaults stay governance-gated for now',
      'ERC-7540 asynchronous deposits for strategies that cannot settle instantly',
    ],
  },
];

const STATE_STYLES: Record<Phase['state'], { badge: string; label: string; dot: string }> = {
  done: { badge: 'badge-verified', label: 'Complete', dot: 'bg-verified-400' },
  active: { badge: 'badge-warn', label: 'In progress', dot: 'bg-amber-400' },
  next: { badge: 'badge-zor', label: 'Next', dot: 'bg-zor-400' },
  later: { badge: 'badge', label: 'Later', dot: 'bg-ink-500' },
};

export default function RoadmapPage() {
  return (
    <>
      <section className="relative overflow-hidden border-b border-void-700">
        <div className="spotlight absolute inset-0 -z-10" aria-hidden="true" />
        <div className="shell py-16 sm:py-20">
          <span className="badge">Roadmap</span>
          <h1 className="mt-6 max-w-3xl text-3xl font-semibold leading-tight tracking-tight sm:text-5xl">
            Ordered by dependency, not by date
          </h1>
          <p className="lede mt-6 max-w-2xl">
            Dates on a crypto roadmap are decoration. They slip, and the slip becomes the story.
            What follows is the order the work has to happen in, and the gate that must close before
            each phase can start. Nothing here is a delivery commitment.
          </p>
        </div>
      </section>

      <section className="shell py-16">
        <div className="space-y-5">
          {PHASES.map((phase) => {
            const style = STATE_STYLES[phase.state];
            return (
              <article key={phase.label} className="card-pad">
                <div className="flex flex-wrap items-center gap-3">
                  <span className="font-mono text-2xs text-ink-500">{phase.label}</span>
                  <span className={style.badge}>
                    <span className={`h-1.5 w-1.5 rounded-full ${style.dot}`} />
                    {style.label}
                  </span>
                </div>

                <h2 className="mt-3.5 text-xl font-semibold text-ink-100">{phase.title}</h2>
                <p className="mt-2.5 max-w-3xl text-sm leading-relaxed text-ink-400">
                  {phase.body}
                </p>

                <ul className="mt-5 space-y-2.5">
                  {phase.items.map((item) => (
                    <li key={item} className="flex gap-3 text-sm text-ink-300">
                      <span
                        className={`mt-1.5 h-1.5 w-1.5 shrink-0 rounded-full ${
                          phase.state === 'done' ? 'bg-verified-500' : 'bg-void-500'
                        }`}
                      />
                      {item}
                    </li>
                  ))}
                </ul>

                {phase.gate ? (
                  <div className="mt-5 border-t border-void-700 pt-4">
                    <span className="stat-label">Gate to the next phase</span>
                    <p className="mt-1.5 text-sm text-ink-300">{phase.gate}</p>
                  </div>
                ) : null}
              </article>
            );
          })}
        </div>

        <div className="mt-10">
          <SectionHeading
            eyebrow="Explicitly deferred"
            title="Things we decided not to build yet"
            lede="Cutting scope is the reason phase 0 is finished. These are tracked, not forgotten."
          />
          <div className="mt-8 grid gap-4 sm:grid-cols-2">
            {[
              ['Permissionless spot and rotation vaults', 'Anyone can launch a yield vault behind a bond and subordinated capital. Equity strategies still go through governance: a long tail of unreviewed mandates on tokenised stocks is a different risk from a curated ERC-4626 venue.'],
              ['A protocol-run house vault', 'One flagship vault the protocol itself operates, open to everyone. Wanted, but only after the leader vaults have a track record to design it against.'],
              ['AI-signed rebalances', 'The signing path is agnostic about who holds the key. Marketing it before there is a track record would be backwards.'],
              ['Cross-chain deployment', 'One chain, done properly, before several done partially.'],
            ].map(([title, body]) => (
              <div key={title} className="card-pad">
                <h3 className="text-sm font-semibold text-ink-100">{title}</h3>
                <p className="mt-2 text-sm leading-relaxed text-ink-400">{body}</p>
              </div>
            ))}
          </div>
        </div>

        <div className="mt-10">
          <Callout tone="info" title="How to check whether this page is honest">
            <p>
              Phase 0 claims a passing token test suite and phase 1 claims the vault suite is
              failing. Both are checkable: clone the protocol repository and run the test suite. If
              this page and the output disagree, believe the output.
            </p>
          </Callout>
        </div>
      </section>
    </>
  );
}

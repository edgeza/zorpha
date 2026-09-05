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
    state: 'done',
    title: 'Vault layer remediation',
    body: 'All 24 internal findings are closed and pinned by regression tests, including the critical one where the yield vault priced shares against an adapter balance it never funded. Deposits are enabled in the portal.',
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
    state: 'active',
    title: 'Third-party audit',
    body: 'This phase was meant to gate the next one and did not. The testnet ran and its managers signed real rebalances, but the contracts went to mainnet before an external firm reviewed them, and they remain unreviewed today. Verified source and a public test suite are evidence; they are not an audit. This is stated plainly rather than reordered away, because the sequence is the part a depositor needs to know.',
    items: [
      'Done: public testnet with real managers signing real rebalances. One of those receipts is the worked example on the home page, and it verifies in the reader’s own browser',
      'Not yet: external audit of the token and vault layers',
      'Not yet: a multi-key oracle updater set and a median quorum above one. There is no oracle on mainnet at all; the one vault live there prices from its ERC-4626 target instead',
    ],
    gate: 'External audit report published, including any accepted risks.',
  },
  {
    label: 'Phase 3',
    state: 'active',
    title: 'Mainnet and token launch',
    body: 'Partly shipped. The contracts are deployed and verified on Robinhood Chain, the float is set, and the insider tranches do not begin unlocking for twelve months. Two items below are not finished, and are listed as unfinished rather than quietly dropped.',
    items: [
      'Done: mainnet deployment, source-verified, with the whole supply distributed and the deploy key holding nothing',
      'Done: protocol-owned liquidity paired into the ZOR/USDG market',
      'Done: the first vault live over a real external yield source, with its rate read from the chain',
      'Not yet: Season 1 airdrop claims. The tranche is funded on-chain and held by governance until the criteria are published and voted',
      'Not yet: the buyback swap route. The burn ledger is live in the portal, but the router is unset, so no revenue has been converted',
    ],
    gate: 'Remaining: the external audit above, and Season 1 criteria put to a vote.',
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

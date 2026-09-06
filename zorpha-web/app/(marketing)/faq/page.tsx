import Link from 'next/link';
import type { Metadata } from 'next';
import { SectionHeading } from '@/components/ui/Primitives';
import { TOKEN, CIRCULATING_PCT } from '@/lib/tokenomics';
import { countBy } from '@/lib/audit';
import { MAINNET } from '@/lib/deployment';

export const metadata: Metadata = {
  alternates: { canonical: '/faq' },
  title: 'FAQ',
  description:
    'Straight answers about Zorpha vaults, $ZOR tokenomics, custody, governance, audit status and risk.',
};

type QA = { q: string; a: React.ReactNode };

const GROUPS: { heading: string; items: QA[] }[] = [
  {
    heading: 'Using the protocol',
    items: [
      {
        q: 'Do I need to hold ZOR to deposit into a vault?',
        a: 'No, and this is deliberate. Charging users a toll in your own token to use your product is a way of manufacturing demand, not creating it. Vaults take their underlying asset and nothing else.',
      },
      {
        q: 'Can a manager run off with my deposit?',
        a: 'No. Funds sit in the vault contract, and no manager, keeper or admin address has a function that can transfer them out. A manager produces a signature authorising a rebalance within limits the vault enforces independently. The worst a compromised manager key can do is push exposure to a bad target, within the daily rate limit, until the key is rotated.',
      },
      {
        q: 'Were there ever bugs that could have lost my deposit?',
        a: (
          <>
            Yes, and we publish them. Our internal audit found that the USDG yield vault valued
            shares against a yield-adapter balance it never actually funded, so a depositor could
            have burned every share and received nothing while their principal stayed stuck in the
            contract. Deposits were disabled until it was fixed. It is now fixed and pinned by a
            fuzz test asserting a deposit-then-redeem round trip is whole. All {countBy('fixed')}{' '}
            findings from that review are written up in the protocol repository.
          </>
        ),
      },
      {
        q: 'What fees do I pay?',
        a: 'A performance fee only, charged on gains above a high-water mark. 20% on the equity vaults, 10% on the yield vault. There is no management fee, so a vault that does nothing costs you nothing, and no deposit or withdrawal fee.',
      },
    ],
  },
  {
    heading: 'The token',
    items: [
      {
        q: 'Can more ZOR ever be created?',
        a: 'No. The entire supply of 1,000,000,000 is minted in the constructor and there is no mint function on the contract. Not an owner-gated one, not a testnet one, nothing. Supply can only fall, through burns. An earlier revision did carry a testnet mint function; it was removed, and a test now asserts no mint entrypoint exists in the ABI.',
      },
      {
        q: 'Does holding ZOR pay me anything?',
        a: 'No. There is no staking, no yield, no dividend and no revenue share. Protocol fees are used to buy ZOR on the open market and burn it, which reduces supply. That is not a payment to holders and it is not a promise about price.',
      },
      {
        q: `How much of the supply is actually liquid?`,
        a: `${CIRCULATING_PCT}% circulating: the governance Safe, protocol-owned liquidity and holders. 800,000,000 (80%) sits in a vesting contract on a 180-day cliff and then releases linearly to day 1095. That schedule is marked non-revocable onchain, so it cannot be cancelled or clawed back by anyone, including us.`,
      },
      {
        q: 'How much do insiders hold?',
        a: 'The published allocation reserves 25% for contributors and backers. Onchain, that share is not held as separate per-cohort schedules: the treasury, contributor and backer buckets were locked together as one non-revocable schedule to the governance Safe. Verify the vesting contract rather than the allocation table; it is the schedule that binds, and it releases nothing until day 180.',
      },
      {
        q: 'Is ZOR a security?',
        a: 'We are not in a position to give you a legal conclusion, and you should not accept one from a project website. What we can tell you is the design: no yield, no dividend, no revenue share, no claim on treasury assets, and a buyback that is triggered permissionlessly rather than at anyone’s discretion. Read the risk disclaimer, and take your own advice.',
      },
    ],
  },
  {
    heading: 'Governance',
    items: [
      {
        q: 'Is ZOR a governance token or not?',
        a: (
          <>
            It carries real voting weight, using ERC-5805 checkpoints that stay queryable
            historically. What does
            not exist yet is a Governor contract, so there is currently no on-chain venue to submit
            or execute a proposal, and changes move through a multisig behind a 48-hour timelock.
            Earlier documentation said the token had no voting weight at all, which was simply
            wrong; that contradiction is logged as a published finding.
          </>
        ),
      },
      {
        q: 'Why does my balance show zero voting weight?',
        a: 'ERC20Votes requires an explicit delegation before a balance counts. Delegating to yourself activates it and costs one transaction. This trips up almost everyone, so the portal detects it and offers the transaction directly.',
      },
      {
        q: 'What can the team change without warning?',
        a: 'Nothing. Every privileged action is queued in a 48-hour timelock, so you get two days of on-chain notice. The token contract itself has no admin function at all, so there is nothing to queue against it.',
      },
    ],
  },
  {
    heading: 'Risk',
    items: [
      {
        q: 'Has this been audited?',
        a: (
          <>
            The contracts have been through a full internal security review. Every finding is
            written up in the protocol repository, all of them are closed, and each one is pinned
            by a regression test.
            <br />
            <br />
            There has been no third-party audit. An earlier version of this answer called one a
            gate before mainnet. That is not what happened: the contracts were deployed to mainnet
            on {MAINNET.launchedOn} unaudited, and they remain unaudited today. Verified source on
            the explorer and a public test suite are evidence, but they are not an audit. Treat
            every deployed contract as unreviewed by a third party and size any position
            accordingly.
          </>
        ),
      },
      {
        q: 'What is the worst case for a depositor?',
        a: 'Total loss. That is true of every smart contract, and no audit changes it. Tokenised equity exposure can also fall, oracles can fail, and a manager can simply be wrong repeatedly. Nothing about a verifiable track record makes a bad decision profitable.',
      },
      {
        q: 'Is this live on mainnet?',
        a: `No. ${TOKEN.name} is deployed to ${TOKEN.chain} testnet only. Any address you see on this site is a testnet address until the deployment page says otherwise, and any token claiming to be ZOR on a mainnet today is not ours.`,
      },
    ],
  },
];

/**
 * FAQPage structured data.
 *
 * This is the one schema on the site with a direct payoff: a well-formed
 * FAQPage can surface the questions themselves as expandable rows under the
 * search result, which is a great deal of result real estate for a domain with
 * no ranking history.
 *
 * Only the answers stored as plain strings are emitted. A few are JSX because
 * they carry links, and rather than keep a hand-written plaintext copy of those
 * in sync with the markup, they are left out. Google requires that schema match
 * the visible page; a subset satisfies that, a stale duplicate would not.
 */
function FaqStructuredData() {
  const entries = GROUPS.flatMap((g) => g.items).filter(
    (item): item is { q: string; a: string } => typeof item.a === 'string',
  );

  const schema = {
    '@context': 'https://schema.org',
    '@type': 'FAQPage',
    mainEntity: entries.map((item) => ({
      '@type': 'Question',
      name: item.q,
      acceptedAnswer: { '@type': 'Answer', text: item.a },
    })),
  };

  return (
    <script
      type="application/ld+json"
      dangerouslySetInnerHTML={{ __html: JSON.stringify(schema) }}
    />
  );
}

export default function FaqPage() {
  return (
    <>
      <FaqStructuredData />
      <section className="relative overflow-hidden border-b border-void-700">
        <div className="spotlight absolute inset-0 -z-10" aria-hidden="true" />
        <div className="shell py-16 sm:py-20">
          <span className="badge">FAQ</span>
          <h1 className="mt-6 max-w-3xl text-3xl font-semibold leading-tight tracking-tight sm:text-5xl">
            Questions, answered without the marketing voice
          </h1>
          <p className="lede mt-6 max-w-2xl">
            Including the ones with answers we would rather not have to give.
          </p>
        </div>
      </section>

      <section className="shell-narrow py-16">
        <div className="space-y-14">
          {GROUPS.map((group) => (
            <div key={group.heading}>
              <SectionHeading title={group.heading} />
              <div className="mt-6 space-y-3">
                {group.items.map((item) => (
                  <details key={item.q} className="card group">
                    <summary className="flex cursor-pointer items-start justify-between gap-4 px-5 py-4 text-sm font-medium text-ink-100 marker:content-none [&::-webkit-details-marker]:hidden">
                      {item.q}
                      <span
                        className="mt-1 shrink-0 text-ink-500 transition-transform group-open:rotate-45"
                        aria-hidden="true"
                      >
                        +
                      </span>
                    </summary>
                    <div className="border-t border-void-700 px-5 py-4 text-sm leading-relaxed text-ink-400">
                      {item.a}
                    </div>
                  </details>
                ))}
              </div>
            </div>
          ))}
        </div>

        <div className="mt-16 card-pad text-center">
          <h2 className="text-lg font-semibold">Something not covered?</h2>
          <p className="mx-auto mt-2 max-w-md text-sm leading-relaxed text-ink-400">
            Security reports are the one kind of message we always want. Disclosure details are in
            the protocol repository under <span className="font-mono">docs/SECURITY.md</span>.
          </p>
          <div className="mt-6 flex flex-wrap justify-center gap-3">
            <Link href="/whitepaper#risk" className="btn-primary">
              Read the risk section
            </Link>
            <Link href="/legal/disclaimer" className="btn">
              Risk disclaimer
            </Link>
          </div>
        </div>
      </section>
    </>
  );
}

import Link from 'next/link';
import type { Metadata } from 'next';
import { Hero } from '@/components/marketing/Hero';
import { ReceiptAnatomy } from '@/components/marketing/ReceiptAnatomy';
import { SectionHeading } from '@/components/ui/Primitives';
import { ReceiptMarquee } from '@/components/marketing/ReceiptMarquee';
import { Reveal } from '@/components/motion/Reveal';
import { TOKEN } from '@/lib/tokenomics';
import { TEST_STATUS } from '@/lib/audit';

export const metadata: Metadata = {
  // Absolute, so the root layout's "%s · Zorpha" template does not append a
  // second "Zorpha" to a title that already starts with it.
  title: { absolute: 'Zorpha: verifiable onchain asset management' },
  description:
    'Curated vaults on Robinhood Chain where every rebalance is signed onchain and published as a public receipt. Fixed-supply $ZOR with fee-funded buyback and burn.',
};

const STEPS = [
  {
    n: '01',
    title: 'Pick a vault, not a promise',
    body: 'Each vault is an ERC-4626 contract with a fixed mandate, a named oracle, a hard slippage bound and a published fee. You can read all of it before you deposit a cent.',
  },
  {
    n: '02',
    title: 'The manager signs, the chain records',
    body: 'Managers cannot touch your funds. They sign an EIP-712 rebalance instruction; the vault verifies the signature, enforces its own risk limits, and emits a receipt.',
  },
  {
    n: '03',
    title: 'Judge them on the record',
    body: 'Every receipt is permanent and timestamped. A manager’s history is the sum of their receipts, including the bad ones. That is the entire point.',
  },
];

const VAULTS = [
  {
    symbol: 'zqHOOD',
    name: 'HOOD Long/Flat',
    mandate: 'Rotates a single tokenised equity between full exposure and cash.',
    detail: 'Oracle-gated · 1% max slippage · 20% performance fee',
  },
  {
    symbol: 'zqROT',
    name: 'RWA Rotation',
    mandate: 'Reweights a basket of tokenised equities against a USDC base.',
    detail: 'Per-asset oracles · basket weights onchain · 20% performance fee',
  },
  {
    symbol: 'zqUSD',
    name: 'USDC Yield',
    mandate: 'Routes idle USDC through a pluggable yield adapter.',
    detail: 'Adapter swaps are timelocked · 10% performance fee',
  },
];

const DIFFERENTIATORS = [
  {
    title: 'Managers never custody funds',
    body: 'A compromised manager key can request a rebalance within preset limits. It cannot withdraw, cannot change the mandate, and cannot raise its own fee.',
  },
  {
    title: 'Fail-closed oracles',
    body: 'If a price feed is stale or out of bounds, the vault reverts rather than guessing. A rebalance that cannot be priced honestly does not happen.',
  },
  {
    title: 'Fees buy and burn the token',
    body: `Half of every performance fee is used to buy ${TOKEN.ticker} on the open market and burn it. The contract reports the USDC actually spent and the tokens actually destroyed.`,
  },
  {
    title: 'Admin power sits behind a delay',
    body: 'Privileged changes are queued in a 48-hour Timelock owned by a multisig. You get two days of warning, not a surprise.',
  },
];

export default function HomePage() {
  return (
    <>
      <Hero />
      <ReceiptMarquee />

      {/* ─── The problem ──────────────────────────────────────────────────── */}
      <section className="shell py-20 sm:py-24">
        <div className="grid gap-12 lg:grid-cols-2 lg:items-center lg:gap-16">
          <div>
            <SectionHeading
              eyebrow="The problem"
              title="Everyone’s track record is undefeated"
              lede="Screenshots get cropped. Bad calls get deleted. “Up 400% this quarter” is a claim with no counterparty, and the people who most want your capital are the ones with the least to lose by exaggerating."
            />
            <p className="mt-5 max-w-2xl text-sm leading-relaxed text-ink-400">
              Zorpha does not ask you to trust a manager’s summary of their own performance. It
              removes the summary. What is left is a list of signed, timestamped instructions and
              what each one did to the vault’s net asset value. The same data for the manager’s
              best month and their worst.
            </p>
            <div className="mt-8 flex flex-wrap gap-3">
              <Link href="/protocol" className="btn-primary">
                Read the mechanism
              </Link>
              <Link href="/portal/receipts" className="btn">
                Browse live receipts
              </Link>
            </div>
          </div>

          <div id="receipts">
            <div className="mb-3 flex items-center justify-between">
              <span className="eyebrow">Anatomy of a receipt</span>
              <span className="badge-verified">verifiable</span>
            </div>
            <ReceiptAnatomy />
          </div>
        </div>
      </section>

      {/* ─── How it works ─────────────────────────────────────────────────── */}
      <section className="border-y border-void-700 bg-void-900/40 py-20 sm:py-24">
        <div className="shell">
          <SectionHeading
            eyebrow="How it works"
            title="Three steps, no trust required in between"
            align="center"
          />
          <div className="mt-14 grid gap-px overflow-hidden rounded-card border border-void-700 bg-void-700 md:grid-cols-3">
            {STEPS.map((step, i) => (
              <Reveal key={step.n} delay={i * 110} className="bg-void-900 p-7">
                <div className="font-mono text-xs text-zor-400">{step.n}</div>
                <h3 className="mt-4 text-lg font-semibold">{step.title}</h3>
                <p className="mt-3 text-sm leading-relaxed text-ink-400">{step.body}</p>
              </Reveal>
            ))}
          </div>
        </div>
      </section>

      {/* ─── Vaults ───────────────────────────────────────────────────────── */}
      <section id="vaults" className="shell py-20 sm:py-24">
        <div className="flex flex-col gap-6 sm:flex-row sm:items-end sm:justify-between">
          <SectionHeading
            eyebrow="Curated, not permissionless"
            title="Three vaults at launch"
            lede="V1 ships a small number of mandates on purpose. Every vault is deployed through a gated factory and reviewed before it exists, so there is no long tail of anonymous strategies for depositors to sift through."
          />
        </div>

        <div className="mt-12 grid gap-5 md:grid-cols-3">
          {VAULTS.map((vault, i) => (
            <Reveal
              key={vault.symbol}
              delay={i * 110}
              className="card-pad card-hover flex flex-col"
            >
              <div className="flex items-baseline justify-between gap-3">
                <h3 className="text-base font-semibold">{vault.name}</h3>
                <span className="badge font-mono">{vault.symbol}</span>
              </div>
              <p className="mt-3 flex-1 text-sm leading-relaxed text-ink-400">{vault.mandate}</p>
              <p className="mt-4 border-t border-void-700 pt-4 text-2xs leading-relaxed text-ink-500">
                {vault.detail}
              </p>
            </Reveal>
          ))}
        </div>

        <div className="mt-10 flex flex-wrap items-center gap-x-6 gap-y-3">
          <Link href="/whitepaper" className="btn-primary">
            Read the whitepaper
          </Link>
          <Link href="/security" className="link-quiet text-sm">
            {TEST_STATUS.suiteTests} contract tests, and every audit finding published
          </Link>
        </div>
      </section>

      {/* ─── Differentiators ──────────────────────────────────────────────── */}
      <section className="border-y border-void-700 bg-void-900/40 py-20 sm:py-24">
        <div className="shell">
          <SectionHeading
            eyebrow="How it holds up"
            title="Four things that stay true whoever is managing"
            lede="These are properties of the contracts rather than promises about conduct, which is why they survive a manager having a bad month, a bad year, or bad intentions."
          />
          <div className="mt-12 grid gap-5 sm:grid-cols-2">
            {DIFFERENTIATORS.map((item, i) => (
              <Reveal key={item.title} delay={i * 90} className="card-pad">
                <h3 className="text-base font-semibold text-ink-100">{item.title}</h3>
                <p className="mt-2.5 text-sm leading-relaxed text-ink-400">{item.body}</p>
              </Reveal>
            ))}
          </div>
        </div>
      </section>

      {/* ─── Token ────────────────────────────────────────────────────────── */}
      <section className="shell py-20 sm:py-24">
        <div className="grid gap-12 lg:grid-cols-2 lg:items-center lg:gap-16">
          <div>
            <SectionHeading
              eyebrow={TOKEN.ticker}
              title="A token with a job, not a yield"
              lede="ZOR has a fixed supply of one billion, minted once, with no mint function on the contract. It carries governance weight and captures protocol fees through buyback and burn. It pays no dividend and confers no claim on revenue."
            />
            <ul className="mt-7 space-y-3.5">
              {[
                'Fixed 1,000,000,000 supply that can only ever fall',
                'No owner, no pause, no blocklist, no upgrade path',
                'Half of all protocol fees buy and burn ZOR on the open market',
                'Real ERC-5805 voting weight, timestamp-keyed',
                'Never required to deposit into a vault',
              ].map((line) => (
                <li key={line} className="flex gap-3 text-sm text-ink-300">
                  <span className="mt-2 h-1 w-1 shrink-0 rounded-full bg-zor-400" />
                  {line}
                </li>
              ))}
            </ul>
            <div className="mt-8">
              <Link href="/token" className="btn-primary">
                Tokenomics in full
              </Link>
            </div>
          </div>

          <div className="card-pad">
            <div className="eyebrow">Contract properties</div>
            <dl className="mt-5 divide-hair">
              {[
                ['Standard', TOKEN.standard],
                ['Decimals', String(TOKEN.decimals)],
                ['Mint function', 'none. Supply fixed at deploy'],
                ['Owner / admin', 'none on the token itself'],
                ['Transfer tax', 'none'],
                ['Voting clock', 'timestamp (ERC-6372)'],
              ].map(([k, v]) => (
                <div key={k} className="flex items-baseline justify-between gap-6 py-3.5">
                  <dt className="text-xs uppercase tracking-[0.12em] text-ink-500">{k}</dt>
                  <dd className="text-right font-mono text-xs text-ink-200">{v}</dd>
                </div>
              ))}
            </dl>
          </div>
        </div>
      </section>

      {/* ─── Final CTA ────────────────────────────────────────────────────── */}
      <section className="shell pb-8">
        <div className="relative overflow-hidden rounded-card border border-zor-900 bg-void-900 px-7 py-14 text-center sm:px-14">
          <div className="spotlight absolute inset-0 -z-10" aria-hidden="true" />
          <h2 className="text-2xl font-semibold tracking-tight sm:text-4xl">
            Read the receipts before you read the pitch
          </h2>
          <p className="lede mx-auto mt-5 max-w-xl">
            The portal shows every rebalance every manager has ever signed, in order, with the
            transaction hash next to it.
          </p>
          <div className="mt-8 flex flex-col items-center justify-center gap-3 sm:flex-row">
            <Link href="/portal" className="btn-primary w-full sm:w-auto">
              Open the portal
            </Link>
            <Link href="/security" className="btn w-full sm:w-auto">
              Security posture
            </Link>
          </div>
        </div>
      </section>
    </>
  );
}

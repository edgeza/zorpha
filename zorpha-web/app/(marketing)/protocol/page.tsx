import Link from 'next/link';
import type { Metadata } from 'next';
import { ReceiptAnatomy } from '@/components/marketing/ReceiptAnatomy';
import { SectionHeading, Callout, SpecRow } from '@/components/ui/Primitives';

export const metadata: Metadata = {
  alternates: { canonical: '/protocol' },
  title: 'Protocol',
  description:
    'How Zorpha works: ERC-4626 vaults with fixed mandates, EIP-712 signed rebalances, fail-closed oracles, and a public receipt for every action a manager takes.',
};

const VAULTS = [
  {
    symbol: 'zqEQ',
    name: 'Long / Flat Equity',
    body: 'Holds a single Stock Token or sits in cash. The manager sets a target exposure in basis points; the vault will not act on a target that moves less than its rebalance threshold, which stops fee-generating churn.',
    specs: [
      ['Mandate', 'One asset versus USDG, 0–100% exposure'],
      ['Pricing', 'Single oracle, staleness-checked, fails closed'],
      ['Slippage cap', '1% per rebalance, enforced onchain'],
      ['Performance fee', '20% above high-water mark'],
    ],
  },
  {
    symbol: 'zqROT',
    name: 'RWA Rotation',
    body: 'Holds a basket of Stock Tokens against a USDG base and reweights between them. Target weights are stored onchain, so the intended portfolio is public before the trades settle.',
    specs: [
      ['Mandate', 'N-asset basket, weights sum to 100%'],
      ['Pricing', 'One oracle per asset, each staleness-checked'],
      ['Weights', 'Stored onchain and emitted per rebalance'],
      ['Performance fee', '20% above high-water mark'],
    ],
  },
  {
    symbol: 'zqUSD',
    name: 'USDG Yield',
    body: 'Routes idle USDG through a pluggable yield adapter. V1 ships a zero-yield, zero-risk stub so the slot is real before a lending market is wired in; swapping the adapter is a timelocked action.',
    specs: [
      ['Mandate', 'USDG in, USDG out, via one adapter'],
      ['Adapter changes', 'Timelock-gated, 48-hour delay'],
      ['Performance fee', '10% above high-water mark'],
      ['Status', 'Live. Capital routes through the adapter'],
    ],
  },
];

export default function ProtocolPage() {
  return (
    <>
      <section className="relative overflow-hidden border-b border-void-700">
        <div className="spotlight absolute inset-0 -z-10" aria-hidden="true" />
        <div className="shell py-16 sm:py-20">
          <span className="badge">Protocol</span>
          <h1 className="mt-6 max-w-3xl text-3xl font-semibold leading-tight tracking-tight sm:text-5xl">
            The manager signs. The vault decides. The chain remembers.
          </h1>
          <p className="lede mt-6 max-w-2xl">
            Zorpha separates three things that most asset management collapses into one: who decides
            the trade, who holds the funds, and who keeps the record. A manager only ever produces a
            signature. The vault holds custody and enforces its own limits. The chain writes the
            record, and nobody can edit it afterwards.
          </p>
        </div>
      </section>

      {/* ─── Mechanism ───────────────────────────────────────────────────── */}
      <section className="shell py-20">
        <SectionHeading
          eyebrow="Mechanism"
          title="What happens when a manager rebalances"
        />

        <div className="mt-12 grid gap-10 lg:grid-cols-2 lg:gap-14">
          <ol className="space-y-6">
            {[
              [
                'The manager signs an instruction',
                'An EIP-712 payload naming the vault, the target weight, a nonce and an expiry. It is a signature, not a transaction. The manager never holds a privileged position in the vault.',
              ],
              [
                'Anyone can submit it',
                'The signature is worthless to a third party: it can only do the one thing it says, to the one vault it names, once. Submission is permissionless, so the protocol does not depend on the manager also running reliable infrastructure.',
              ],
              [
                'The executor verifies and rate-limits',
                'It checks the signer is the vault’s authorised manager, that the nonce has not been used, that the expiry has not passed, and that the manager is under their daily limit.',
              ],
              [
                'The vault enforces its own rules',
                'Independently of the executor, the vault re-checks the target is within bounds, prices the trade against its oracle, reverts if the price is stale or out of range, and refuses a fill worse than its slippage cap.',
              ],
              [
                'The receipt is emitted',
                'Target, both legs of the trade, resulting NAV per share, the nonce and a commitment hash binding all of it. Permanent, timestamped, and readable by anyone.',
              ],
            ].map(([title, body], i) => (
              <li key={title} className="flex gap-5">
                <span className="mt-0.5 flex h-8 w-8 shrink-0 items-center justify-center rounded-full border border-zor-600/50 bg-zor-500/10 font-mono text-xs text-zor-300">
                  {i + 1}
                </span>
                <div>
                  <h3 className="text-base font-semibold text-ink-100">{title}</h3>
                  <p className="mt-1.5 text-sm leading-relaxed text-ink-400">{body}</p>
                </div>
              </li>
            ))}
          </ol>

          <div id="receipts" className="lg:sticky lg:top-24 lg:self-start">
            <div className="mb-3 flex items-center justify-between">
              <span className="eyebrow">The output</span>
              <span className="badge-verified">immutable</span>
            </div>
            <ReceiptAnatomy />
            <p className="mt-4 text-xs leading-relaxed text-ink-500">
              The commitment hash is what makes a track record checkable rather than merely public.
              Recompute it from the fields; if it does not match, the record has been tampered with.
            </p>
          </div>
        </div>
      </section>

      {/* ─── Vaults ──────────────────────────────────────────────────────── */}
      <section id="vaults" className="border-y border-void-700 bg-void-900/40 py-20">
        <div className="shell">
          <SectionHeading
            eyebrow="Vaults"
            title="Three mandates, deliberately few"
            lede="A permissionless vault factory produces a long tail of anonymous strategies that nobody can meaningfully evaluate. V1 curates instead: every vault is deployed through a gated factory and reviewed before it exists."
          />

          <div className="mt-12 space-y-5">
            {VAULTS.map((vault) => (
              <div key={vault.symbol} className="card-pad">
                <div className="grid gap-6 lg:grid-cols-[1fr_minmax(0,20rem)]">
                  <div>
                    <div className="flex items-baseline gap-3">
                      <h3 className="text-lg font-semibold text-ink-100">{vault.name}</h3>
                      <span className="badge font-mono">{vault.symbol}</span>
                    </div>
                    <p className="mt-3 text-sm leading-relaxed text-ink-400">{vault.body}</p>
                  </div>
                  <dl className="divide-hair lg:border-l lg:border-void-700 lg:pl-6">
                    {vault.specs.map(([k, v]) => (
                      <div key={k} className="flex items-baseline justify-between gap-4 py-2.5">
                        <dt className="text-2xs uppercase tracking-[0.12em] text-ink-500">{k}</dt>
                        <dd className="text-right font-mono text-2xs text-ink-200">{v}</dd>
                      </div>
                    ))}
                  </dl>
                </div>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* ─── Guarantees ──────────────────────────────────────────────────── */}
      <section className="shell py-20">
        <SectionHeading
          eyebrow="Guarantees"
          title="The properties that hold regardless of who is managing"
        />
        <div className="mt-10 card-pad">
          <dl className="divide-hair">
            <SpecRow label="Custody">
              Funds live in the vault contract. No manager, keeper or admin address can transfer
              them out.
            </SpecRow>
            <SpecRow label="Share accounting">
              ERC-4626. Deposits and redemptions are priced from the vault&rsquo;s own valuation,
              not from a quoted figure.
            </SpecRow>
            <SpecRow label="Oracle failure">
              Fails closed. A stale or out-of-bounds price reverts the rebalance rather than
              pricing it wrongly.
            </SpecRow>
            <SpecRow label="Fee basis">
              Performance fee only, charged above a high-water mark. No management fee, so an idle
              vault costs nothing.
            </SpecRow>
            <SpecRow label="Rate limiting">
              Each manager has a per-day rebalance limit, capping the damage from a compromised
              signing key to roughly a day of misdirected exposure.
            </SpecRow>
            <SpecRow label="Circuit breaker">
              A risk-council role can halt deposits and rebalances on a single vault without
              touching redemptions.
            </SpecRow>
            <SpecRow label="Admin delay">
              Every privileged change is queued in a 48-hour Timelock owned by a multisig.
            </SpecRow>
          </dl>
        </div>

        <div className="mt-8">
          <Callout tone="verified" title="Each of these is pinned by a test">
            <p>
              Each guarantee above is covered by tests rather than asserted in prose: 97 unit and
              fuzz tests plus seven stateful invariants, including one that fails the run outright
              if the fuzzer never actually managed a deposit or a rebalance.
            </p>
            <p>
              <Link href="/whitepaper#receipts" className="link-quiet">
                How the receipt scheme works
              </Link>
            </p>
          </Callout>
        </div>
      </section>
    </>
  );
}

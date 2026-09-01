import Link from 'next/link';
import type { Metadata } from 'next';
import { AllocationChart } from '@/components/marketing/AllocationChart';
import { SupplyCurve } from '@/components/marketing/SupplyCurve';
import { SectionHeading, Callout, SpecRow, Stat } from '@/components/ui/Primitives';
import {
  ALLOCATIONS,
  TOKEN,
  FLOAT_AT_LAUNCH_PCT,
  INSIDER_PCT,
  tokensFor,
  pctFor,
} from '@/lib/tokenomics';
import { formatCompact, formatMonths } from '@/lib/format';
import { countBy, TEST_STATUS } from '@/lib/audit';

export const metadata: Metadata = {
  title: 'Token',
  description:
    '$ZOR tokenomics: 1,000,000,000 fixed supply, no mint function, 21% float at launch, and 50% of protocol fees used to buy and burn on the open market.',
};

export default function TokenPage() {
  return (
    <>
      {/* ─── Header ───────────────────────────────────────────────────────── */}
      <section className="relative overflow-hidden border-b border-void-700">
        <div className="spotlight absolute inset-0 -z-10" aria-hidden="true" />
        <div className="shell py-16 sm:py-20">
          <span className="badge-zor">{TOKEN.ticker}</span>
          <h1 className="mt-6 max-w-3xl text-3xl font-semibold leading-tight tracking-tight sm:text-5xl">
            One billion tokens, minted once, and no way to make more
          </h1>
          <p className="lede mt-6 max-w-2xl">
            {TOKEN.name} is the governance and fee-capture token of the protocol. It is not a
            staking product, it pays no yield, and it is never required to use a vault. What it does
            have is a fixed supply, a real vote, and a share of protocol revenue that is spent
            buying it back and destroying it.
          </p>

          <div className="mt-10 grid grid-cols-2 gap-4 sm:grid-cols-4">
            <Stat label="Max supply" value={formatCompact(TOKEN.maxSupply)} sub="No mint function exists" />
            <Stat
              label="Float at launch"
              value={`${FLOAT_AT_LAUNCH_PCT}%`}
              sub="Airdrop plus protocol liquidity"
            />
            <Stat label="Insider share" value={`${INSIDER_PCT}%`} sub="Contributors and backers combined" />
            <Stat label="Fees to burn" value="50%" tone="verified" sub="Of all protocol revenue" />
          </div>
        </div>
      </section>

      {/* ─── Allocation ───────────────────────────────────────────────────── */}
      <section id="allocation" className="shell py-20">
        <SectionHeading
          eyebrow="Allocation"
          title="Where the supply goes"
          lede="Six buckets, summing to exactly 100%. The same basis points are hardcoded in the deploy script, which refuses to run if the distribution does not consume the entire supply and leave the deploy key holding zero."
        />

        <div className="mt-12 card-pad">
          <AllocationChart />
        </div>

        <div className="mt-8 space-y-4">
          {ALLOCATIONS.map((a) => (
            <div key={a.key} className="card-pad">
              <div className="flex flex-wrap items-baseline justify-between gap-3">
                <div className="flex items-center gap-3">
                  <span
                    className="h-2.5 w-2.5 rounded-sm"
                    style={{ background: a.color }}
                    aria-hidden="true"
                  />
                  <h3 className="text-base font-semibold text-ink-100">{a.label}</h3>
                </div>
                <div className="flex items-baseline gap-3 font-mono text-sm">
                  <span className="text-ink-100">{pctFor(a.bps)}%</span>
                  <span className="text-ink-500">{formatCompact(tokensFor(a.bps))}</span>
                </div>
              </div>

              <p className="mt-3 text-sm leading-relaxed text-ink-400">{a.rationale}</p>

              <dl className="mt-4 flex flex-wrap gap-x-8 gap-y-3 border-t border-void-700 pt-4">
                <div>
                  <dt className="stat-label">At launch</dt>
                  <dd className="mt-1 font-mono text-xs text-ink-200">
                    {a.tgeBps > 0 ? `${formatCompact(tokensFor(a.tgeBps))} (${pctFor(a.tgeBps)}%)` : 'nothing'}
                  </dd>
                </div>
                <div>
                  <dt className="stat-label">Cliff</dt>
                  <dd className="mt-1 font-mono text-xs text-ink-200">
                    {formatMonths(a.cliffMonths)}
                  </dd>
                </div>
                <div>
                  <dt className="stat-label">Vesting term</dt>
                  <dd className="mt-1 font-mono text-xs text-ink-200">
                    {a.shape === 'locked'
                      ? 'locked until governance releases'
                      : a.shape === 'tge'
                        ? 'fully unlocked'
                        : formatMonths(a.vestMonths)}
                  </dd>
                </div>
              </dl>
            </div>
          ))}
        </div>
      </section>

      {/* ─── Unlocks ──────────────────────────────────────────────────────── */}
      <section id="unlocks" className="border-y border-void-700 bg-void-900/40 py-20">
        <div className="shell">
          <SectionHeading
            eyebrow="Unlocks"
            title="A float you can plan around"
            lede="The most reliable way to break a token is to launch 5% of supply into a thin book and then unlock the other 95% into it. Twenty-one percent of supply is liquid on day one, and no insider tranche unlocks anything for twelve months."
          />
          <div className="mt-12">
            <SupplyCurve />
          </div>

          <div className="mt-8 grid gap-5 sm:grid-cols-3">
            {[
              {
                t: 'No insider cliff before month 12',
                b: 'Contributors and backers receive nothing at launch. Their first tokens arrive at month 12, then accrue per second rather than in monthly lumps.',
              },
              {
                t: 'Liquidity is owned, not rented',
                b: 'The 13% liquidity tranche is paired by the protocol itself. There is no incentive programme that can be turned off, taking the order book with it.',
              },
              {
                t: 'Emissions need a vote',
                b: 'The 30% ecosystem tail is released season by season against published criteria. It is a budget with an approver, not an automatic drip.',
              },
            ].map((item) => (
              <div key={item.t} className="card-pad">
                <h3 className="text-sm font-semibold text-ink-100">{item.t}</h3>
                <p className="mt-2 text-sm leading-relaxed text-ink-400">{item.b}</p>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* ─── Value accrual ────────────────────────────────────────────────── */}
      <section id="value" className="shell py-20">
        <div className="grid gap-12 lg:grid-cols-2 lg:gap-16">
          <div>
            <SectionHeading
              eyebrow="Value accrual"
              title="Fees buy the token and burn it"
              lede="Vaults charge a performance fee. Fees land in the treasury, which splits them fifty-fifty: half funds operations, half goes to a buyback contract that purchases ZOR on the open market and burns what it receives."
            />
            <p className="mt-5 text-sm leading-relaxed text-ink-400">
              The buyback is permissionless — anyone can trigger it once the balance clears a
              threshold — and the caller supplies their own minimum output, so a sandwich attempt
              cannot force the protocol into a bad fill.
            </p>
            <p className="mt-4 text-sm leading-relaxed text-ink-400">
              Both figures the contract reports are measured as balance deltas across the swap,
              not read from the swap venue&rsquo;s return value. A router cannot over-report a burn
              that did not happen, and the burn is a real{' '}
              <span className="font-mono text-ink-300">totalSupply</span> reduction rather than a
              transfer to a dead address.
            </p>
            <div className="mt-8">
              <Link href="/portal/governance" className="btn-primary">
                See the live burn ledger
              </Link>
            </div>
          </div>

          <div className="flex flex-col gap-5">
            <div className="card-pad">
              <div className="eyebrow">Fee route</div>
              <ol className="mt-5 space-y-4">
                {[
                  ['Vault earns a performance fee', 'Charged on gains above the high-water mark only.'],
                  ['Treasury receives it', 'A single contract, with no discretion over the split.'],
                  ['Split 50 / 50', 'Half to operations, half to the buyback contract.'],
                  ['Buyback purchases ZOR', 'On the open market, with caller-supplied slippage bounds.'],
                  ['Tokens are burned', 'Supply falls permanently. Nothing is recoverable.'],
                ].map(([title, body], i) => (
                  <li key={title} className="flex gap-4">
                    <span className="mt-0.5 flex h-6 w-6 shrink-0 items-center justify-center rounded-full border border-zor-600/50 bg-zor-500/10 font-mono text-2xs text-zor-300">
                      {i + 1}
                    </span>
                    <div>
                      <div className="text-sm font-medium text-ink-100">{title}</div>
                      <div className="mt-0.5 text-xs leading-relaxed text-ink-400">{body}</div>
                    </div>
                  </li>
                ))}
              </ol>
            </div>

            <Callout tone="info" title="What ZOR is not">
              <p>
                Not a dividend. Not a revenue share. Not a claim on treasury assets. Burning
                reduces supply — it does not entitle any holder to a payment, and it does not
                promise a price outcome.
              </p>
            </Callout>
          </div>
        </div>
      </section>

      {/* ─── Contract spec ───────────────────────────────────────────────── */}
      <section className="border-t border-void-700 bg-void-900/40 py-20">
        <div className="shell">
          <SectionHeading eyebrow="Contract" title="What the code actually permits" />
          <div className="mt-10 grid gap-5 lg:grid-cols-2">
            <div className="card-pad">
              <h3 className="text-sm font-semibold text-ink-100">Token parameters</h3>
              <dl className="mt-3 divide-hair">
                <SpecRow label="Name / symbol">
                  {TOKEN.name} / <span className="font-mono">{TOKEN.symbol}</span>
                </SpecRow>
                <SpecRow label="Decimals">{TOKEN.decimals}</SpecRow>
                <SpecRow label="Max supply">
                  <span className="font-mono">{TOKEN.maxSupply.toLocaleString('en-US')}</span>
                </SpecRow>
                <SpecRow label="Standards">{TOKEN.standard}</SpecRow>
                <SpecRow label="Network">{TOKEN.chain}</SpecRow>
                <SpecRow label="Voting clock">
                  timestamp — <span className="font-mono">mode=timestamp</span>
                </SpecRow>
              </dl>
            </div>

            <div className="card-pad">
              <h3 className="text-sm font-semibold text-ink-100">Powers that do not exist</h3>
              <ul className="mt-4 space-y-3">
                {[
                  ['Mint', 'There is no mint function. Supply is set in the constructor.'],
                  ['Owner or admin', 'The token has no privileged role of any kind.'],
                  ['Pause / freeze', 'Transfers cannot be halted by anyone.'],
                  ['Blocklist', 'No address can be denied the ability to transfer.'],
                  ['Transfer tax', 'Transfers move exactly the amount specified.'],
                  ['Upgrade', 'Not a proxy. The bytecode is final.'],
                ].map(([k, v]) => (
                  <li key={k} className="flex gap-3">
                    <span className="mt-1 font-mono text-xs text-verified-500" aria-hidden="true">
                      ✕
                    </span>
                    <div>
                      <span className="text-sm font-medium text-ink-200">{k}</span>
                      <span className="ml-2 text-xs text-ink-500">{v}</span>
                    </div>
                  </li>
                ))}
              </ul>
              <p className="mt-5 border-t border-void-700 pt-4 text-xs leading-relaxed text-ink-500">
                The only state-changing functions beyond standard ERC-20 transfer and approval are{' '}
                <span className="font-mono">burn</span>,{' '}
                <span className="font-mono">burnFrom</span>,{' '}
                <span className="font-mono">permit</span> and{' '}
                <span className="font-mono">delegate</span>.
              </p>
            </div>
          </div>

          <div className="mt-8">
            <Callout tone="warn" title="Not yet deployed, not yet externally audited">
              <p>
                The contracts have been reviewed internally, all {countBy('fixed')} findings are
                fixed, and the full suite is green at{' '}
                {TEST_STATUS.suiteTests - TEST_STATUS.suiteFailing} of {TEST_STATUS.suiteTests}. But
                no third-party audit has been completed and nothing is deployed to mainnet. Treat
                every address on this site as testnet until the deployment page says otherwise.
              </p>
              <p>
                <Link href="/security#audit" className="link-quiet">
                  Read every finding and how it was reproduced
                </Link>
              </p>
            </Callout>
          </div>
        </div>
      </section>
    </>
  );
}

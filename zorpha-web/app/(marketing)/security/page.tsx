import Link from 'next/link';
import type { Metadata } from 'next';
import { SectionHeading, Callout, Stat, SpecRow } from '@/components/ui/Primitives';
import {
  FINDINGS,
  openFindings,
  fixedFindings,
  countBy,
  AUDIT_DATE,
  AUDITOR,
  TEST_STATUS,
  type Finding,
  type Severity,
} from '@/lib/audit';
import { formatDate } from '@/lib/format';

export const metadata: Metadata = {
  title: 'Security',
  description:
    'Zorpha security posture: every internal audit finding in full, the mechanism behind each, the test that now prevents it, and what a compromised key can and cannot do.',
};

const SEVERITY_STYLES: Record<Severity, string> = {
  critical: 'border-danger-600/50 bg-danger-500/10 text-danger-400',
  high: 'border-amber-600/50 bg-amber-500/10 text-amber-400',
  medium: 'border-zor-600/50 bg-zor-500/10 text-zor-300',
  low: 'border-void-600 bg-void-800 text-ink-300',
  info: 'border-void-600 bg-void-800 text-ink-400',
};

function FindingCard({ finding }: { finding: Finding }) {
  return (
    <article className="card-pad">
      <div className="flex flex-wrap items-center gap-2.5">
        <span className="font-mono text-2xs text-ink-500">{finding.id}</span>
        <span
          className={`inline-flex items-center rounded-full border px-2.5 py-0.5 font-mono text-2xs uppercase tracking-wider ${SEVERITY_STYLES[finding.severity]}`}
        >
          {finding.severity}
        </span>
        <span className="badge">{finding.scope}</span>
        {finding.status === 'fixed' ? (
          <span className="badge-verified">fixed</span>
        ) : (
          <span className="badge-danger">open</span>
        )}
      </div>

      <h3 className="mt-3.5 text-base font-semibold text-ink-100">{finding.title}</h3>

      <div className="mt-3 space-y-3">
        <div>
          <div className="stat-label">Impact</div>
          <p className="mt-1.5 text-sm leading-relaxed text-ink-400">{finding.impact}</p>
        </div>
        <div>
          <div className="stat-label">
            {finding.status === 'fixed' ? 'Resolution' : 'Status'}
          </div>
          <p className="mt-1.5 text-sm leading-relaxed text-ink-400">{finding.resolution}</p>
        </div>
      </div>
    </article>
  );
}

export default function SecurityPage() {
  const open = openFindings();
  const fixed = fixedFindings();
  const criticalOpen = open.filter((f) => f.severity === 'critical').length;

  return (
    <>
      <section className="relative overflow-hidden border-b border-void-700">
        <div className="spotlight absolute inset-0 -z-10" aria-hidden="true" />
        <div className="shell py-16 sm:py-20">
          <span className="badge">Security</span>
          <h1 className="mt-6 max-w-3xl text-3xl font-semibold leading-tight tracking-tight sm:text-5xl">
            {countBy('fixed')} findings in code that had never been compiled
          </h1>
          <p className="lede mt-6 max-w-2xl">
            A security page that lists only resolved issues tells you nothing about whether anybody
            actually looked. Below is the complete output of our internal audit as of{' '}
            {formatDate(AUDIT_DATE)} — all {countBy('fixed')} findings, including two that would
            have caused unrecoverable loss of funds, each with the mechanism that made it possible
            and the test that now prevents it.
          </p>

          <div className="mt-10 grid grid-cols-2 gap-4 sm:grid-cols-4">
            <Stat label="Findings fixed" value={countBy('fixed')} tone="verified" />
            <Stat
              label="Findings open"
              value={countBy('open')}
              tone={countBy('open') === 0 ? 'verified' : 'warn'}
              sub={countBy('open') === 0 ? 'None outstanding' : `${criticalOpen} critical`}
            />
            <Stat
              label="Contract tests"
              value={`${TEST_STATUS.suiteTests - TEST_STATUS.suiteFailing}/${TEST_STATUS.suiteTests}`}
              size="md"
              tone={TEST_STATUS.suiteFailing === 0 ? 'verified' : 'warn'}
              sub={
                TEST_STATUS.suiteFailing === 0
                  ? 'All passing'
                  : `${TEST_STATUS.suiteFailing} failing`
              }
            />
            <Stat
              label="Third-party audit"
              value="Pending"
              size="md"
              tone="warn"
              sub="Gate before mainnet"
            />
          </div>
        </div>
      </section>

      {/* ─── Headline status ──────────────────────────────────────────────── */}
      <section id="audit" className="shell py-16">
        <Callout tone="warn" title="An internal review is not a third-party audit">
          <p>
            Every finding below was found, reproduced, fixed and pinned by the people who wrote the
            code. That is genuinely useful, and it has a hard ceiling: an internal review reliably
            finds the bugs its authors were capable of imagining. No external security firm has
            examined this code, and that stays a gate before mainnet rather than something to
            arrange afterwards.
          </p>
          <p>
            The two findings that would have caused unrecoverable loss of funds — a buyback contract
            that performed no swap while reporting that it had, and a yield vault that redeemed for
            zero — are described in full below. Both are closed.
          </p>
        </Callout>

        <div className="mt-8 grid gap-5 lg:grid-cols-2">
          <div className="card-pad">
            <h2 className="text-sm font-semibold text-ink-100">Review scope</h2>
            <dl className="mt-3 divide-hair">
              <SpecRow label="Reviewer">{AUDITOR}</SpecRow>
              <SpecRow label="Date">{formatDate(AUDIT_DATE)}</SpecRow>
              <SpecRow label="In scope">
                Whole protocol — token, vesting, buyback, airdrop distributor, treasury, the vaults,
                strategy executor, reputation registry, oracle, both deploy pipelines, the off-chain
                airdrop generator, and the front-end contract integration
              </SpecRow>
              <SpecRow label="Static analysis">
                Slither — 130 results, none at high or medium severity
              </SpecRow>
              <SpecRow label="Third-party audit">
                <span className="text-amber-400">Not started</span>
              </SpecRow>
              <SpecRow label="Mainnet deployment">
                <span className="text-amber-400">None</span>
              </SpecRow>
            </dl>
          </div>

          <div className="card-pad">
            <h2 className="text-sm font-semibold text-ink-100">What we will not claim</h2>
            <ul className="mt-4 space-y-3 text-sm leading-relaxed text-ink-400">
              {[
                'That an internal review substitutes for a third-party audit. It does not.',
                'That a passing test suite proves the absence of bugs. It proves the presence of tests.',
                `That closing ${countBy('fixed')} findings means there is no next one nobody has found.`,
                'That any of this predicts a price outcome for the token.',
              ].map((line) => (
                <li key={line} className="flex gap-3">
                  <span className="mt-2 h-1 w-1 shrink-0 rounded-full bg-ink-500" />
                  {line}
                </li>
              ))}
            </ul>
          </div>
        </div>
      </section>

      {/* ─── Open findings. Section stays even when empty: its absence would
           be indistinguishable from having nothing to report. ─────────────── */}
      <section className="border-y border-void-700 bg-void-900/40 py-16">
        <div className="shell">
          {open.length === 0 ? (
            <>
              <SectionHeading
                eyebrow="Nothing outstanding"
                title="No open findings"
                lede="This section stays on the page. When a finding is open it appears here with the same detail as a resolved one — otherwise publishing findings at all would mean very little."
              />
              <div className="card-pad mt-8">
                <p className="text-sm leading-relaxed text-ink-400">
                  The last items outstanding were the five vault-layer findings, closed alongside
                  two further issues uncovered during that work: a reputation flag a manager could
                  mint for themselves, and rotation-vault receipts that did not actually commit to
                  the basket they described. Both are below.
                </p>
              </div>
            </>
          ) : (
            <>
              <SectionHeading
                eyebrow={`${open.length} unresolved`}
                title="Open findings"
                lede="These are live problems in the current code. They are published because you should be able to price the risk yourself rather than take our word for it."
              />
              <div className="mt-10 space-y-5">
                {open.map((f) => (
                  <FindingCard key={f.id} finding={f} />
                ))}
              </div>
            </>
          )}
        </div>
      </section>

      {/* ─── Fixed findings ──────────────────────────────────────────────── */}
      <section className="shell py-16">
        <SectionHeading
          eyebrow={`${fixed.length} resolved`}
          title="Every finding"
          lede="Each was found, reproduced with a failing test where possible, fixed, and pinned with a regression test so it cannot come back quietly. Ordered by severity."
        />
        <div className="mt-10 space-y-5">
          {fixed.map((f) => (
            <FindingCard key={f.id} finding={f} />
          ))}
        </div>
      </section>

      {/* ─── Roles ───────────────────────────────────────────────────────── */}
      <section id="roles" className="border-t border-void-700 bg-void-900/40 py-16">
        <div className="shell">
          <SectionHeading
            eyebrow="Trust model"
            title="What a compromised key can do"
            lede="The useful question is not whether keys can be compromised, but what the worst outcome is when one is."
          />

          <div className="mt-10 grid gap-5 sm:grid-cols-2">
            {[
              {
                key: 'A manager key',
                can: 'Request rebalances within the vault’s preset weight bounds, slippage cap and daily rate limit.',
                cannot:
                  'Withdraw funds, change the mandate, raise the fee, change the oracle, or touch any other vault.',
              },
              {
                key: 'The governance Safe',
                can: 'Queue any privileged action, create and revoke vesting schedules, seat oracle updaters.',
                cannot:
                  'Mint tokens, execute a queued action before the 48-hour delay elapses, or take vested tokens back from a beneficiary.',
              },
              {
                key: 'The Timelock',
                can: 'Change the buyback swap route, withdraw undeployed fee revenue, pay out the insurance fund, sweep unclaimed airdrop after the deadline.',
                cannot:
                  'Act instantly. Every action is visible on-chain for two days before it can execute.',
              },
              {
                key: 'The deploy key',
                can: 'Nothing after deployment. It holds zero tokens and zero roles, and the deploy script asserts both before reporting success.',
                cannot: 'Anything at all. This is the point of the assertions.',
              },
            ].map((row) => (
              <div key={row.key} className="card-pad">
                <h3 className="font-mono text-sm text-zor-300">{row.key}</h3>
                <div className="mt-3.5 space-y-3">
                  <div>
                    <div className="stat-label text-verified-500">Can</div>
                    <p className="mt-1 text-sm leading-relaxed text-ink-300">{row.can}</p>
                  </div>
                  <div>
                    <div className="stat-label text-danger-400">Cannot</div>
                    <p className="mt-1 text-sm leading-relaxed text-ink-300">{row.cannot}</p>
                  </div>
                </div>
              </div>
            ))}
          </div>

          <div className="mt-10 flex flex-wrap gap-3">
            <Link href="/portal/governance" className="btn-primary">
              See live role assignments
            </Link>
            <Link href="/faq" className="btn">
              Read the FAQ
            </Link>
          </div>
        </div>
      </section>

      <section className="shell py-12">
        <p className="text-xs leading-relaxed text-ink-500">
          Found something we missed? Security reports are the one kind of message we always want.
          Contact details and the disclosure policy live in the protocol repository under{' '}
          <span className="font-mono">docs/SECURITY.md</span>. This page covers{' '}
          {FINDINGS.length} findings in total.
        </p>
      </section>
    </>
  );
}

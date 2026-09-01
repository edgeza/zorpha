'use client';

import Link from 'next/link';
import { TOKEN, FLOAT_AT_LAUNCH_PCT } from '@/lib/tokenomics';
import { formatCompact } from '@/lib/format';
import { CountUp } from '@/components/motion/CountUp';

/**
 * Hero.
 *
 * One orchestrated load sequence rather than scattered effects: badge, then
 * headline, then lede, then actions, then the stat strip. Each step is a fixed
 * offset on the same easing curve, so it reads as a single movement settling
 * instead of five independent animations. The stat values count up last,
 * because a number that resolves is the page's whole argument in miniature.
 */

const STATS = [
  { label: 'Max supply', value: TOKEN.maxSupply, sub: 'fixed, no mint', compact: true },
  { label: 'Launch float', value: FLOAT_AT_LAUNCH_PCT, sub: 'circulating day one', suffix: '%' },
  { label: 'Fee to buyback', value: 50, sub: 'bought and burned', suffix: '%' },
  { label: 'Timelock delay', value: 48, sub: 'on every admin action', suffix: 'h' },
];

export function Hero() {
  return (
    <section className="relative overflow-hidden">
      <div className="spotlight absolute inset-0 -z-10" aria-hidden="true" />
      <div className="grid-lines absolute inset-0 -z-10" aria-hidden="true" />

      <div className="shell pb-14 pt-20 sm:pb-16 sm:pt-28">
        <div className="mx-auto max-w-3xl text-center">
          <div className="animate-fade-up">
            <span className="badge-zor">
              <span className="h-1.5 w-1.5 animate-pulse-dot rounded-full bg-zor-400" />
              Live on {TOKEN.chain} testnet
            </span>
          </div>

          <h1
            className="mt-7 animate-fade-up text-4xl font-semibold leading-[1.05] tracking-tight sm:text-6xl"
            style={{ animationDelay: '60ms' }}
          >
            Track records you can
            <br className="hidden sm:block" />{' '}
            <span className="text-gradient">actually verify</span>
          </h1>

          <p
            className="lede mx-auto mt-6 max-w-2xl animate-fade-up"
            style={{ animationDelay: '120ms' }}
          >
            Zorpha runs curated vaults on {TOKEN.chain}. Every rebalance is signed by the manager
            and written onchain as a public receipt — with the price, the size, and the exact
            moment it happened. No screenshots. No edits. No quietly deleted calls.
          </p>

          <div
            className="mt-9 flex animate-fade-up flex-col items-center justify-center gap-3 sm:flex-row"
            style={{ animationDelay: '180ms' }}
          >
            <Link href="/portal" className="btn-primary w-full sm:w-auto">
              Open the portal
            </Link>
            <Link href="/protocol" className="btn w-full sm:w-auto">
              How it works
            </Link>
          </div>

          <p
            className="mt-5 animate-fade-up text-xs text-ink-500"
            style={{ animationDelay: '240ms' }}
          >
            Depositing never requires holding {TOKEN.ticker}.
          </p>
        </div>

        {/* Token facts, not price. Every number here is a contract constant. */}
        <dl
          className="mx-auto mt-16 grid max-w-4xl animate-fade-up grid-cols-2 gap-px overflow-hidden rounded-card border border-void-700 bg-void-700 sm:grid-cols-4"
          style={{ animationDelay: '300ms' }}
        >
          {STATS.map((item) => (
            <div
              key={item.label}
              className="flex flex-col justify-start bg-void-900 px-5 py-6 text-center"
            >
              <dt className="stat-label">{item.label}</dt>
              <dd className="mt-2 font-mono text-xl text-ink-100 sm:text-2xl">
                <CountUp
                  to={item.value}
                  suffix={item.suffix ?? ''}
                  format={item.compact ? (v) => formatCompact(v) : undefined}
                />
              </dd>
              <dd className="mt-1 text-2xs text-ink-500">{item.sub}</dd>
            </div>
          ))}
        </dl>
      </div>
    </section>
  );
}

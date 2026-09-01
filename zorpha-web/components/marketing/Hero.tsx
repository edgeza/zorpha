'use client';

import Link from 'next/link';
import { TOKEN, FLOAT_AT_LAUNCH_PCT } from '@/lib/tokenomics';
import { formatCompact } from '@/lib/format';
import { CountUp } from '@/components/motion/CountUp';

/**
 * Hero.
 *
 * Full-bleed atmospheric background, floating glass chip, serif display
 * headline, glass actions, trust row beneath.
 *
 * The background is generated rather than photographic. A stock image would
 * need hosting, an entry in the CSP's img-src, and art direction at every
 * breakpoint; layered gradients plus two drifting blurred blobs give the same
 * depth for a few hundred bytes and scale to any viewport.
 *
 * The row at the bottom lists the chain and standards Zorpha is actually built
 * on. It occupies the slot a partner-logo wall would, deliberately: Zorpha has
 * no agency partnerships, and putting logos there would be an outright claim
 * that it does.
 */

const STATS = [
  { label: 'Max supply', value: TOKEN.maxSupply, sub: 'fixed, no mint', compact: true },
  { label: 'Launch float', value: FLOAT_AT_LAUNCH_PCT, sub: 'circulating day one', suffix: '%' },
  { label: 'Fee to buyback', value: 50, sub: 'bought and burned', suffix: '%' },
  { label: 'Timelock delay', value: 48, sub: 'on every admin action', suffix: 'h' },
];

const BUILT_ON = [
  { label: 'Robinhood Chain', detail: 'chain 46630' },
  { label: 'ERC-4626', detail: 'vault shares' },
  { label: 'ERC-5805', detail: 'vote checkpoints' },
  { label: 'ERC-2612', detail: 'gasless approvals' },
  { label: 'Blockscout', detail: 'public explorer' },
];

function ArrowRight({ className = 'h-4 w-4' }: { className?: string }) {
  return (
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
      className={className}
      aria-hidden="true"
    >
      <path d="M5 12h14" />
      <path d="m12 5 7 7-7 7" />
    </svg>
  );
}

function Play({ className = 'h-4 w-4' }: { className?: string }) {
  return (
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
      className={className}
      aria-hidden="true"
    >
      <path d="M5 5a2 2 0 0 1 3.008-1.728l11.997 6.998a2 2 0 0 1 .003 3.458l-12 7A2 2 0 0 1 5 19z" />
    </svg>
  );
}

export function Hero() {
  return (
    // -mt-20 cancels the marketing layout's pt-20 so the aurora runs behind
    // the fixed header; the inner pt-28 then clears it for content.
    <section className="relative isolate -mt-20 flex min-h-[100svh] flex-col overflow-hidden">
      {/* ─── Background ───────────────────────────────────────────────────── */}
      <div className="aurora grain absolute inset-0 -z-20" aria-hidden="true">
        <span
          className="aurora-blob animate-drift-a"
          style={{
            top: '-18%',
            left: '-10%',
            width: '46rem',
            height: '38rem',
            background:
              'radial-gradient(circle, rgba(139,109,255,0.42) 0%, rgba(139,109,255,0) 70%)',
          }}
        />
        <span
          className="aurora-blob animate-drift-b"
          style={{
            bottom: '-24%',
            right: '-12%',
            width: '52rem',
            height: '42rem',
            background:
              'radial-gradient(circle, rgba(111,74,232,0.38) 0%, rgba(34,211,238,0.10) 55%, rgba(0,0,0,0) 72%)',
          }}
        />
      </div>
      <div className="grid-lines absolute inset-0 -z-10" aria-hidden="true" />

      {/* Fades the aurora into the page below so the hero does not end on a
          hard horizontal seam. */}
      <div
        className="absolute inset-x-0 bottom-0 -z-10 h-40 bg-gradient-to-b from-transparent to-void-950"
        aria-hidden="true"
      />

      {/* ─── Content ──────────────────────────────────────────────────────── */}
      <div className="shell flex flex-1 flex-col justify-center pb-14 pt-28 sm:pt-32">
        <div className="mx-auto max-w-3xl text-center">
          <div className="fade-in-1">
            <span className="chip-row">
              <span className="chip-label">Live</span>
              <span className="pr-1 text-sm font-medium text-white/90">
                Testnet is up on {TOKEN.chain}
              </span>
            </span>
          </div>

          <h1 className="fade-in-2 mt-7 text-[2.6rem] leading-[1.02] text-white sm:text-6xl lg:text-[4.5rem]">
            Track records you can
            <br className="hidden sm:block" /> actually verify
          </h1>

          <p className="lede fade-in-3 mx-auto mt-6 max-w-2xl text-white/70">
            Zorpha runs curated vaults on {TOKEN.chain}. Every rebalance is signed by the manager
            and written onchain as a public receipt — with the price, the size, and the exact
            moment it happened. No screenshots. No edits. No quietly deleted calls.
          </p>

          <div className="fade-in-4 mt-10 flex flex-col items-center justify-center gap-3 sm:flex-row sm:gap-4">
            <Link href="/portal" className="btn-glass w-full sm:w-auto">
              Open the portal
              <ArrowRight />
            </Link>
            <Link href="/protocol" className="btn-quiet w-full sm:w-auto">
              How it works
              <Play />
            </Link>
          </div>

          <p className="fade-in-4 mt-5 text-xs text-white/45">
            Depositing never requires holding {TOKEN.ticker}.
          </p>
        </div>

        {/* Token facts, not price. Every number is a contract constant. */}
        <dl className="fade-in-5 mx-auto mt-16 grid w-full max-w-4xl grid-cols-2 overflow-hidden rounded-[1.25rem] border border-white/10 bg-white/[0.04] backdrop-blur-md sm:grid-cols-4">
          {STATS.map((item, i) => (
            <div
              key={item.label}
              className={`flex flex-col justify-start px-5 py-6 text-center ${
                // Hairlines drawn per-cell rather than with gap-px on a
                // background, so the glass stays continuous underneath.
                i % 2 === 1 ? 'border-l border-white/10' : ''
              } ${i < 2 ? 'border-b border-white/10 sm:border-b-0' : ''} ${
                i === 2 ? 'sm:border-l sm:border-white/10' : ''
              }`}
            >
              <dt className="text-2xs uppercase tracking-[0.14em] text-white/45">{item.label}</dt>
              <dd className="mt-2 font-mono text-xl text-white sm:text-2xl">
                <CountUp
                  to={item.value}
                  suffix={item.suffix ?? ''}
                  format={item.compact ? (v) => formatCompact(v) : undefined}
                />
              </dd>
              <dd className="mt-1 text-2xs text-white/40">{item.sub}</dd>
            </div>
          ))}
        </dl>

        {/* ─── Built on ───────────────────────────────────────────────────── */}
        <div className="fade-in-5 mx-auto mt-14 w-full max-w-5xl">
          <p className="text-center text-sm text-white/45">
            Built on open standards, with nothing proprietary in the trust path
          </p>
          <ul className="mt-6 grid grid-cols-2 items-center justify-items-center gap-3 sm:grid-cols-3 md:grid-cols-5">
            {BUILT_ON.map((item) => (
              <li
                key={item.label}
                className="glass flex w-full flex-col items-center rounded-xl px-3 py-3 text-center transition-colors hover:bg-white/[0.09]"
              >
                <span className="text-xs font-medium text-white/85">{item.label}</span>
                <span className="mt-0.5 font-mono text-2xs text-white/40">{item.detail}</span>
              </li>
            ))}
          </ul>
        </div>
      </div>
    </section>
  );
}

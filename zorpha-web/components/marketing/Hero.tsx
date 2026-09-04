'use client';

import { TOKEN, FLOAT_AT_LAUNCH_PCT } from '@/lib/tokenomics';
import { formatCompact } from '@/lib/format';
import { CountUp } from '@/components/motion/CountUp';
import { PrismHero } from '@/components/ui/prism-hero';
import { isMainnet } from '@/lib/chains';

/**
 * Hero.
 *
 * The wordmark sits in front of a faceted crystal that refracts a ghost of it
 * from behind, so the brand reads as lit rather than printed. See
 * components/ui/prism-hero.tsx for how the light gets through the letterforms.
 *
 * Nothing here is fetched. The stone is procedural geometry lit by lightformers,
 * which matters beyond taste: vercel.json pins `connect-src 'self'`, so an HDRI
 * or a loaded model would be blocked in production. The old layered-gradient
 * aurora was chosen for the same reason and is now retired -- the crystal does
 * that job, and running both put two full-viewport composites on top of each
 * other for no gain.
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

export function Hero() {
  return (
    <>
      {/* -mt-20 cancels the marketing layout's pt-20 so the scene runs behind
          the fixed header; topInset then clears it for the copy. */}
      <PrismHero
        className="-mt-20"
        topInset
        word="Zorpha"
        eyebrow={`${isMainnet ? 'Live' : 'Testnet live'} on ${TOKEN.chain}`}
        description={
          <>
            <span className="block font-display text-[1.35rem] leading-snug text-ink-100 sm:text-[1.6rem]">
              Track records you can actually verify
            </span>
            <span className="mt-4 block">
              Zorpha runs curated vaults on {TOKEN.chain}. Every rebalance is signed by the manager
              and written onchain as a public receipt, with the price, the size, and the exact
              moment it happened. No screenshots. No edits. No quietly deleted calls.
            </span>
          </>
        }
        footnote={`Depositing never requires holding ${TOKEN.ticker}.`}
        meta={['Signed rebalances', 'Onchain receipts', '48h timelock']}
      />

      {/* ─── Token facts, not price. Every number is a contract constant. ─── */}
      <section className="shell pb-4 pt-16 sm:pt-20">
        <dl className="mx-auto grid w-full max-w-4xl grid-cols-2 overflow-hidden rounded-[1.25rem] border border-white/10 bg-white/[0.04] backdrop-blur-md sm:grid-cols-4">
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

        {/* ─── Built on ─────────────────────────────────────────────────── */}
        <div className="mx-auto mt-14 w-full max-w-5xl">
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
      </section>
    </>
  );
}

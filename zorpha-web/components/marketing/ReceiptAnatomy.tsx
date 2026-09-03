'use client';

import { Mono } from '@/components/ui/Primitives';
import { useInView } from '@/components/motion/Reveal';
import { ScrambleHash } from '@/components/motion/ScrambleHash';

const FIELDS: { label: string; value: string; note: string; hash?: boolean }[] = [
  {
    label: 'manager',
    value: '0x8f2a…4c19',
    note: 'The key that signed. Not a display name someone typed.',
  },
  {
    label: 'targetBps',
    value: '7000',
    note: '70% exposure requested. The intent, recorded before the fill.',
  },
  {
    label: 'navPerShare',
    value: '1.04182',
    note: 'Vault NAV at execution, computed from the oracle the vault is pinned to.',
  },
  {
    label: 'nonce',
    value: '42',
    note: 'Strictly increasing. A skipped nonce is a visible gap in the record.',
  },
  {
    label: 'commitment',
    value: '0xb617f5353dc8…18ff',
    note: 'Hash binding every field above. Change one number and it stops matching.',
    hash: true,
  },
];

/**
 * WHY THIS SAYS "ILLUSTRATIVE" ON THE PAGE
 *
 * The field values below are invented. `navPerShare` 1.04182 and manager
 * 0x8f2a…4c19 belong to no transaction, and the sibling marquee showed block
 * 1,284,551 while Robinhood Chain was at 112,141,793.
 *
 * That was unlabelled, in the one section of the site whose entire argument is
 * "do not trust a manager's summary of their own performance, read the chain".
 * Fabricated evidence under that heading does more damage than a blank space,
 * and the portal already holds the right standard -- it renders an em dash for
 * anything it cannot read and says so: "If the indexer is not running, this
 * stays empty rather than showing placeholder data."
 *
 * The marketing page now meets the same bar. The diagram is worth keeping,
 * because a labelled diagram of a receipt teaches the shape of the thing; an
 * unlabelled one just asserts a track record that does not exist yet.
 */
export function ReceiptAnatomy() {
  const { ref, inView, reduced } = useInView<HTMLDivElement>({ threshold: 0.25 });
  const animate = inView || reduced;

  return (
    <div ref={ref} className="card overflow-hidden">
      <div className="flex flex-wrap items-center justify-between gap-x-4 gap-y-2 border-b border-void-700 bg-void-850 px-5 py-3.5">
        <div className="flex items-center gap-2">
          <span
            className={`h-1.5 w-1.5 rounded-full bg-verified-400 ${reduced ? '' : 'animate-pulse-dot'}`}
          />
          <span className="font-mono text-xs text-ink-300">Rebalanced</span>
        </div>
        <span className="font-mono text-2xs text-ink-500">block 1,284,551</span>
      </div>

      {/* Fields land one after another, which is the order the vault computes
          them in, the commitment can only exist once the rest is known. */}
      <dl className="divide-hair px-5">
        {FIELDS.map((field, i) => (
          <div
            key={field.label}
            className="py-4"
            style={{
              opacity: animate ? 1 : 0,
              transform: animate ? 'none' : 'translateY(8px)',
              transition: reduced
                ? undefined
                : `opacity 420ms ease ${140 * i}ms, transform 420ms cubic-bezier(0.22,1,0.36,1) ${140 * i}ms`,
            }}
          >
            <div className="flex flex-wrap items-baseline justify-between gap-x-6 gap-y-1">
              <dt className="font-mono text-xs text-zor-300">{field.label}</dt>
              <dd className="font-mono text-sm text-ink-100">
                {field.hash ? (
                  <ScrambleHash value={field.value} className="text-verified-400" />
                ) : (
                  <Mono>{field.value}</Mono>
                )}
              </dd>
            </div>
            <p className="mt-1.5 text-xs leading-relaxed text-ink-500">{field.note}</p>
          </div>
        ))}
      </dl>

      <div className="border-t border-void-700 bg-void-850 px-5 py-3.5">
        <p className="mb-2 text-xs font-semibold leading-relaxed text-amber-300">
          Field values above are illustrative, not a real transaction. Live
          receipts are in the portal.
        </p>
        <p className="text-xs leading-relaxed text-ink-400">
          Emitted by the vault contract itself, so it exists whether or not this website does.
        </p>
      </div>
    </div>
  );
}

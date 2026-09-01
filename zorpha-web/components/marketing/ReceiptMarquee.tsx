'use client';

import { useEffect, useState } from 'react';
import { formatAddress } from '@/lib/format';

/**
 * Horizontal marquee of rebalance receipts.
 *
 * Illustrative sample data, and labelled as such on the page. The live feed
 * lives in the portal. It earns a place on the marketing page because a scrolling ledger of
 * signed instructions communicates "the chain is writing this down" faster than
 * a paragraph does.
 *
 * The track is duplicated and translated by exactly -50%, which is what makes
 * the loop seamless. `aria-hidden` on the clone keeps the duplicate out of the
 * accessibility tree, and the whole strip is hidden from assistive tech in
 * favour of the real table in the portal.
 */

type Row = { vault: string; target: string; nav: string; manager: string; nonce: number };

const SAMPLE: Row[] = [
  { vault: 'zqHOOD', target: '70%', nav: '1.04182', manager: '0x8f2ab41c9d0e4c19', nonce: 42 },
  { vault: 'zqROT', target: '20 / 80', nav: '0.99871', manager: '0x3c71de90ab2f7741', nonce: 17 },
  { vault: 'zqUSD', target: '—', nav: '1.00240', manager: '0x91b0ff23c7de5a08', nonce: 8 },
  { vault: 'zqHOOD', target: '0%', nav: '1.03994', manager: '0x8f2ab41c9d0e4c19', nonce: 41 },
  { vault: 'zqROT', target: '50 / 50', nav: '1.00113', manager: '0x3c71de90ab2f7741', nonce: 16 },
  { vault: 'zqHOOD', target: '100%', nav: '1.02760', manager: '0x8f2ab41c9d0e4c19', nonce: 40 },
];

function Cell({ row }: { row: Row }) {
  return (
    <div className="flex shrink-0 items-center gap-4 border-r border-void-700 px-5 py-3">
      <span className="h-1.5 w-1.5 shrink-0 rounded-full bg-verified-400" />
      <span className="font-mono text-2xs text-ink-200">{row.vault}</span>
      <span className="font-mono text-2xs text-ink-500">target</span>
      <span className="font-mono text-2xs text-zor-300">{row.target}</span>
      <span className="font-mono text-2xs text-ink-500">nav</span>
      <span className="font-mono text-2xs text-ink-200">{row.nav}</span>
      <span className="font-mono text-2xs text-ink-500">by</span>
      <span className="font-mono text-2xs text-ink-400">{formatAddress(row.manager)}</span>
      <span className="font-mono text-2xs text-ink-600">#{row.nonce}</span>
    </div>
  );
}

export function ReceiptMarquee() {
  const [reduced, setReduced] = useState(false);

  useEffect(() => {
    const mq = window.matchMedia('(prefers-reduced-motion: reduce)');
    setReduced(mq.matches);
    const onChange = () => setReduced(mq.matches);
    mq.addEventListener('change', onChange);
    return () => mq.removeEventListener('change', onChange);
  }, []);

  return (
    <div
      className="relative overflow-hidden border-y border-void-700 bg-void-900/60"
      aria-hidden="true"
    >
      {/* Feathered edges so rows enter and leave rather than being clipped. */}
      <div
        className="pointer-events-none absolute inset-y-0 left-0 z-10 w-24 bg-gradient-to-r from-void-950 to-transparent"
      />
      <div
        className="pointer-events-none absolute inset-y-0 right-0 z-10 w-24 bg-gradient-to-l from-void-950 to-transparent"
      />

      {reduced ? (
        <div className="flex overflow-x-auto">
          {SAMPLE.map((row, i) => (
            <Cell key={i} row={row} />
          ))}
        </div>
      ) : (
        <div className="flex w-max animate-ticker">
          {SAMPLE.map((row, i) => (
            <Cell key={`a-${i}`} row={row} />
          ))}
          {SAMPLE.map((row, i) => (
            <Cell key={`b-${i}`} row={row} />
          ))}
        </div>
      )}
    </div>
  );
}

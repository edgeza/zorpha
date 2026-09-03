'use client';

import { useEffect, useState } from 'react';
import { formatAddress } from '@/lib/format';

/**
 * Horizontal marquee of rebalance receipts.
 *
 * Illustrative sample data. That claim used to be in this comment and NOWHERE
 * on the page -- a search of the rendered text for "illustrative", "sample" or
 * "example" returned nothing, so a visitor saw invented receipts, including a
 * block height of 1,284,551 against a real chain head of 112,141,793,
 * presented as evidence. The label below is the comment made true.
 *
 * The live feed lives in the portal. It earns a place on the marketing page because a scrolling ledger of
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
  { vault: 'zqtAAPL', target: '70%', nav: '1.04182', manager: '0x8f2ab41c9d0e4c19', nonce: 42 },
  { vault: 'zqROT', target: '20 / 80', nav: '0.99871', manager: '0x3c71de90ab2f7741', nonce: 17 },
  { vault: 'zqtUSDG', target: '—', nav: '1.00240', manager: '0x91b0ff23c7de5a08', nonce: 8 },
  { vault: 'zqtAAPL', target: '0%', nav: '1.03994', manager: '0x8f2ab41c9d0e4c19', nonce: 41 },
  { vault: 'zqROT', target: '50 / 50', nav: '1.00113', manager: '0x3c71de90ab2f7741', nonce: 16 },
  { vault: 'zqtAAPL', target: '100%', nav: '1.02760', manager: '0x8f2ab41c9d0e4c19', nonce: 40 },
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
    <div className="border-y border-void-700 bg-void-900/60">
      {/*
        Deliberately OUTSIDE the aria-hidden strip below. The strip is hidden
        from assistive tech because the real table in the portal is the
        accessible version of it -- but that also meant the only thing a
        sighted user could see was invented data with nothing marking it as
        such. The label must be in the accessibility tree even though the
        rows are not.
      */}
      <p className="px-5 pt-2.5 font-mono text-2xs uppercase tracking-[0.14em] text-amber-300/90">
        Illustrative sample &middot; live receipts in the portal
      </p>
      <div className="relative overflow-hidden" aria-hidden="true">
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
    </div>
  );
}

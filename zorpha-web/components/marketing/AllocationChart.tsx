'use client';

import { ALLOCATIONS, TOKEN, tokensFor, pctFor } from '@/lib/tokenomics';
import { formatCompact } from '@/lib/format';
import { useInView } from '@/components/motion/Reveal';
import { CountUp } from '@/components/motion/CountUp';

/**
 * Supply allocation donut.
 *
 * Drawn as stroked arcs on one circle rather than pie wedges: with six segments
 * a ring reads more precisely than a filled pie, and the centre is where the
 * number people actually want lives.
 *
 * The ring draws itself on scroll by animating `stroke-dashoffset` from a full
 * circumference down to each segment's real offset. That is the composition
 * assembling, which is what the chart is about, not decoration. Under reduced
 * motion every segment renders at its final offset immediately.
 */
export function AllocationChart() {
  const { ref, inView, reduced } = useInView<HTMLDivElement>({ threshold: 0.35 });
  const animate = inView && !reduced;

  const radius = 62;
  const circumference = 2 * Math.PI * radius;
  let cursor = 0;

  const segments = ALLOCATIONS.map((a, i) => {
    const length = circumference * (a.bps / 10_000);
    const seg = {
      key: a.key,
      label: a.label,
      color: a.color,
      length,
      offset: -cursor,
      delay: 90 * i,
    };
    cursor += length;
    return seg;
  });

  return (
    <div ref={ref} className="grid gap-8 sm:grid-cols-[minmax(0,180px)_1fr] sm:items-center sm:gap-10">
      <div className="relative mx-auto w-[180px]">
        <svg
          viewBox="0 0 160 160"
          className="w-full -rotate-90"
          role="img"
          aria-label="Supply allocation by bucket"
        >
          <circle cx="80" cy="80" r={radius} fill="none" stroke="#1c1c2b" strokeWidth="16" />
          {segments.map((seg) => (
            <circle
              key={seg.key}
              cx="80"
              cy="80"
              r={radius}
              fill="none"
              stroke={seg.color}
              strokeWidth="16"
              strokeLinecap="butt"
              // Each arc is one dash of `length` followed by a gap covering the
              // rest of the circle, positioned by its own dashoffset.
              strokeDasharray={`${seg.length} ${circumference - seg.length}`}
              strokeDashoffset={animate || reduced ? seg.offset : seg.offset + seg.length}
              style={{
                transition: reduced
                  ? undefined
                  : `stroke-dashoffset 900ms cubic-bezier(0.22, 1, 0.36, 1) ${seg.delay}ms`,
                opacity: animate || reduced ? 1 : 0,
                transitionProperty: reduced ? undefined : 'stroke-dashoffset, opacity',
              }}
            />
          ))}
        </svg>

        <div className="pointer-events-none absolute inset-0 flex flex-col items-center justify-center">
          <span className="font-mono text-xl text-ink-100">
            <CountUp to={TOKEN.maxSupply} format={(v) => formatCompact(v)} />
          </span>
          <span className="mt-0.5 text-2xs uppercase tracking-[0.14em] text-ink-500">
            max supply
          </span>
        </div>
      </div>

      <ul className="flex flex-col gap-2.5">
        {ALLOCATIONS.map((a, i) => (
          <li
            key={a.key}
            className="flex items-baseline gap-3"
            style={{
              opacity: animate || reduced ? 1 : 0,
              transform: animate || reduced ? 'none' : 'translateX(-6px)',
              transition: reduced
                ? undefined
                : `opacity 500ms ease ${90 * i + 200}ms, transform 500ms cubic-bezier(0.22,1,0.36,1) ${90 * i + 200}ms`,
            }}
          >
            <span
              className="mt-1.5 h-2 w-2 shrink-0 rounded-sm"
              style={{ background: a.color }}
              aria-hidden="true"
            />
            <span className="flex-1 text-sm text-ink-300">{a.label}</span>
            <span className="font-mono text-sm text-ink-100">{pctFor(a.bps)}%</span>
            <span className="w-16 text-right font-mono text-2xs text-ink-500">
              {formatCompact(tokensFor(a.bps))}
            </span>
          </li>
        ))}
      </ul>
    </div>
  );
}

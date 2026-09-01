'use client';

import { supplyCurve, TOKEN } from '@/lib/tokenomics';
import { formatCompact } from '@/lib/format';
import { useInView } from '@/components/motion/Reveal';

/**
 * Circulating-supply curve over five years.
 *
 * Deliberately plotted as an area on a linear axis with the max-supply ceiling
 * drawn in. A log axis, or one rebased to "percent of float", would flatter the
 * shape; the point of this chart is to make the size of each unlock step
 * obvious, including the year-one cliff.
 *
 * The line draws itself left to right on scroll via `stroke-dasharray`, and the
 * year markers land behind it. That mirrors how the schedule is actually
 * read, forward through time, rather than being decoration.
 */
export function SupplyCurve() {
  const { ref, inView, reduced } = useInView<HTMLElement>({ threshold: 0.3 });
  const animate = inView || reduced;

  const points = supplyCurve();
  const w = 640;
  const h = 220;
  const padL = 8;
  const padB = 26;
  const padT = 12;

  const maxY = TOKEN.maxSupply;
  const x = (i: number) => padL + (i / (points.length - 1)) * (w - padL * 2);
  const y = (v: number) => padT + (1 - v / maxY) * (h - padT - padB);

  const line = points.map((p, i) => `${i === 0 ? 'M' : 'L'} ${x(i)} ${y(p.circulating)}`).join(' ');
  const area = `${line} L ${x(points.length - 1)} ${y(0)} L ${x(0)} ${y(0)} Z`;

  // Generous over-estimate of path length; exactness is unnecessary because the
  // dash only has to fully cover the stroke before it retracts.
  const pathLen = w * 1.6;

  return (
    <figure ref={ref} className="card-pad">
      <figcaption className="flex flex-wrap items-baseline justify-between gap-3">
        <span className="eyebrow">Circulating supply, years 0&ndash;5</span>
        <span className="font-mono text-2xs text-ink-500">
          ceiling {formatCompact(TOKEN.maxSupply)} {TOKEN.symbol}
        </span>
      </figcaption>

      <svg
        viewBox={`0 0 ${w} ${h}`}
        className="mt-5 w-full"
        role="img"
        aria-label="Circulating supply projection over five years"
      >
        <defs>
          <linearGradient id="supply-fill" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stopColor="#8b6dff" stopOpacity="0.35" />
            <stop offset="100%" stopColor="#8b6dff" stopOpacity="0.02" />
          </linearGradient>
        </defs>

        {[0.25, 0.5, 0.75, 1].map((f) => (
          <g key={f}>
            <line
              x1={padL}
              x2={w - padL}
              y1={y(maxY * f)}
              y2={y(maxY * f)}
              stroke="#1c1c2b"
              strokeWidth="1"
              strokeDasharray={f === 1 ? '4 4' : undefined}
            />
            <text x={padL + 4} y={y(maxY * f) - 5} className="fill-ink-500" fontSize="9">
              {formatCompact(maxY * f)}
            </text>
          </g>
        ))}

        <path
          d={area}
          fill="url(#supply-fill)"
          style={{
            opacity: animate ? 1 : 0,
            transition: reduced ? undefined : 'opacity 900ms ease 500ms',
          }}
        />

        <path
          d={line}
          fill="none"
          stroke="#a48dff"
          strokeWidth="2"
          strokeLinejoin="round"
          strokeDasharray={pathLen}
          strokeDashoffset={animate ? 0 : pathLen}
          style={{
            transition: reduced
              ? undefined
              : 'stroke-dashoffset 1500ms cubic-bezier(0.33, 1, 0.68, 1)',
          }}
        />

        {points.map((p, i) => (
          <g
            key={p.year}
            style={{
              opacity: animate ? 1 : 0,
              transition: reduced ? undefined : `opacity 400ms ease ${260 * i + 300}ms`,
            }}
          >
            <circle
              cx={x(i)}
              cy={y(p.circulating)}
              r="3"
              fill="#06060a"
              stroke="#a48dff"
              strokeWidth="1.5"
            />
            <text x={x(i)} y={h - 8} textAnchor="middle" className="fill-ink-500" fontSize="10">
              Y{p.year}
            </text>
          </g>
        ))}
      </svg>

      <div className="mt-4 grid grid-cols-2 gap-4 border-t border-void-700 pt-4 sm:grid-cols-3">
        {[0, 1, 4].map((year) => {
          const p = points[year];
          return (
            <div key={year}>
              <div className="stat-label">Year {year}</div>
              <div className="mt-1 font-mono text-sm text-ink-200">
                {formatCompact(p.circulating)}{' '}
                <span className="text-ink-500">
                  ({((p.circulating / maxY) * 100).toFixed(0)}%)
                </span>
              </div>
            </div>
          );
        })}
      </div>

      <p className="mt-4 text-xs leading-relaxed text-ink-500">
        Modelled from the contract schedules, not from a plan. Ecosystem emissions are drawn on a
        straight line because that is the maximum they can be. Each season needs a governance
        vote, so the real curve sits at or below this one.
      </p>
    </figure>
  );
}

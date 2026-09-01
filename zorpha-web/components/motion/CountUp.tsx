'use client';

import { useEffect, useRef, useState } from 'react';
import { useInView } from './Reveal';

/**
 * Counts a number up when it scrolls into view.
 *
 * The server renders the FINAL value, so the page is correct before any JS runs
 * and search engines never index a zero. The count only starts once mounted and
 * in view, and is skipped entirely under `prefers-reduced-motion`.
 */
export function CountUp({
  to,
  duration = 1100,
  decimals = 0,
  prefix = '',
  suffix = '',
  format,
  className = '',
}: {
  to: number;
  duration?: number;
  decimals?: number;
  prefix?: string;
  suffix?: string;
  /** Overrides plain numeric formatting (e.g. compact notation). */
  format?: (value: number) => string;
  className?: string;
}) {
  const { ref, inView, reduced } = useInView<HTMLSpanElement>();
  const [value, setValue] = useState(to);
  const started = useRef(false);

  useEffect(() => {
    if (reduced || !inView || started.current) return;
    started.current = true;

    setValue(0);
    let frame = 0;
    const start = performance.now();

    const tick = (now: number) => {
      const t = Math.min(1, (now - start) / duration);
      // easeOutExpo: fast commit, gentle settle. Reads as a value resolving
      // rather than a slot machine.
      const eased = t === 1 ? 1 : 1 - Math.pow(2, -10 * t);
      setValue(to * eased);
      if (t < 1) frame = requestAnimationFrame(tick);
    };

    frame = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(frame);
  }, [inView, reduced, to, duration]);

  const text = format
    ? format(value)
    : value.toLocaleString('en-US', {
        minimumFractionDigits: decimals,
        maximumFractionDigits: decimals,
      });

  return (
    <span ref={ref} className={className}>
      {prefix}
      {text}
      {suffix}
    </span>
  );
}

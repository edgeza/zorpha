'use client';

import { useEffect, useRef, useState } from 'react';
import { useInView } from './Reveal';

const HEX = '0123456789abcdef';

/**
 * Settles a hex string into place, character by character, left to right.
 *
 * This is the one deliberate flourish on the marketing site, and it earns its
 * place by dramatising the actual mechanism: a commitment hash being computed
 * over a receipt's fields. It is not applied to prose, headings, or any number
 * a reader might try to read while it moves.
 *
 * The final value is rendered on the server and restored the instant the
 * animation ends, so the text is never wrong at rest, and the whole effect is
 * skipped under `prefers-reduced-motion`.
 */
export function ScrambleHash({
  value,
  className = '',
  duration = 1400,
}: {
  value: string;
  className?: string;
  duration?: number;
}) {
  const { ref, inView, reduced } = useInView<HTMLSpanElement>();
  const [display, setDisplay] = useState(value);
  const started = useRef(false);

  useEffect(() => {
    if (reduced || !inView || started.current) return;
    started.current = true;

    // Only scramble the hex body; keep any 0x prefix and ellipsis fixed so the
    // string never changes width.
    const chars = value.split('');
    const mutable = chars.map((c) => HEX.includes(c.toLowerCase()));
    const total = mutable.filter(Boolean).length;
    if (total === 0) return;

    let frame = 0;
    const start = performance.now();

    const tick = (now: number) => {
      const t = Math.min(1, (now - start) / duration);
      const settledCount = Math.floor(t * total);

      let seen = 0;
      const next = chars.map((c, i) => {
        if (!mutable[i]) return c;
        seen++;
        if (seen <= settledCount) return c;
        return HEX[Math.floor(Math.random() * HEX.length)];
      });

      setDisplay(next.join(''));
      if (t < 1) {
        frame = requestAnimationFrame(tick);
      } else {
        setDisplay(value);
      }
    };

    frame = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(frame);
  }, [inView, reduced, value, duration]);

  return (
    <span ref={ref} className={className}>
      {display}
    </span>
  );
}

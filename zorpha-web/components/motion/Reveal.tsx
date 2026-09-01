'use client';

import { useEffect, useRef, useState, type ReactNode } from 'react';

/**
 * Scroll-triggered reveal.
 *
 * Two rules this follows that most implementations get wrong:
 *
 *  1. Content is NEVER hidden by default. The hidden state is applied by JS
 *     after mount, so a failed hydration, a crawler, or a reader with scripts
 *     off sees the finished page rather than a blank column. `data-reveal` is
 *     only ever set to "hidden" from the effect.
 *
 *  2. `prefers-reduced-motion` is checked before arming anything at all. Under
 *     that setting no observer is created and no transition is applied — the
 *     global CSS override alone would still leave elements briefly transparent.
 */
export function Reveal({
  children,
  delay = 0,
  y = 16,
  className = '',
  as: Tag = 'div',
  once = true,
}: {
  children: ReactNode;
  /** Stagger offset in ms. */
  delay?: number;
  /** Travel distance in px. */
  y?: number;
  className?: string;
  as?: 'div' | 'section' | 'li' | 'span';
  once?: boolean;
}) {
  const ref = useRef<HTMLElement>(null);
  const [state, setState] = useState<'idle' | 'hidden' | 'shown'>('idle');

  useEffect(() => {
    const node = ref.current;
    if (!node) return;

    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
      setState('shown');
      return;
    }

    // Already in view on first paint (above the fold): show immediately so the
    // top of the page never animates in behind the reader.
    const rect = node.getBoundingClientRect();
    if (rect.top < window.innerHeight * 0.92) {
      setState('shown');
      return;
    }

    setState('hidden');

    const observer = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          if (entry.isIntersecting) {
            setState('shown');
            if (once) observer.unobserve(entry.target);
          } else if (!once) {
            setState('hidden');
          }
        }
      },
      { rootMargin: '0px 0px -12% 0px', threshold: 0.08 },
    );

    observer.observe(node);
    return () => observer.disconnect();
  }, [once]);

  const hidden = state === 'hidden';

  return (
    <Tag
      // @ts-expect-error -- polymorphic ref across the allowed tag union
      ref={ref}
      className={className}
      style={{
        opacity: hidden ? 0 : 1,
        transform: hidden ? `translate3d(0, ${y}px, 0)` : 'translate3d(0, 0, 0)',
        transition:
          state === 'idle'
            ? undefined
            : `opacity 620ms cubic-bezier(0.22, 1, 0.36, 1) ${delay}ms, transform 620ms cubic-bezier(0.22, 1, 0.36, 1) ${delay}ms`,
        willChange: state === 'hidden' ? 'opacity, transform' : undefined,
      }}
    >
      {children}
    </Tag>
  );
}

/**
 * Reports whether the element has entered the viewport, without touching its
 * styling. For charts that animate their own internals.
 */
export function useInView<T extends Element>(options?: IntersectionObserverInit) {
  const ref = useRef<T>(null);
  const [inView, setInView] = useState(false);
  const [reduced, setReduced] = useState(false);

  useEffect(() => {
    const node = ref.current;
    if (!node) return;

    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
      setReduced(true);
      setInView(true);
      return;
    }

    const observer = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          if (entry.isIntersecting) {
            setInView(true);
            observer.unobserve(entry.target);
          }
        }
      },
      { threshold: 0.2, ...options },
    );
    observer.observe(node);
    return () => observer.disconnect();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  return { ref, inView, reduced };
}

'use client';

import * as React from 'react';
import dynamic from 'next/dynamic';
import { motion, useAnimationControls, useReducedMotion } from 'motion/react';

/**
 * PrismHero -- a faceted crystal behind the wordmark, throwing light through it.
 *
 * WHY THE WORD IS DOM AND NOT PAINTED INTO THE SCENE
 *
 * The upstream component draws its headline to a 2048x640 canvas and hangs it on
 * a plane inside the scene, which is what let the crystal sit in FRONT and
 * refract it. Putting the prism behind the text removes that reason entirely --
 * a texture in front of the stone gains nothing from being a texture, and costs
 * a great deal: a canvas-baked wordmark is invisible to crawlers and to screen
 * readers, resolution-locked, and re-baked on every webfont load.
 *
 * So the word is a real <h1>. It renders on the server, it is selectable, it is
 * announced, and it is crisp at any device pixel ratio.
 *
 * HOW "SHINE THROUGH" IS DONE
 *
 * Two stacked copies of the word:
 *
 *   1. the base, held a little under full opacity, so the stone behind is
 *      genuinely visible *through* the glyphs. This is the effect proper, and it
 *      works everywhere because it is nothing but alpha.
 *   2. a bloom pass in `mix-blend-mode: screen`, so a facet sitting behind a
 *      letter drives that letter toward white and the stone reads as lighting
 *      the word rather than merely sitting behind it.
 *
 * The bloom is the enhancement, not the mechanism. A blended element composites
 * against its backdrop only within its own stacking context, and the entrance
 * animation puts `will-change: opacity` on an ancestor while it runs -- which
 * creates one. So for the first second the bloom is inert and only the alpha
 * shows; it engages when the springs settle and motion drops `will-change`.
 * That is a deliberate, graceful degradation, and it is why the legibility of
 * the wordmark rests on layer 1 alone. Do not "simplify" this by moving the
 * base colour into the blended layer.
 */

const PrismScene = dynamic(() => import('./prism-scene'), {
  ssr: false,
  // No skeleton: the section already paints `background`, so the canvas fading
  // in over a matching ground is invisible rather than a flash of empty box.
  loading: () => null,
});

/** Springs rather than duration curves -- the settle is what reads as costly. */
const ENTER = {
  hidden: { opacity: 0, y: 18 },
  show: {
    opacity: 1,
    y: 0,
    transition: { type: 'spring' as const, stiffness: 96, damping: 17, mass: 0.9 },
  },
};

const GROUP = {
  hidden: {},
  show: { transition: { staggerChildren: 0.11, delayChildren: 0.15 } },
};

export interface PrismHeroProps {
  eyebrow?: React.ReactNode;
  /** The wordmark. Rendered as a real <h1>, with the prism behind it. */
  word?: string;
  /** Screen-reader and <title>-style expansion, when the wordmark alone is not a sentence. */
  wordLabel?: string;
  description?: React.ReactNode;
  action?: React.ReactNode;
  secondaryAction?: React.ReactNode;
  footnote?: React.ReactNode;
  /** Small facts strip along the bottom. */
  meta?: string[];
  /** How much of the stone shows through the glyphs. 0 opaque, 1 ghostly. */
  shine?: number;
  /** Strength of the chromatic split. 0.2 subtle, 0.8 heavy. */
  dispersion?: number;
  /** Glass tint. Keep it close to white for a neutral crystal. */
  tint?: string;
  /** How strongly the stone refracts a ghost of the word behind it. 0 disables. */
  echoOpacity?: number;
  background?: string;
  foreground?: string;
  accent?: string;
  /** CSS font-family for the refracted echo; the DOM wordmark uses `font-display`. */
  displayFont?: string;
  /** Pin progress and ignore scroll -- for covers and thumbnails. */
  staticProgress?: number;
  /** Extra objects rendered inside the R3F canvas. */
  sceneChildren?: React.ReactNode;
  /** Adds top padding so the copy clears a fixed site header. */
  topInset?: boolean;
  className?: string;
  children?: React.ReactNode;
}

export function PrismHero({
  eyebrow,
  word = 'Zorpha',
  wordLabel,
  description,
  action,
  secondaryAction,
  footnote,
  meta,
  shine = 0.24,
  dispersion = 0.42,
  tint = '#ffffff',
  echoOpacity = 0.28,
  background = '#06060a',
  foreground = '#f6f6fb',
  accent = '#a48dff',
  displayFont = "var(--font-display), ui-serif, Charter, Georgia, serif",
  staticProgress,
  sceneChildren,
  topInset = false,
  className,
  children,
}: PrismHeroProps) {
  const sectionRef = React.useRef<HTMLDivElement>(null);
  const railRef = React.useRef<HTMLDivElement>(null);
  const progress = React.useRef(0);

  const [reducedMotion, setReducedMotion] = React.useState(false);
  const [ready, setReady] = React.useState(false);
  const [onScreen, setOnScreen] = React.useState(true);
  const prefersReduced = useReducedMotion();
  const controls = useAnimationControls();

  const isStatic = staticProgress !== undefined;

  // Transmission is the most expensive thing on the page; there is no reason to
  // keep paying for it once the hero has scrolled away.
  React.useEffect(() => {
    const el = sectionRef.current;
    if (!el || typeof IntersectionObserver === 'undefined') return;
    const io = new IntersectionObserver(([entry]) => setOnScreen(entry.isIntersecting), {
      rootMargin: '120px',
    });
    io.observe(el);
    return () => io.disconnect();
  }, []);

  // The entrance is decided after hydration, never during render: reading
  // `document.hidden` (or the reduced-motion hook) while rendering diverges from
  // the server output and trips a hydration mismatch. rAF is also throttled in
  // hidden tabs, which would otherwise strand the springs mid-flight and reveal
  // a half-faded hero when the tab regains focus.
  React.useEffect(() => {
    if (prefersReduced || document.hidden) {
      controls.set('show');
      return;
    }
    controls.start('show');
  }, [controls, prefersReduced]);

  React.useEffect(() => {
    const raf = requestAnimationFrame(() => setReady(true));
    return () => cancelAnimationFrame(raf);
  }, []);

  React.useEffect(() => {
    const mq = window.matchMedia('(prefers-reduced-motion: reduce)');
    const apply = () => setReducedMotion(mq.matches);
    apply();
    mq.addEventListener('change', apply);
    return () => mq.removeEventListener('change', apply);
  }, []);

  React.useEffect(() => {
    const paint = (p: number) => {
      progress.current = p;
      if (railRef.current) railRef.current.style.transform = `scaleX(${p})`;
    };

    if (staticProgress !== undefined) {
      paint(Math.min(1, Math.max(0, staticProgress)));
      return;
    }
    if (reducedMotion) {
      paint(0);
      return;
    }

    // Progress is how far the hero has scrolled OUT of view, not how far through
    // a tall pinned section we are. The upstream component used a 260vh section
    // with a sticky stage, which would have pushed the token stats and the
    // standards row two and a half viewports down the landing page. This keeps
    // the page exactly as long as it is today and still drives the spin.
    let raf = 0;
    const update = () => {
      raf = 0;
      const el = sectionRef.current;
      if (!el) return;
      const rect = el.getBoundingClientRect();
      const span = rect.height || 1;
      paint(Math.min(1, Math.max(0, -rect.top / span)));
    };
    const onScroll = () => {
      if (!raf) raf = requestAnimationFrame(update);
    };

    update();
    window.addEventListener('scroll', onScroll, { passive: true });
    window.addEventListener('resize', onScroll);
    return () => {
      if (raf) cancelAnimationFrame(raf);
      window.removeEventListener('scroll', onScroll);
      window.removeEventListener('resize', onScroll);
    };
  }, [reducedMotion, staticProgress]);

  // Shared by both copies of the wordmark, so they cannot drift apart.
  const wordType =
    'font-display font-medium leading-[0.86] tracking-[-0.03em] ' +
    'text-[clamp(4.25rem,17vw,13rem)]';

  return (
    <section
      ref={sectionRef}
      // `isolate` keeps the bloom pass compositing against the canvas inside
      // this section rather than against the whole page.
      className={['relative isolate flex min-h-[100svh] flex-col overflow-hidden', className]
        .filter(Boolean)
        .join(' ')}
      style={{ background }}
    >
      {/* ─── Scene ───────────────────────────────────────────────────────── */}
      <div
        aria-hidden
        className="absolute inset-0 z-0 transition-opacity duration-[1200ms] ease-out"
        style={{ opacity: ready ? 1 : 0 }}
      >
        <PrismScene
          word={word}
          background={background}
          echoColor={foreground}
          echoOpacity={echoOpacity}
          displayFont={displayFont}
          moteColor={accent}
          tint={tint}
          dispersion={dispersion}
          progress={progress}
          reducedMotion={reducedMotion}
          // Tuned against the rendered page, not guessed: the copy column puts
          // the wordmark a little above the band's centre, and the stone has to
          // sit behind the WORD rather than behind the whole section.
          lift={0.46}
          active={onScreen}
          sceneChildren={sceneChildren}
        />
      </div>

      {/* ─── Vignette + grain ────────────────────────────────────────────── */}
      <div
        aria-hidden
        className="pointer-events-none absolute inset-0 z-10"
        style={{
          background: `radial-gradient(120% 90% at 50% 42%, transparent 38%, ${background} 100%)`,
        }}
      />
      <div
        aria-hidden
        className="pointer-events-none absolute inset-0 z-10 opacity-[0.16] mix-blend-overlay"
        style={{
          backgroundImage:
            "url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='140' height='140'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.85' numOctaves='3'/%3E%3C/filter%3E%3Crect width='140' height='140' filter='url(%23n)' opacity='0.5'/%3E%3C/svg%3E\")",
        }}
      />
      {/* Legibility scrim, and the seam fade in the same layer.
          The stone is bright and it moves, so on some frames a white facet
          lands squarely behind the description. Text over a live render needs a
          guaranteed floor of contrast rather than a hope that the geometry stays
          out of the way -- so everything below the wordmark sits on a ramp down
          to the page colour, which also fades the hero into the section under
          it instead of ending on a hard horizontal seam. */}
      <div
        aria-hidden
        className="pointer-events-none absolute inset-0 z-10"
        style={{
          // Held fully clear down to 46%, which is where the wordmark ends.
          // Ramping from 34% instead dimmed the stone's own midriff and cost
          // most of the effect to protect text that was not there yet.
          background:
            `linear-gradient(to bottom, transparent 46%, ${background}b3 63%, ` +
            `${background}f2 80%, ${background} 100%)`,
        }}
      />

      {/* ─── Copy ────────────────────────────────────────────────────────── */}
      <motion.div
        variants={GROUP}
        initial="hidden"
        animate={controls}
        className={`relative z-20 flex flex-1 flex-col px-5 sm:px-10 ${
          topInset ? 'pb-10 pt-28 sm:pb-14 sm:pt-32' : 'py-10 sm:py-14'
        }`}
      >
        {eyebrow && (
          <motion.div variants={ENTER} className="flex items-center justify-center gap-3">
            {/* The rules are dropped below `sm`. At 375px they cost the label
                enough width to wrap mid-phrase, and a two-line eyebrow with a
                dash hanging off the first line reads as a mistake. */}
            <span
              aria-hidden
              className="hidden h-px w-8 sm:block"
              style={{ background: accent, opacity: 0.7 }}
            />
            <span
              className="text-center font-mono text-[10px] uppercase tracking-[0.32em]"
              style={{ color: accent }}
            >
              {eyebrow}
            </span>
            <span
              aria-hidden
              className="hidden h-px w-8 sm:block"
              style={{ background: accent, opacity: 0.7 }}
            />
          </motion.div>
        )}

        <div aria-hidden className="flex-1" />

        {/* The wordmark, with the stone directly behind it. */}
        <motion.div variants={ENTER} className="relative mx-auto w-full text-center">
          <h1
            aria-label={wordLabel}
            className={`relative block ${wordType}`}
            style={{
              color: foreground,
              // Held under 1 so the crystal is visible through the letterforms.
              opacity: 1 - shine * 0.62,
              // A soft accent bloom, so the word looks lit by the stone even on
              // the frames where no facet happens to sit behind a glyph.
              textShadow: `0 0 70px ${accent}4d, 0 0 140px ${accent}26`,
            }}
          >
            {word}
          </h1>
          {/* Bloom pass. Inert while the entrance runs; see the file header.
              Deliberately a SIBLING of the heading rather than a child: nested
              inside it, this second copy made the heading's text content read
              "ZorphaZorpha" for anything that walks the DOM rather than the
              accessibility tree -- crawlers included. aria-hidden fixes the
              screen reader, not the document. */}
          <span
            aria-hidden
            className={`pointer-events-none absolute inset-0 block ${wordType}`}
            style={{
              color: foreground,
              mixBlendMode: 'screen',
              opacity: shine * 0.85,
            }}
          >
            {word}
          </span>
        </motion.div>

        <div className="mx-auto mt-7 w-full max-w-2xl text-center">
          {description && (
            <motion.p
              variants={ENTER}
              className="mx-auto max-w-xl text-[15px] leading-relaxed sm:text-base"
              style={{ color: foreground, opacity: 0.68 }}
            >
              {description}
            </motion.p>
          )}

          {(action || secondaryAction) && (
            <motion.div
              variants={ENTER}
              className="mt-8 flex flex-col items-center justify-center gap-3 sm:flex-row sm:gap-4"
            >
              {action}
              {secondaryAction}
            </motion.div>
          )}

          {footnote && (
            <motion.p
              variants={ENTER}
              className="mt-5 text-xs"
              style={{ color: foreground, opacity: 0.45 }}
            >
              {footnote}
            </motion.p>
          )}
        </div>

        <div aria-hidden className="flex-1" />

        {(meta?.length || !isStatic) && (
          <motion.div
            variants={ENTER}
            className="mt-10 flex flex-wrap items-center justify-between gap-4"
          >
            <div className="hidden flex-wrap items-center gap-x-5 gap-y-2 sm:flex">
              {meta?.map((m) => (
                <span
                  key={m}
                  className="font-mono text-[10px] uppercase tracking-[0.22em]"
                  style={{ color: foreground, opacity: 0.55 }}
                >
                  {m}
                </span>
              ))}
            </div>

            {!isStatic && (
              <div className="h-px w-24 overflow-hidden" style={{ background: `${foreground}22` }}>
                <div
                  ref={railRef}
                  className="h-full origin-left"
                  style={{ background: accent, transform: 'scaleX(0)' }}
                />
              </div>
            )}
          </motion.div>
        )}

        {children}
      </motion.div>
    </section>
  );
}

export default PrismHero;

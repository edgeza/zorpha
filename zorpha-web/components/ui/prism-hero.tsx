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
 * The word is cut from glass -- see GlassWord below for the four layers and
 * what each one is for.
 *
 * The first attempt was simply a translucent copy of the word plus a
 * screen-blended bloom. It let the stone through, but a semi-transparent white
 * word does not read as a material: it reads as faded type, and over a bright
 * facet it washed out to nothing. The blend was also unreliable, because a
 * blended element composites only within its own stacking context and the
 * entrance animation puts `will-change` on an ancestor while it runs. Glass
 * gets the same transparency from a gradient that is opaque at the rims, so the
 * letterforms hold their shape whatever passes behind them.
 */

const PrismScene = dynamic(() => import('./prism-scene'), {
  ssr: false,
  // No skeleton: the section already paints `background`, so the canvas fading
  // in over a matching ground is invisible rather than a flash of empty box.
  loading: () => null,
});

/**
 * The wordmark, cut from glass.
 *
 * Four layers, and every one earns its place. A single translucent <span> was
 * the first attempt: it let the stone through, but a semi-transparent white word
 * does not read as a material -- it reads as faded type, and over a bright
 * facet it washed out to nothing.
 *
 *   caustic   a heavily blurred copy in the accent, behind everything: the
 *             light the slab throws onto the page around itself.
 *   body      a vertical gradient clipped to the glyphs. Near-opaque at the top
 *             and bottom rims where a glass edge gathers light, dropping
 *             through the waist so the crystal shows in the middle of each
 *             letter. This is the glass, and it is what makes the word legible.
 *   sweep     a narrow specular band travelling across the letterforms. Static
 *             glass looks like plastic; it is the moving highlight that reads
 *             as polish.
 *   edge      a hairline stroke, so the letterforms keep a defined boundary
 *             whatever the scene does behind them.
 *
 * WHAT IS NOT HERE, AND WHY
 *
 * A `backdrop-filter` layer clipped to the text, to blur and saturate the prism
 * genuinely inside the glyphs. It was implemented and it does not work: the
 * engine painted the filter over the element's whole box, so the wordmark sat
 * in a pale blurred rectangle a third of the hero wide. `background-clip: text`
 * clips a background; it does not clip a backdrop. Removed rather than left
 * behind a flag, because a knob defaulting to broken is worse than no knob.
 */
function GlassWord({
  word,
  type,
  accent,
  label,
}: {
  word: string;
  type: string;
  accent: string;
  label?: string;
}) {
  const clip: React.CSSProperties = {
    WebkitBackgroundClip: 'text',
    backgroundClip: 'text',
    color: 'transparent',
  };

  return (
    <span className="relative block">
      {/* caustic */}
      <span
        aria-hidden
        className={`absolute inset-0 block select-none ${type}`}
        style={{ color: accent, filter: 'blur(34px)', opacity: 0.5 }}
      >
        {word}
      </span>

      {/* body -- the real heading, and the ONLY copy of the word that is not
          aria-hidden. The decorative layers are siblings of it, never children:
          nested inside, they made the heading's text content read
          "ZorphaZorphaZorphaZorpha" for anything walking the DOM rather than
          the accessibility tree, crawlers included. */}
      <h1
        aria-label={label}
        className={`relative block ${type}`}
        style={{
          ...clip,
          backgroundImage:
            'linear-gradient(176deg,' +
            'rgba(255,255,255,1) 0%,' +
            'rgba(252,251,255,0.97) 14%,' +
            'rgba(233,229,255,0.93) 33%,' +
            'rgba(210,199,255,0.87) 50%,' +
            'rgba(230,223,255,0.94) 67%,' +
            'rgba(253,252,255,0.98) 88%,' +
            'rgba(255,255,255,1) 100%)',
          // Two shadows, not a glow: a tight dark one to seat the slab against
          // the scene behind it, and a wide accent one for the bloom.
          filter: `drop-shadow(0 2px 2px rgba(6,6,10,0.7)) drop-shadow(0 0 52px ${accent}59)`,
        }}
      >
        {word}
      </h1>

      {/* sweep */}
      <span
        aria-hidden
        className={`animate-glass-sweep absolute inset-0 block select-none motion-reduce:animate-none ${type}`}
        style={{
          ...clip,
          backgroundImage:
            'linear-gradient(100deg, transparent 38%, rgba(255,255,255,0.92) 50%, transparent 62%)',
          backgroundSize: '220% 100%',
          backgroundRepeat: 'no-repeat',
        }}
      >
        {word}
      </span>

      {/* edge */}
      <span
        aria-hidden
        className={`absolute inset-0 block select-none ${type}`}
        style={{
          color: 'transparent',
          WebkitTextStrokeWidth: '0.7px',
          WebkitTextStrokeColor: 'rgba(255,255,255,0.5)',
        }}
      >
        {word}
      </span>
    </span>
  );
}

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
  dispersion = 0.42,
  tint = '#ffffff',
  echoOpacity = 0,
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
  // leading MUST leave room for the glyphs' full ink height.
  //
  // At leading-[0.86] the line box was shorter than the type, so ascenders and
  // descenders overflowed it -- and since `background-clip: text` clips a
  // background that is only ever painted across the element's own box, every
  // overflowing part had nothing to clip and came out unpainted. That showed up
  // as the Z, the p and the h being sliced off with stray marks where the box
  // edge cut them: exactly the three letters in "Zorpha" that reach furthest.
  //
  // Tight leading bought nothing here anyway. This is a single line, so
  // line-height only sets the box height; it does not tighten the letterforms.
  const wordType =
    'font-display font-medium leading-[1.06] tracking-[-0.03em] ' +
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
          lift={0.78}
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
          // Deliberately late and gentle. An earlier, heavier ramp from 34%
          // was half the reason the stone stopped looking like glass -- it ate
          // the lower facets to protect copy that mostly is not there. It now
          // holds fully clear to 58% and never fully opaque until the very
          // bottom, where it doubles as the seam fade into the next section.
          background:
            `linear-gradient(to bottom, transparent 58%, ${background}80 74%, ` +
            `${background}d9 88%, ${background} 100%)`,
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

        {/* The wordmark, cut from glass, with the stone directly behind it.
            Every decorative copy of the word lives inside GlassWord and is
            aria-hidden, so the heading's own text content stays exactly
            "Zorpha" for anything that walks the DOM rather than the
            accessibility tree -- crawlers included. */}
        <motion.div variants={ENTER} className="relative mx-auto w-full text-center">
          <GlassWord word={word} type={wordType} accent={accent} label={wordLabel} />
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

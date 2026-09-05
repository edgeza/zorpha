import Image from 'next/image';
import Link from 'next/link';
import type { ReactNode } from 'react';

/**
 * The Zorpha mark: a faceted prism.
 *
 * Sized by HEIGHT with width:auto, because the artwork is taller than it is
 * wide (101x115). Forcing it into a square box -- which the previous `h-7 w-7`
 * did -- would either squash it or letterbox it off-centre.
 *
 * Served from /zorpha-mark.png, which is public/logo_trans.png cropped to its
 * artwork. The original carries transparent padding across 60% of its width, so
 * used directly the mark rendered at under half the size of its box and sat
 * visibly left of centre next to the wordmark. Regenerate with:
 *
 *   npm --prefix zorpha-web run logo:crop     (from the repo root)
 *   npm run logo:crop                         (from zorpha-web/)
 *
 * `priority` because this is above the fold on every page and is the one image
 * a visitor should never watch load in.
 */
export function Logo({ className = 'h-7 w-auto' }: { className?: string }) {
  return (
    <Image
      src="/zorpha-mark.png"
      alt=""
      width={101}
      height={115}
      priority
      className={className}
      aria-hidden="true"
    />
  );
}

export function Wordmark({ href = '/' }: { href?: string }) {
  return (
    <Link href={href} className="group flex items-center gap-2.5" aria-label="Zorpha home">
      <Logo />
      <span className="font-display text-lg font-semibold tracking-tight text-ink-100">
        Zorpha
      </span>
    </Link>
  );
}

export function SectionHeading({
  eyebrow,
  title,
  lede,
  align = 'left',
}: {
  eyebrow?: string;
  title: string;
  lede?: string;
  align?: 'left' | 'center';
}) {
  return (
    <div className={align === 'center' ? 'mx-auto max-w-2xl text-center' : 'max-w-2xl'}>
      {eyebrow ? <div className="eyebrow mb-3">{eyebrow}</div> : null}
      <h2 className="text-2xl font-semibold tracking-tight sm:text-3xl">{title}</h2>
      {lede ? <p className="lede mt-4">{lede}</p> : null}
    </div>
  );
}

export function Stat({
  label,
  value,
  sub,
  tone = 'default',
  size = 'lg',
}: {
  label: string;
  value: ReactNode;
  sub?: ReactNode;
  tone?: 'default' | 'verified' | 'warn';
  /**
   * `lg` suits short numerics. Use `md` for word values: "Testnet" at the
   * large mono size overflows a quarter-width card on narrow viewports.
   */
  size?: 'lg' | 'md';
}) {
  const valueTone =
    tone === 'verified'
      ? 'text-verified-400'
      : tone === 'warn'
        ? 'text-amber-400'
        : 'text-ink-100';
  const valueSize = size === 'md' ? 'font-mono text-lg' : 'stat-value';
  return (
    <div className="card-pad">
      <div className="stat-label">{label}</div>
      <div className={`mt-2 break-words ${valueSize} ${valueTone}`}>{value}</div>
      {sub ? <div className="mt-2 text-xs leading-relaxed text-ink-400">{sub}</div> : null}
    </div>
  );
}

export function EmptyState({
  title,
  body,
  action,
  headingLevel = 2,
}: {
  title: string;
  body: string;
  action?: ReactNode;
  /**
   * Heading level for the empty-state title. See the note on `Callout`: this
   * was a hardcoded h3, and an empty state usually sits directly under the
   * page h1, so /portal/receipts and /portal/leaders/launch jumped h1 to h3.
   * Level 2 is skip-free in both positions the component appears in.
   */
  headingLevel?: 2 | 3 | 4;
}) {
  const Heading = `h${headingLevel}` as 'h2' | 'h3' | 'h4';
  return (
    <div className="card flex flex-col items-center gap-3 px-6 py-14 text-center">
      <div className="flex h-10 w-10 items-center justify-center rounded-full border border-void-600 bg-void-800">
        <span className="h-2 w-2 rounded-full bg-ink-500" />
      </div>
      <Heading className="text-base font-medium text-ink-200">{title}</Heading>
      <p className="max-w-md text-sm leading-relaxed text-ink-400">{body}</p>
      {action}
    </div>
  );
}

export function Callout({
  tone = 'info',
  title,
  children,
  headingLevel = 2,
}: {
  tone?: 'info' | 'warn' | 'danger' | 'verified';
  title: string;
  children: ReactNode;
  /**
   * The heading level for the callout's title.
   *
   * This was a hardcoded `h4`, and a callout almost always sits directly under
   * an `h2` -- so /token and /protocol both jumped h2 to h4, which is the jump
   * screen-reader users feel: heading navigation skips a rung and the callout
   * reads as a sub-sub-section of something that does not exist.
   *
   * The default is 2 because callouts appear in both positions -- directly
   * under the page h1 (the legal pages and most of the portal) and inside an
   * h2 section (/token, /protocol). Level 2 skips in neither: h1 to h2 is a
   * descent, h2 to h2 is a sibling. A default of 3 was tried first and simply
   * moved the skip onto the nine pages with no h2, which is why this was
   * checked against every route rather than reasoned about.
   *
   * Pass 3 where the callout genuinely sits inside an h2 section, so the
   * outline nests instead of flattening.
   *
   * Appearance is unaffected either way: the size comes from the class, not
   * the tag.
   */
  headingLevel?: 2 | 3 | 4 | 5;
}) {
  const Heading = `h${headingLevel}` as 'h2' | 'h3' | 'h4' | 'h5';
  const styles = {
    info: 'border-zor-600/40 bg-zor-500/[0.07]',
    warn: 'border-amber-600/40 bg-amber-500/[0.07]',
    danger: 'border-danger-600/40 bg-danger-500/[0.07]',
    verified: 'border-verified-600/40 bg-verified-500/[0.07]',
  }[tone];
  const dot = {
    info: 'bg-zor-400',
    warn: 'bg-amber-400',
    danger: 'bg-danger-400',
    verified: 'bg-verified-400',
  }[tone];

  return (
    <div className={`rounded-card border p-5 ${styles}`}>
      <div className="flex items-center gap-2">
        <span className={`h-1.5 w-1.5 rounded-full ${dot}`} />
        <Heading className="text-sm font-semibold text-ink-100">{title}</Heading>
      </div>
      <div className="mt-2.5 space-y-2 text-sm leading-relaxed text-ink-300">{children}</div>
    </div>
  );
}

/** Horizontal definition row used across spec tables. */
export function SpecRow({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div className="flex flex-col gap-1 py-3.5 sm:flex-row sm:items-baseline sm:gap-6">
      <dt className="w-full shrink-0 text-xs uppercase tracking-[0.12em] text-ink-500 sm:w-52">
        {label}
      </dt>
      <dd className="min-w-0 flex-1 text-sm text-ink-200">{children}</dd>
    </div>
  );
}

export function Mono({ children }: { children: ReactNode }) {
  return <span className="font-mono text-[0.9em] text-ink-200">{children}</span>;
}

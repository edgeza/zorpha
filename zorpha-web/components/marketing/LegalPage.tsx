import type { ReactNode } from 'react';
import { Callout } from '@/components/ui/Primitives';

/**
 * Shared shell for the legal pages.
 *
 * These are templates written by engineers, not lawyers. The banner says so on
 * every page, because a policy that sounds authoritative but has never been
 * reviewed is worse than an obviously provisional one.
 */
export function LegalPage({
  title,
  updated,
  children,
}: {
  title: string;
  updated: string;
  children: ReactNode;
}) {
  return (
    <div className="shell-narrow py-16">
      <header>
        <span className="badge">Legal</span>
        <h1 className="mt-5 text-3xl font-semibold tracking-tight sm:text-4xl">{title}</h1>
        <p className="mt-3 text-xs text-ink-500">Last updated {updated}</p>
      </header>

      <div className="mt-8">
        <Callout tone="warn" title="Template pending legal review">
          <p>
            This document is a starting point drafted alongside the protocol, not advice and not a
            reviewed policy. It must be replaced by counsel-reviewed text before any mainnet launch
            or token distribution.
          </p>
        </Callout>
      </div>

      <article className="mt-10 space-y-8">{children}</article>
    </div>
  );
}

export function LegalSection({ heading, children }: { heading: string; children: ReactNode }) {
  return (
    <section>
      <h2 className="text-lg font-semibold text-ink-100">{heading}</h2>
      <div className="mt-3 space-y-3 text-sm leading-relaxed text-ink-300">{children}</div>
    </section>
  );
}

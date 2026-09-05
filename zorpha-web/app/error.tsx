'use client';

import { useEffect } from 'react';
import Link from 'next/link';
import { Logo } from '@/components/ui/Primitives';

/**
 * What a visitor sees when a route throws.
 *
 * There was no error boundary at all, so any unhandled error in a segment fell
 * through to the Next.js default: in production that is an unstyled page
 * reading "Application error: a client-side exception has occurred", with no
 * header, no navigation and no way back to the site. `not-found.tsx` already
 * existed and does this properly, which made the gap easy to miss -- a wrong
 * URL was handled gracefully and a genuine fault was not.
 *
 * The distinction this page draws is the one a visitor actually needs: a
 * render fault is OURS, and it says so, because the alternative is someone
 * assuming their wallet or their funds are involved. Nothing on this site
 * moves money without a signature, and the copy says that outright rather
 * than leaving it to be inferred from a blank screen.
 *
 * `reset()` is offered first because most of these are transient -- an RPC
 * timing out mid-render, a hydration mismatch -- and retrying costs nothing.
 */
export default function Error({
  error,
  reset,
}: {
  error: Error & { digest?: string };
  reset: () => void;
}) {
  useEffect(() => {
    // The digest is the only handle on a production stack trace, which is
    // stripped from the client. Without logging it, a report of "it broke" is
    // unmatchable against the server logs.
    console.error('Zorpha: unhandled render error', error.digest ?? '(no digest)', error);
  }, [error]);

  return (
    <div className="flex min-h-dvh flex-col items-center justify-center px-5 text-center">
      <Logo className="h-10 w-auto" />
      <p className="mt-8 font-mono text-2xs uppercase tracking-[0.2em] text-ink-500">
        Something broke
      </p>
      <h1 className="mt-4 text-3xl font-semibold tracking-tight sm:text-4xl">
        This page failed to render
      </h1>
      <p className="mt-4 max-w-md text-sm leading-relaxed text-ink-400">
        That is a fault on our side, not something you did. Nothing on this site moves funds
        without a signature you approve, so no transaction has been affected by this.
      </p>
      {error.digest ? (
        <p className="mt-4 font-mono text-2xs text-ink-500">
          Reference <span className="text-ink-400">{error.digest}</span>
        </p>
      ) : null}
      <div className="mt-8 flex flex-wrap justify-center gap-3">
        <button type="button" onClick={reset} className="btn-primary">
          Try again
        </button>
        <Link href="/" className="btn">
          Back to home
        </Link>
      </div>
    </div>
  );
}

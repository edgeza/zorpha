'use client';

import { useEffect } from 'react';

/**
 * The last resort: the root layout itself threw.
 *
 * `error.tsx` handles a fault inside a route segment, but it renders INSIDE the
 * root layout -- so if the layout is what failed, that boundary never mounts
 * and the visitor gets the unstyled Next.js default instead. This file replaces
 * the layout outright, which is why it carries its own <html> and <body>.
 *
 * Everything here is inline and dependency-free on purpose. The stylesheet, the
 * fonts and the design tokens are all loaded by the layout that has just
 * failed, so a Tailwind class or an imported component is not safe to rely on;
 * assuming otherwise is how a fallback page ends up as unstyled black text on
 * white, which is the exact outcome it exists to prevent. The colours below are
 * the site's own void-950 ground and ink text, spelled out literally.
 */
export default function GlobalError({
  error,
  reset,
}: {
  error: Error & { digest?: string };
  reset: () => void;
}) {
  useEffect(() => {
    console.error('Zorpha: root layout error', error.digest ?? '(no digest)', error);
  }, [error]);

  return (
    <html lang="en">
      <body
        style={{
          margin: 0,
          minHeight: '100dvh',
          display: 'flex',
          flexDirection: 'column',
          alignItems: 'center',
          justifyContent: 'center',
          gap: '1rem',
          padding: '0 1.25rem',
          textAlign: 'center',
          background: '#06060a',
          color: '#e8e8f0',
          fontFamily:
            'ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, Helvetica, Arial, sans-serif',
        }}
      >
        <p
          style={{
            margin: 0,
            fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace',
            fontSize: '0.6875rem',
            letterSpacing: '0.2em',
            textTransform: 'uppercase',
            color: '#8a8aa0',
          }}
        >
          Something broke
        </p>
        <h1 style={{ margin: 0, fontSize: '1.75rem', fontWeight: 600, letterSpacing: '-0.02em' }}>
          Zorpha failed to load
        </h1>
        <p
          style={{
            margin: 0,
            maxWidth: '28rem',
            fontSize: '0.875rem',
            lineHeight: 1.7,
            color: '#a6a6bb',
          }}
        >
          That is a fault on our side. Nothing on this site moves funds without a signature you
          approve, so no transaction has been affected by this.
        </p>
        {error.digest ? (
          <p
            style={{
              margin: 0,
              fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace',
              fontSize: '0.6875rem',
              color: '#8a8aa0',
            }}
          >
            Reference {error.digest}
          </p>
        ) : null}
        <button
          type="button"
          onClick={reset}
          style={{
            marginTop: '0.5rem',
            cursor: 'pointer',
            borderRadius: '9999px',
            border: 'none',
            background: '#7c4dff',
            color: '#ffffff',
            padding: '0.625rem 1.25rem',
            fontSize: '0.875rem',
            fontWeight: 600,
          }}
        >
          Try again
        </button>
      </body>
    </html>
  );
}

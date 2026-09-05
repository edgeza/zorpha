import { ImageResponse } from 'next/og';
import { TOKEN, CIRCULATING_PCT } from '@/lib/tokenomics';

/**
 * The social card.
 *
 * Every link to this site posted in a group chat, a timeline or a Discord
 * renders this. Without it the same link renders as a bare text row, which for
 * a project whose entire distribution is people sharing links is the single
 * cheapest thing to get wrong.
 *
 * Generated rather than shipped as a binary so the numbers on it come from
 * lib/tokenomics.ts. A hardcoded card is a card that goes stale the first time
 * an allocation changes and nobody remembers to re-export the PNG.
 *
 * Satori (the renderer behind ImageResponse) supports a subset of CSS: flexbox
 * only, no grid, and any element with more than one child needs an explicit
 * `display: flex`. It also has no access to the site's webfonts, so this uses
 * the default stack rather than fetching Google Fonts at build time and making
 * every deploy depend on a third-party request succeeding.
 */

export const alt = 'Zorpha: verifiable onchain asset management';
export const size = { width: 1200, height: 630 };
export const contentType = 'image/png';

const VOID = '#06060a';
const INK_100 = '#f6f6fb';
const INK_400 = '#8f8fa8';
const ZOR_400 = '#a48dff';
const BORDER = '#1c1c2b';

function Fact({ k, v }: { k: string; v: string }) {
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
      <div
        style={{
          fontSize: 20,
          letterSpacing: 3,
          textTransform: 'uppercase',
          color: INK_400,
        }}
      >
        {k}
      </div>
      <div style={{ fontSize: 46, color: INK_100, fontWeight: 600 }}>{v}</div>
    </div>
  );
}

export default function Image() {
  return new ImageResponse(
    (
      <div
        style={{
          width: '100%',
          height: '100%',
          display: 'flex',
          flexDirection: 'column',
          justifyContent: 'space-between',
          background: VOID,
          padding: 72,
          position: 'relative',
        }}
      >
        {/* The aurora, matching the hero. Two offset radials rather than one,
            so the glow has a direction instead of reading as a vignette. */}
        <div
          style={{
            position: 'absolute',
            top: -260,
            left: -120,
            width: 900,
            height: 900,
            background:
              'radial-gradient(circle, rgba(139,109,255,0.30) 0%, rgba(6,6,10,0) 62%)',
          }}
        />
        <div
          style={{
            position: 'absolute',
            top: -200,
            right: -220,
            width: 800,
            height: 800,
            background:
              'radial-gradient(circle, rgba(34,211,238,0.16) 0%, rgba(6,6,10,0) 62%)',
          }}
        />

        {/* Wordmark */}
        <div style={{ display: 'flex', alignItems: 'center', gap: 20 }}>
          <svg width="56" height="56" viewBox="0 0 32 32">
            <defs>
              <linearGradient id="og-mark" x1="0" y1="0" x2="1" y2="1">
                <stop offset="0%" stopColor="#a48dff" />
                <stop offset="55%" stopColor="#6f4ae8" />
                <stop offset="100%" stopColor="#22d3ee" />
              </linearGradient>
            </defs>
            <path
              d="M16 2.6 27.5 9.3v13.4L16 29.4 4.5 22.7V9.3L16 2.6Z"
              fill="none"
              stroke="url(#og-mark)"
              strokeWidth="2"
              strokeLinejoin="round"
            />
            <path
              d="M16 10.4 22 13.9v7L16 24.4l-6-3.5v-7l6-3.5Z"
              fill="url(#og-mark)"
              opacity="0.9"
            />
          </svg>
          <div style={{ fontSize: 40, color: INK_100, fontWeight: 600, letterSpacing: -0.5 }}>
            Zorpha
          </div>
        </div>

        {/* Claim */}
        <div style={{ display: 'flex', flexDirection: 'column', gap: 26 }}>
          <div
            style={{
              fontSize: 82,
              lineHeight: 1.05,
              color: INK_100,
              letterSpacing: -2.5,
              maxWidth: 940,
            }}
          >
            Track records you can actually verify
          </div>
          <div style={{ fontSize: 30, lineHeight: 1.4, color: INK_400, maxWidth: 880 }}>
            Curated vaults on Robinhood Chain. Every rebalance is signed onchain and
            published as a receipt anyone can check.
          </div>
        </div>

        {/* Facts, read from the same source the site reads */}
        <div
          style={{
            display: 'flex',
            gap: 76,
            borderTop: `1px solid ${BORDER}`,
            paddingTop: 34,
            alignItems: 'flex-end',
            justifyContent: 'space-between',
          }}
        >
          <div style={{ display: 'flex', gap: 76 }}>
            <Fact k="Max supply" v="1B" />
            <Fact k="Circulating" v={`${CIRCULATING_PCT}%`} />
            <Fact k="Fees to burn" v="50%" />
          </div>
          {/* One expression, not three text nodes: Satori treats adjacent
              children as a multi-child node and then demands display:flex. */}
          <div style={{ fontSize: 28, color: ZOR_400 }}>{`${TOKEN.ticker} · zorpha.xyz`}</div>
        </div>
      </div>
    ),
    size,
  );
}

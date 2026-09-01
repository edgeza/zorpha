import { ImageResponse } from 'next/og';

/**
 * 180x180 PNG. Serves two jobs.
 *
 * The first is the home-screen icon on iOS, which will not use an SVG.
 *
 * The second is the wallet-connection icon. `lib/wagmi.ts` hands this URL to
 * WalletConnect, and it is what a phone wallet shows when asking someone to
 * approve a connection: a dialog naming the site and showing its mark. That
 * URL used to point at `/icon.png`, which never existed, so the dialog rendered
 * a broken image or a generic placeholder at the exact moment a user is
 * deciding whether a site is who it claims to be.
 */

export const size = { width: 180, height: 180 };
export const contentType = 'image/png';

export default function AppleIcon() {
  return new ImageResponse(
    (
      <div
        style={{
          width: '100%',
          height: '100%',
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          background: '#06060a',
        }}
      >
        <svg width="132" height="132" viewBox="0 0 32 32">
          <defs>
            <linearGradient id="apple-mark" x1="0" y1="0" x2="1" y2="1">
              <stop offset="0%" stopColor="#a48dff" />
              <stop offset="55%" stopColor="#6f4ae8" />
              <stop offset="100%" stopColor="#22d3ee" />
            </linearGradient>
          </defs>
          <path
            d="M16 2.6 27.5 9.3v13.4L16 29.4 4.5 22.7V9.3L16 2.6Z"
            fill="none"
            stroke="url(#apple-mark)"
            strokeWidth="2"
            strokeLinejoin="round"
          />
          <path
            d="M16 10.4 22 13.9v7L16 24.4l-6-3.5v-7l6-3.5Z"
            fill="url(#apple-mark)"
            opacity="0.9"
          />
        </svg>
      </div>
    ),
    size,
  );
}

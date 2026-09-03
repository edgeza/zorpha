/**
 * The origin this build will actually be served from.
 *
 * WHY THIS IS A MODULE AND NOT FOUR `?? 'https://zorpha.xyz'`
 *
 * It was four of them -- in `lib/wagmi.ts`, `app/layout.tsx`, `app/robots.ts`
 * and `app/sitemap.ts` -- and they agreed only by coincidence. A value that
 * decides what a wallet shows the user, what search engines index and what
 * every sitemap entry points at should be decided once.
 *
 * `NEXT_PUBLIC_*` is inlined at BUILD time, so this resolves once per build and
 * cannot adapt at runtime. That is precisely why it has to be right.
 *
 * ORDER, AND THE MIDDLE ENTRY
 *
 *   NEXT_PUBLIC_SITE_URL     set deliberately, per environment. Always wins.
 *
 *   NEXT_PUBLIC_VERCEL_URL   Vercel's own hostname for THIS deployment. Every
 *                            preview gets a unique one and no explicit
 *                            NEXT_PUBLIC_SITE_URL, so without this line every
 *                            preview build claimed to be zorpha.xyz: the wallet
 *                            approval dialog named the production site while
 *                            the reviewer was looking at a preview, and the
 *                            canonical URLs pointed at pages that were not the
 *                            ones under review. WalletConnect warns about that
 *                            mismatch specifically.
 *
 *   https://zorpha.xyz       last resort, and the reason `scripts/check-env.mjs`
 *                            refuses a PRODUCTION build that has no explicit
 *                            value. A silent default is only safe while
 *                            something loud is guarding it.
 *
 * Vercel exposes `NEXT_PUBLIC_VERCEL_URL` only while "Automatically expose
 * System Environment Variables" is on, which is the default. If it is off the
 * fallback applies and nothing breaks -- the preview is merely mislabelled
 * again, which is where this started.
 */

export const SITE_URL: string = (() => {
  // An explicit value keeps its own protocol. Forcing https here would rewrite
  // http://localhost:3000 in local dev, and would also hide an http:// value
  // from the production check in scripts/check-env.mjs that exists to catch it.
  const explicit = process.env.NEXT_PUBLIC_SITE_URL;
  if (explicit) return explicit.replace(/\/+$/, '');

  // Vercel supplies a bare hostname, never a scheme, and always serves it over
  // https -- so this is the one place a scheme is added rather than preserved.
  const vercel = process.env.NEXT_PUBLIC_VERCEL_URL;
  if (vercel) return `https://${vercel.replace(/^https?:\/\//, '').replace(/\/+$/, '')}`;

  return 'https://zorpha.xyz';
})();

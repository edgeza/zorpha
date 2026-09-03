/**
 * The site's security headers, with the CSP DERIVED from configuration
 * rather than hardcoded.
 *
 * WHY THIS FILE EXISTS
 *
 * The CSP used to be a literal string in vercel.json, and its `connect-src`
 * named RPC hosts by hand. Production was configured with
 *
 *     NEXT_PUBLIC_RPC_URL = https://testnet.rpc.robinhood.com/
 *
 * while the allowlist admitted only `https://*.chain.robinhood.com`. Those two
 * look alike and do not match, so the browser blocked every single JSON-RPC
 * request the app made:
 *
 *     Connecting to 'https://testnet.rpc.robinhood.com/' violates the
 *     following Content Security Policy directive: "connect-src ..."
 *
 * The failure mode is the worst kind. Nothing 500s, no build fails, the page
 * renders perfectly, the database-backed panels keep working -- and every
 * on-chain value silently becomes an em dash. Circulating supply, burned to
 * date, the buyback figures, the vault bond, a connected wallet's own balance.
 * The vault launch form's three buttons stay greyed out forever, because
 * `bondDone` needs `bond !== undefined` and `bond` never arrives. It reads as
 * "the app is broken" with no way to discover that the app is fine and its own
 * security header is the thing stopping it.
 *
 * A hardcoded allowlist cannot know what the RPC is configured to be, so it is
 * guaranteed to drift the first time anyone points a deployment at a different
 * node. The fix is to stop hardcoding: build `connect-src` from the same
 * environment variables the app itself reads, so the policy and the code can
 * never disagree.
 */

/** Origin of a URL, or null if it is absent or unparseable. */
function originOf(url) {
  if (!url) return null;
  try {
    return new URL(url).origin;
  } catch {
    return null;
  }
}

/**
 * Everything the app legitimately talks to.
 *
 * Wildcards are kept for the hosts whose subdomains genuinely vary (Supabase
 * projects, the chain's own RPC family). The configured RPC origin is added
 * explicitly so an exact, non-matching host still works.
 */
export function connectSrc(env = process.env) {
  const sources = new Set([
    "'self'",
    'https://*.supabase.co',
    'wss://*.supabase.co',

    // The chain's published endpoints, in both naming schemes it has used.
    'https://*.chain.robinhood.com',
    'https://*.rpc.robinhood.com',
    'https://rpc.robinhood.com',
    'https://robinhood-rpc.publicnode.com',
    'https://robinhood-sepolia-rpc.publicnode.com',

    // LI.FI powers the bridge page.
    'https://li.quest',

    // WalletConnect / Reown AppKit. `pulse` and `explorer-api` are separate
    // hosts from `api.web3modal.org` and were both being blocked, which is why
    // the console filled with CSP errors on every page load even when the
    // chain reads were fine.
    'https://api.web3modal.org',
    'https://pulse.walletconnect.org',
    'https://explorer-api.walletconnect.com',
    'https://relay.walletconnect.com',
    'https://relay.walletconnect.org',
    'wss://relay.walletconnect.com',
    'wss://relay.walletconnect.org',
  ]);

  // The configured endpoints, whatever they happen to be. This is the line
  // that stops the policy drifting away from the app's own configuration.
  for (const key of ['NEXT_PUBLIC_RPC_URL', 'NEXT_PUBLIC_SUPABASE_URL']) {
    const origin = originOf(env[key]);
    if (origin) sources.add(origin);
  }

  return [...sources].join(' ');
}

export function contentSecurityPolicy(env = process.env) {
  return [
    "default-src 'self'",
    // 'unsafe-eval' is required by wagmi/viem's ABI handling; 'unsafe-inline'
    // by Next's own bootstrap script.
    "script-src 'self' 'unsafe-inline' 'unsafe-eval'",
    "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com",
    "font-src 'self' https://fonts.gstatic.com data:",
    "img-src 'self' data: blob: https:",
    `connect-src ${connectSrc(env)}`,
    "frame-src 'self' https://verify.walletconnect.com https://verify.walletconnect.org",
    "frame-ancestors 'none'",
    "base-uri 'self'",
    "form-action 'self'",
    "object-src 'none'",
    'upgrade-insecure-requests',
  ].join('; ');
}

export function securityHeaders(env = process.env) {
  return [
    { key: 'Strict-Transport-Security', value: 'max-age=63072000; includeSubDomains; preload' },
    { key: 'X-Content-Type-Options', value: 'nosniff' },
    { key: 'X-Frame-Options', value: 'DENY' },
    { key: 'Referrer-Policy', value: 'strict-origin-when-cross-origin' },
    { key: 'Permissions-Policy', value: 'camera=(), microphone=(), geolocation=(), payment=(), usb=()' },

    // `same-origin` breaks wallet SDKs that open a popup and then talk to it:
    // Coinbase Wallet says so explicitly in the console, and WalletConnect's
    // popup flow has the same shape. `same-origin-allow-popups` keeps the
    // cross-origin isolation this header exists for while letting a popup the
    // user deliberately opened still reach its opener.
    { key: 'Cross-Origin-Opener-Policy', value: 'same-origin-allow-popups' },

    { key: 'Content-Security-Policy', value: contentSecurityPolicy(env) },
  ];
}

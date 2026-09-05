#!/usr/bin/env node
import { readFileSync } from 'node:fs';
import { connectSrc } from '../lib/security-headers.mjs';

/**
 * Build-time environment check.
 *
 * WHY
 *
 * `NEXT_PUBLIC_SITE_URL` has a fallback: `?? 'https://zorpha.xyz'`. That is a
 * sensible default and a silent one, and it is baked in at BUILD time because
 * NEXT_PUBLIC_ variables are inlined. Deploy without it set and the app is
 * confidently wrong in four places at once:
 *
 *   lib/wagmi.ts     the origin shown in the WalletConnect and MetaMask
 *                    approval dialogs -- a user is asked to trust a site whose
 *                    name does not match the one they are looking at, and
 *                    WalletConnect itself warns this "can lead to issues"
 *   app/layout.tsx   canonical URLs and OpenGraph metadata
 *   app/robots.ts    the sitemap reference
 *   app/sitemap.ts   every URL in it
 *
 * None of that fails a build or throws at runtime. It just points at the wrong
 * domain, and the wallet dialog is the worst of the four because it is the one
 * asking for trust.
 *
 * Same failure shape as RH_EXPLORER_URL in the contracts repo:
 * optional-by-omission, defaulted to something plausible, and wrong in a way
 * whose symptom appeared far from its cause -- that one blanked every explorer
 * link in the portal and failed nine contract verifications with an error
 * message that mentioned neither.
 *
 * WHAT IS AND IS NOT CHECKED
 *
 * Only variables where a WRONG value is worse than a missing one, and only for
 * production builds. Development is left alone deliberately: localhost with an
 * autoPort is a legitimate state, and a check that fires constantly in dev is
 * a check people learn to bypass.
 */

const LF = String.fromCharCode(10);
const CR = String.fromCharCode(13);

/**
 * Load the same .env files Next would, in the same precedence order.
 *
 * `prebuild` runs as its own node process, and node does not read .env files --
 * only Next does, and only after prebuild has finished. Without this a value
 * set in .env.production or .env.local is invisible here and the check fails on
 * a correctly configured project. A check that fires wrongly is worse than no
 * check, because it teaches people to bypass it.
 *
 * Hand-parsed rather than pulling in dotenv, and deliberately without a regex:
 * the newline class kept getting mangled by the tooling writing this file, so
 * splitting on an explicit character code is the unambiguous version.
 *
 * A real process.env value always wins, which is what Next does and what a
 * platform like Vercel relies on.
 */
function loadEnvFiles() {
  const mode = process.env.NODE_ENV === 'production' ? 'production' : 'development';
  const files = [`.env.${mode}.local`, '.env.local', `.env.${mode}`, '.env'];

  for (const file of files) {
    let text;
    try {
      text = readFileSync(file, 'utf8');
    } catch {
      continue;
    }
    for (const rawLine of text.split(LF)) {
      const line = rawLine.split(CR).join('').trim();
      if (!line || line.startsWith('#')) continue;

      const eq = line.indexOf('=');
      if (eq < 1) continue;

      const key = line.slice(0, eq).trim();
      let val = line.slice(eq + 1).trim();
      const quoted =
        (val.startsWith('"') && val.endsWith('"')) ||
        (val.startsWith("'") && val.endsWith("'"));
      if (quoted && val.length >= 2) val = val.slice(1, -1);

      if (process.env[key] === undefined) process.env[key] = val;
    }
  }
}

loadEnvFiles();

const isProd =
  process.env.NODE_ENV === 'production' || process.env.VERCEL_ENV === 'production';

// A Vercel PREVIEW is a production Next.js build -- NODE_ENV is 'production'
// there -- so isProd above is true for it, and this script demanded a
// NEXT_PUBLIC_SITE_URL that only the production environment has. Every preview
// deployment failed on it:
//
//     Environment check failed (1):
//       - NEXT_PUBLIC_SITE_URL is not set.
//     Refusing to build.
//
// while the same commit built fine in GitHub Actions, which sets one. The
// check was right that a build must know its own origin and wrong that only a
// human can supply it: Vercel already publishes the origin this deployment
// will be served from, as VERCEL_URL. lib/site-url.ts consumes the public
// twin of it, so a preview now labels itself correctly instead of claiming to
// be zorpha.xyz.
/**
 * The hosts this site is actually served from.
 *
 * An assertion about the world, not a preference: changing it should be a
 * deliberate edit in the same commit as the domain change, which is exactly
 * why it lives in the repository rather than in an environment variable that
 * could be set to anything.
 */
const PUBLIC_HOSTS = ['www.zorpha.xyz', 'zorpha.xyz'];

const isPreview = process.env.VERCEL_ENV === 'preview';
const problems = [];
const notes = [];

const siteUrl = process.env.NEXT_PUBLIC_SITE_URL;

if (!siteUrl) {
  if (isPreview && process.env.VERCEL_URL) {
    // Report what the APP will use, not what this script can see. The two are
    // different variables: VERCEL_URL is always present in the build
    // environment, while lib/site-url.ts can only read NEXT_PUBLIC_VERCEL_URL,
    // which Vercel exposes only while "Automatically expose System Environment
    // Variables" is on. Noting the first while the app falls back to the second
    // would print a reassuring origin that nothing actually serves.
    const publicUrl = process.env.NEXT_PUBLIC_VERCEL_URL;
    notes.push(
      publicUrl
        ? `NEXT_PUBLIC_SITE_URL unset — preview build, using https://${publicUrl}`
        : [
            `NEXT_PUBLIC_SITE_URL unset, and NEXT_PUBLIC_VERCEL_URL is not exposed.`,
            `  This preview will label itself https://zorpha.xyz, not ${process.env.VERCEL_URL}.`,
            `  Turn on "Automatically expose System Environment Variables" in the`,
            `  Vercel project, or set NEXT_PUBLIC_SITE_URL for the Preview scope.`,
          ].join(LF + '        '),
    );
  } else if (isProd) {
    problems.push(
      [
        'NEXT_PUBLIC_SITE_URL is not set.',
        '  It is inlined at build time, so this build would ship with the',
        '  fallback https://zorpha.xyz in the wallet approval dialog, the',
        '  canonical URLs, robots.txt and every sitemap entry.',
        '  Set it to the origin this build will actually be served from.',
      ].join(LF + '      '),
    );
  } else {
    notes.push('NEXT_PUBLIC_SITE_URL unset — dev build, falling back to https://zorpha.xyz');
  }
} else {
  let url;
  try {
    url = new URL(siteUrl);
  } catch {
    problems.push(`NEXT_PUBLIC_SITE_URL is not a valid URL: ${siteUrl}`);
  }

  if (url) {
    if (url.pathname !== '/' || url.search || url.hash) {
      problems.push(
        [
          `NEXT_PUBLIC_SITE_URL must be a bare origin, got ${siteUrl}`,
          '  A trailing path is concatenated into icon and sitemap URLs.',
        ].join(LF + '      '),
      );
    }
    if (isProd && url.protocol !== 'https:') {
      problems.push(
        [
          `NEXT_PUBLIC_SITE_URL is ${url.protocol} in a production build.`,
          '  Wallets treat a non-HTTPS origin as untrusted.',
        ].join(LF + '      '),
      );
    }
    if (isProd && /localhost|127\.0\.0\.1|0\.0\.0\.0/.test(url.hostname)) {
      problems.push(
        [
          `NEXT_PUBLIC_SITE_URL points at ${url.hostname} in a production build.`,
          '  This is almost certainly a .env.local value leaking into a deploy.',
        ].join(LF + '      '),
      );
    }

    // The origin must be one users actually reach.
    //
    // Every check above asks whether the value is WELL FORMED -- a valid URL, a
    // bare origin, https, not localhost. A production deploy once shipped with
    // NEXT_PUBLIC_SITE_URL set to the project's vercel.app alias, which passes
    // all four and is still wrong. It went unnoticed because nothing on the
    // page looks broken:
    //
    //   canonical  https://<project>.vercel.app/whitepaper   on every page
    //   robots     Sitemap + Host pointing at the same host
    //   sitemap    all twelve entries
    //
    // and worst, lib/wagmi.ts hands that origin to the wallet approval dialog,
    // so someone on the real domain is asked to trust a name that does not
    // match the site in front of them -- the shape of a phishing prompt, on a
    // page asking for a deposit.
    //
    // Gated on VERCEL_ENV === 'production' rather than isProd, because isProd
    // is also true for previews and for a plain `next build`, and a preview is
    // SUPPOSED to label itself with its vercel.app origin.
    if (process.env.VERCEL_ENV === 'production' && !PUBLIC_HOSTS.includes(url.hostname)) {
      problems.push(
        [
          `NEXT_PUBLIC_SITE_URL is ${url.hostname} in a PRODUCTION deploy.`,
          `  Expected one of: ${PUBLIC_HOSTS.join(', ')}`,
          '  This value is inlined at build time into the wallet approval',
          '  dialog, every canonical URL, robots.txt and every sitemap entry.',
          '  A vercel.app alias passes every other check here and is still the',
          '  wrong answer: it tells search engines the deployment host is',
          '  authoritative, and it asks a depositor to approve an origin whose',
          '  name does not match the site they are looking at.',
          '  Set it in Vercel -> Settings -> Environment Variables -> Production.',
          '  If the public domain has genuinely changed, update PUBLIC_HOSTS in',
          '  this file in the same commit -- deliberately, not to silence this.',
        ].join(LF + '      '),
      );
    }
  }
}

// WalletConnect is optional: the connector is only registered when the project
// id is present, and the app works without it. Worth a note, not a failure.
//
// NEXT_PUBLIC_WC_PROJECT_ID is the name lib/wagmi.ts actually reads. I first
// wrote this check against NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID, which exists
// nowhere in the codebase, so it emitted "WalletConnect will be unavailable"
// on every build INCLUDING ones where it is correctly configured. A check that
// cries wolf is worse than no check, which is the whole argument for this file.
if (!process.env.NEXT_PUBLIC_WC_PROJECT_ID) {
  notes.push(
    'NEXT_PUBLIC_WC_PROJECT_ID unset — WalletConnect and mobile wallet ' +
      'pairing will be unavailable in this build',
  );
}

// The contract addresses. Missing ones do NOT fail the build -- a staged
// deploy legitimately has some unset, and the portal's EnvBanner names them at
// runtime. But they are inlined at build time, so a build made without them
// produces a site whose entire on-chain layer is dead: every balance, supply
// and threshold renders as an em dash while the database-backed panels keep
// working and make it look healthy.
//
// That is exactly what happened to the production deploy: all twelve unset on
// Vercel, so circulating supply, burned-to-date, buyback figures and the
// launch form's bond were all blank on a site that otherwise looked fine.
const ADDRESS_VARS = [
  'NEXT_PUBLIC_ZOR_ADDRESS',
  'NEXT_PUBLIC_VESTING_ADDRESS',
  'NEXT_PUBLIC_MERKLE_DISTRIBUTOR_ADDRESS',
  'NEXT_PUBLIC_BUYBACK_ADDRESS',
  'NEXT_PUBLIC_TREASURY_ADDRESS',
  'NEXT_PUBLIC_INSURANCE_ADDRESS',
  'NEXT_PUBLIC_TIMELOCK_ADDRESS',
  'NEXT_PUBLIC_VAULT_FACTORY_ADDRESS',
  'NEXT_PUBLIC_STRATEGY_EXECUTOR_ADDRESS',
  'NEXT_PUBLIC_REPUTATION_REGISTRY_ADDRESS',
  'NEXT_PUBLIC_VAULT_LAUNCHER_ADDRESS',
  'NEXT_PUBLIC_LEADER_FAUCET_ADDRESS',
];
const missingAddresses = ADDRESS_VARS.filter((v) => !process.env[v]);
if (missingAddresses.length) {
  notes.push(
    `${missingAddresses.length} of ${ADDRESS_VARS.length} contract addresses unset — ` +
      'those panels will read nothing at runtime: ' +
      missingAddresses.map((v) => v.replace('NEXT_PUBLIC_', '').replace('_ADDRESS', '')).join(', '),
  );
  if (missingAddresses.length === ADDRESS_VARS.length) {
    notes.push(
      'EVERY address is unset. The build will produce a site with no on-chain ' +
        'reads at all, while database-backed panels keep working and hide it.',
    );
  }
}

// The RPC origin must be inside the CSP's connect-src, or the browser blocks
// every JSON-RPC call and the whole on-chain layer dies silently.
//
// This exact mismatch shipped: production ran with
// NEXT_PUBLIC_RPC_URL=https://testnet.rpc.robinhood.com/ against an allowlist
// admitting only https://*.chain.robinhood.com. Those two look alike, do not
// match, and the only evidence was a console error nobody was reading. Every
// figure on the site rendered as an em dash and the vault launch buttons never
// enabled, because they wait on a bond amount that could not be fetched.
//
// connect-src is now derived from this same variable, so the check should
// always pass -- it exists to catch an edit that reintroduces a literal list.
const rpcUrl = process.env.NEXT_PUBLIC_RPC_URL;
if (rpcUrl) {
  let rpcOrigin = null;
  try {
    rpcOrigin = new URL(rpcUrl).origin;
  } catch {
    problems.push(`NEXT_PUBLIC_RPC_URL is not a valid URL: ${rpcUrl}`);
  }

  if (rpcOrigin) {
    const allowed = connectSrc(process.env).split(/\s+/).filter(Boolean);
    const { hostname, protocol } = new URL(rpcUrl);

    const covered = allowed.some((entry) => {
      if (entry === rpcOrigin) return true;
      if (!entry.startsWith('http')) return false;
      let pattern;
      try {
        pattern = new URL(entry.replace('*.', 'WILDCARD.'));
      } catch {
        return false;
      }
      if (pattern.protocol !== protocol) return false;
      if (!entry.includes('*.')) return pattern.hostname === hostname;
      const suffix = pattern.hostname.replace('wildcard.', '');
      return hostname === suffix || hostname.endsWith(`.${suffix}`);
    });

    if (!covered) {
      problems.push(
        [
          `The RPC origin ${rpcOrigin} is not covered by the CSP connect-src.`,
          '  Every chain read would be blocked by the browser, and the site',
          '  would render an em dash in every on-chain field while otherwise',
          '  looking healthy. Add the origin in lib/security-headers.mjs.',
        ].join(LF + '      '),
      );
    }
  }
}

for (const note of notes) console.warn(`  note: ${note}`);

if (problems.length) {
  console.error(`${LF}  Environment check failed (${problems.length}):${LF}`);
  for (const problem of problems) console.error(`    - ${problem}${LF}`);
  console.error(`  Refusing to build. Fix the above, or build with NODE_ENV=development.${LF}`);
  process.exit(1);
}

console.log(`  env ok${isProd ? ' (production)' : ' (development)'}`);

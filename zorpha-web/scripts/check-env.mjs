#!/usr/bin/env node
import { readFileSync } from 'node:fs';

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
const problems = [];
const notes = [];

const siteUrl = process.env.NEXT_PUBLIC_SITE_URL;

if (!siteUrl) {
  if (isProd) {
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

for (const note of notes) console.warn(`  note: ${note}`);

if (problems.length) {
  console.error(`${LF}  Environment check failed (${problems.length}):${LF}`);
  for (const problem of problems) console.error(`    - ${problem}${LF}`);
  console.error(`  Refusing to build. Fix the above, or build with NODE_ENV=development.${LF}`);
  process.exit(1);
}

console.log(`  env ok${isProd ? ' (production)' : ' (development)'}`);

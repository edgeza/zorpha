#!/usr/bin/env node
/**
 * Crawls every route against a running production server.
 *
 * Guards three things: that pages render, that no testnet chain id or RPC host
 * leaked back in, and that the tokenomics figures corrected on 5 September have
 * not regressed.
 *
 * COVERAGE BOUNDARY: this fetches server-rendered HTML and runs no JavaScript.
 * It cannot see client-only failures. In particular the hero prism is imported
 * with `ssr: false` (components/ui/prism-hero.tsx:38) and is never present in
 * the HTML fetched here, so a broken or mis-coloured prism will still report
 * "routes ok". Verifying that needs a real browser. Read a pass as "the server
 * renders every route without leaking the wrong chain", not as "the site works".
 */
const BASE = process.env.BASE ?? 'http://localhost:3000';

const ROUTES = [
  '/', '/faq', '/protocol', '/roadmap', '/token', '/whitepaper', '/tools/bridge',
  '/legal/terms', '/legal/privacy', '/legal/disclaimer',
  '/portal', '/portal/airdrop', '/portal/governance', '/portal/leaderboard',
  '/portal/leaders', '/portal/leaders/launch', '/portal/manage',
  '/portal/receipts', '/portal/vaults', '/portal/vesting',
  // Dynamic routes exercised with real mainnet values:
  '/portal/vaults/0x3829bC787d4eB15Ec855A6cA33e1492a9103d130',  // zsUSDG vault
  '/portal/managers/0xC75E64Ccf3ce6E2F40939Ab58255681769BcF8C4', // governance Safe
];

const failures = [];

for (const route of ROUTES) {
  let res, body;
  try {
    res = await fetch(BASE + route);
    body = await res.text();
  } catch (err) {
    failures.push(route + ': unreachable (' + err.message + ')');
    continue;
  }

  if (res.status !== 200) failures.push(route + ': HTTP ' + res.status);
  if (/application error|Internal Server Error/i.test(body)) failures.push(route + ': render error');
  if (/46630|testnet\.chain\.robinhood/i.test(body)) failures.push(route + ': testnet reference');
  if (/21% (of supply|float)|Float at launch/i.test(body)) failures.push(route + ': stale 21% float claim');
  console.log('  ' + String(res.status).padEnd(4) + route);
}

if (failures.length) {
  console.error('\nroute crawl FAILED:\n' + failures.map((f) => '  - ' + f).join('\n'));
  process.exit(1);
}
console.log('\n  ' + ROUTES.length + ' routes ok');

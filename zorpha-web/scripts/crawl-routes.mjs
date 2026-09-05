#!/usr/bin/env node
/**
 * Crawls every static route against a running production server.
 *
 * Guards three things at once: that pages render, that no testnet chain id or
 * RPC host leaked back in, and that the tokenomics figures corrected on
 * 5 September have not regressed.
 */
const BASE = process.env.BASE ?? 'http://localhost:3000';

const ROUTES = [
  '/', '/faq', '/protocol', '/roadmap', '/token', '/whitepaper', '/tools/bridge',
  '/legal/terms', '/legal/privacy', '/legal/disclaimer',
  '/portal', '/portal/airdrop', '/portal/governance', '/portal/leaderboard',
  '/portal/leaders', '/portal/leaders/launch', '/portal/manage',
  '/portal/receipts', '/portal/vaults', '/portal/vesting',
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

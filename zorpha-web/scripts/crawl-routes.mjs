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
  '/writing', '/writing/silent-failures',
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
  // The testnet check exists because a mainnet page mentioning 46630 is almost
  // always a leftover -- that is how three dead testnet vaults were once
  // offered to mainnet visitors. The writing routes are the one place where
  // naming the testnet is the POINT: the post is about telling 46630 and 4663
  // apart. Exempting those two routes keeps the rule strict everywhere it
  // guards something, rather than loosening the pattern for the whole site.
  // The home page and /protocol carry ONE sanctioned testnet link: the receipt
  // in ReceiptVerifier is a real event the rotation vault emitted on 46630, and
  // there is no mainnet equivalent because no mainnet rebalance has happened
  // yet. It used to be pointed at the MAINNET explorer, which answered 200 and
  // then rendered a details page with the block, sender and recipient
  // permanently blank -- a dead end on the one link the page offers as proof.
  //
  // That single URL is stripped before the check rather than exempting the two
  // routes, so any OTHER testnet reference appearing on them still fails. An
  // exemption by route would switch the rule off exactly where it guards most.
  const SANCTIONED_TESTNET_LINK =
    'https://explorer.testnet.chain.robinhood.com/tx/0x6d2ab9adc9c004ace161e0f2bf4904317c17b84e72a5ef417b823bfbd60a3869';
  const scanned = body.split(SANCTIONED_TESTNET_LINK).join('');
  if (!route.startsWith('/writing') && /46630|testnet\.chain\.robinhood/i.test(scanned)) {
    failures.push(route + ': testnet reference');
  }
  if (/21% (of supply|float)|Float at launch/i.test(body)) failures.push(route + ': stale 21% float claim');
  console.log('  ' + String(res.status).padEnd(4) + route);
}

if (failures.length) {
  console.error('\nroute crawl FAILED:\n' + failures.map((f) => '  - ' + f).join('\n'));
  process.exit(1);
}
console.log('\n  ' + ROUTES.length + ' routes ok');

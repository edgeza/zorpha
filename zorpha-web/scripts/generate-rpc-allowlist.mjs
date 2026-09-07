#!/usr/bin/env node
/**
 * Generate the CSP allowlist of origin-chain RPC hosts from LI.FI's own chain
 * list, and check the committed copy has not gone stale.
 *
 * WHY THIS EXISTS
 *
 * The buy page shipped on 7 September 2026 promising that it reads what you
 * already hold, on any chain. It could not. A tester with USDT on BSC selected
 * the token, saw the right symbol, and got a balance of zero.
 *
 * LI.FI reads balances in the browser. `getPublicClient` in
 * @lifi/sdk-provider-ethereum builds a viem transport per chain out of that
 * chain's own RPC URLs and calls them directly, so a balance read on BSC is a
 * fetch to bsc-dataseed.binance.org from the visitor's browser. Our
 * `connect-src` named the Robinhood Chain endpoints and nothing else, so 116
 * of the 119 RPC endpoints behind LI.FI's 70 chains were blocked.
 *
 * The failure is silent by construction. getTokenBalancesByChain wraps each
 * chain in `Promise.allSettled` and logs the rejection only when the SDK's
 * `debug` flag is on, so a blocked read is indistinguishable from an empty
 * wallet. Nothing throws, nothing 500s, the widget renders perfectly and
 * quotes a route. It just believes you own nothing.
 *
 * lib/security-headers.mjs already carries the lesson in its header: build the
 * policy from the same configuration the app reads, so the two cannot
 * disagree. It applied that to the chain's own RPC and stopped there, because
 * until the buy page there was nothing reading balances off other chains.
 * This script extends the same idea to the other end of the bridge.
 *
 * WHY THE OUTPUT IS COMMITTED RATHER THAN FETCHED DURING THE BUILD
 *
 * Deriving the list at build time would put li.quest on the critical path of
 * every deploy. An outage would then either fail the build or, far worse,
 * produce an empty allowlist and ship it: the site would come up looking
 * healthy with every balance silently back to zero, which is the exact failure
 * this file exists to end. So the list is generated deliberately, committed,
 * and reviewed in a diff like any other code, and CI re-fetches to check it
 * has not drifted.
 *
 * USAGE
 *
 *   node scripts/generate-rpc-allowlist.mjs           rewrite the generated file
 *   node scripts/generate-rpc-allowlist.mjs --check   fail if it is stale
 */

import { writeFileSync, readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const HERE = dirname(fileURLToPath(import.meta.url));
const OUTPUT = join(HERE, '..', 'lib', 'rpc-allowlist.generated.mjs');

/**
 * EVM only, deliberately.
 *
 * LI.FI also serves Solana, Bitcoin and Sui, but reaching them needs provider
 * packages this app does not install: components/tools/BridgeWidget.tsx passes
 * `providers: [EthereumProvider(...)]` and nothing else, so those three chains
 * are never offered. Allowlisting their RPC hosts would widen the policy for
 * traffic that cannot happen.
 */
const CHAINS_ENDPOINT = 'https://li.quest/v1/chains?chainTypes=EVM';

/**
 * Turn an RPC URL into a CSP source.
 *
 * A CSP source is matched by scheme and host, so the path is dropped and the
 * scheme is kept: viem sends `wss://` URLs through `webSocket()` and
 * everything else through `http()`, and connect-src treats the two schemes as
 * different sources. A URL that will not parse is skipped rather than guessed
 * at, since a malformed entry in the policy would silently widen or break it.
 */
function toSource(url) {
  try {
    const { protocol, host } = new URL(url);
    if (protocol !== 'https:' && protocol !== 'wss:') return null;
    return `${protocol}//${host}`;
  } catch {
    return null;
  }
}

async function fetchSources() {
  const response = await fetch(CHAINS_ENDPOINT, { headers: { accept: 'application/json' } });
  if (!response.ok) {
    throw new Error(`li.quest returned ${response.status} ${response.statusText}`);
  }

  const body = await response.json();
  const chains = body?.chains;
  if (!Array.isArray(chains) || chains.length === 0) {
    throw new Error('li.quest returned no chains, refusing to write an empty allowlist');
  }

  const sources = new Set();
  for (const chain of chains) {
    for (const url of chain?.metamask?.rpcUrls ?? []) {
      const source = toSource(url);
      if (source) sources.add(source);
    }
  }

  if (sources.size === 0) {
    throw new Error('no usable RPC hosts found, refusing to write an empty allowlist');
  }

  // Sorted so regenerating without an upstream change produces no diff.
  return { sources: [...sources].sort(), chainCount: chains.length };
}

function render({ sources, chainCount }) {
  return `/**
 * GENERATED FILE. Do not edit by hand.
 *
 * Regenerate with:  npm run rpc-allowlist
 * Check for drift:  npm run check:rpc-allowlist
 *
 * The RPC hosts LI.FI's widget calls from the browser to read a visitor's
 * balances on the chain they are paying from. Without these in \`connect-src\`
 * every balance silently reads as zero. See scripts/generate-rpc-allowlist.mjs
 * for why this is committed rather than fetched at build time.
 *
 * Covers ${chainCount} EVM chains and ${sources.length} distinct endpoints.
 */
export const LIFI_RPC_SOURCES = [
${sources.map((s) => `  '${s}',`).join('\n')}
];
`;
}

const check = process.argv.includes('--check');

let generated;
try {
  generated = await fetchSources();
} catch (error) {
  /**
   * A network failure is not drift.
   *
   * In check mode this runs in CI, where li.quest being unreachable says
   * nothing about whether the committed list is correct. Failing the build on
   * it would train everyone to ignore a red check that is usually a flake,
   * which is how a real drift failure gets waved through. So an unreachable
   * upstream warns and passes, and only a genuine mismatch fails.
   */
  const message = error instanceof Error ? error.message : String(error);
  if (check) {
    console.warn(`check:rpc-allowlist skipped, could not reach li.quest: ${message}`);
    process.exit(0);
  }
  console.error(`Could not fetch the chain list: ${message}`);
  process.exit(1);
}

const rendered = render(generated);

if (check) {
  let committed;
  try {
    committed = readFileSync(OUTPUT, 'utf8');
  } catch {
    console.error('lib/rpc-allowlist.generated.mjs is missing. Run: npm run rpc-allowlist');
    process.exit(1);
  }

  if (committed !== rendered) {
    console.error(
      [
        'The committed RPC allowlist no longer matches LI.FI.',
        '',
        'LI.FI has changed the endpoints it calls, so the CSP is about to start',
        'blocking balance reads that used to work, or is allowing hosts nobody',
        'calls any more. Neither shows up as an error in the browser.',
        '',
        'Fix with:  npm run rpc-allowlist    then commit the change.',
      ].join('\n'),
    );
    process.exit(1);
  }

  console.log(
    `rpc allowlist current: ${generated.sources.length} endpoints across ${generated.chainCount} chains`,
  );
  process.exit(0);
}

writeFileSync(OUTPUT, rendered);
console.log(
  `Wrote lib/rpc-allowlist.generated.mjs: ${generated.sources.length} endpoints across ${generated.chainCount} chains`,
);

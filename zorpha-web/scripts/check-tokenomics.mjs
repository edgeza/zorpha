/**
 * Fails the build if the allocation published on the site has drifted from the
 * allocation the deploy script will actually execute.
 *
 * These are two hand-maintained copies of the same six numbers: `ALLOCATIONS`
 * in lib/tokenomics.ts drives every chart, table and headline percentage on the
 * marketing site, and the `BPS_*` constants in DeployZorphaToken.s.sol decide
 * where a billion tokens actually go. Nothing connected them. Editing one and
 * forgetting the other would not break a test or a type check, it would just
 * make the website a misstatement of the distribution, which is the single
 * worst class of error this project can ship.
 *
 * Both files are parsed as text rather than imported. lib/tokenomics.ts is
 * TypeScript and the Solidity file obviously is not, and a regex over a list of
 * integer constants is more robust here than a toolchain that can break.
 *
 * If the contracts are not checked out alongside the site this skips with a
 * notice rather than failing: a missing repo is not evidence of a mismatch.
 * A file that IS present and disagrees is a hard failure.
 */
import { readFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const TS = resolve(here, '../lib/tokenomics.ts');
const SOL = resolve(here, '../../sidequest-protocol/contracts/script/DeployZorphaToken.s.sol');

/** site key -> Solidity constant suffix */
const PAIRS = {
  community: 'COMMUNITY',
  treasury: 'TREASURY',
  contributors: 'CONTRIB',
  liquidity: 'LIQUIDITY',
  backers: 'BACKERS',
  insurance: 'INSURANCE',
};

function fail(msg) {
  console.error(`\n  tokenomics parity: ${msg}\n`);
  process.exit(1);
}

if (!existsSync(SOL)) {
  console.log('  tokenomics parity: contracts not checked out here, skipping.');
  process.exit(0);
}

const ts = readFileSync(TS, 'utf8');
const sol = readFileSync(SOL, 'utf8');

// Site: `key: 'community',` ... `bps: 3800,`; the bps that follows each key.
const site = {};
for (const key of Object.keys(PAIRS)) {
  const m = ts.match(new RegExp(`key:\\s*'${key}'[\\s\\S]{0,400}?bps:\\s*(\\d+)`));
  if (!m) fail(`could not find a bps value for '${key}' in lib/tokenomics.ts`);
  site[key] = Number(m[1]);
}

// Contract: `uint256 internal constant BPS_COMMUNITY  = 3800;`
const chain = {};
for (const [key, suffix] of Object.entries(PAIRS)) {
  const m = sol.match(new RegExp(`BPS_${suffix}\\s*=\\s*(\\d+)\\s*;`));
  if (!m) fail(`could not find BPS_${suffix} in ${SOL}`);
  chain[key] = Number(m[1]);
}

const drift = Object.keys(PAIRS).filter((k) => site[k] !== chain[k]);
if (drift.length > 0) {
  const rows = drift
    .map((k) => `    ${k.padEnd(14)} site ${String(site[k]).padStart(5)}  contract ${chain[k]}`)
    .join('\n');
  fail(`site and contracts disagree on ${drift.length} allocation(s):\n${rows}`);
}

const total = Object.values(site).reduce((a, b) => a + b, 0);
if (total !== 10_000) fail(`allocations sum to ${total} bps, not 10000`);

console.log(`  tokenomics parity: 6 allocations match the deploy script, summing to 100%.`);

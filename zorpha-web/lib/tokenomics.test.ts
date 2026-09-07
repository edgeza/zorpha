import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  custodyFrom,
  LAST_MEASURED,
  SEASON_1_RESERVE,
  ON_CHAIN_CUSTODY,
  CIRCULATING_PCT,
  TOKEN,
} from './tokenomics';

/**
 * The custody table is rendered under a heading that says "What the chain
 * actually holds" and a lede that tells the reader to go and verify it on a
 * block explorer. That copy is a promise, and until now nothing kept it: the
 * four figures were typed in, correct on the day, and unwatched afterwards.
 *
 * Two things are tested here, and they are different in kind.
 *
 * The arithmetic tests are pure and always run. They pin what happens when the
 * balances move, which is the case the hardcoded version got wrong.
 *
 * The drift test reaches the chain, and only runs when ZOR_RPC_URL is set, so a
 * clone with no network stays green rather than red-for-the-wrong-reason. It is
 * the ratchet behind LAST_MEASURED: three consumers cannot await a network read
 * (metadata on two pages, the edge-runtime opengraph image, the client Hero),
 * so they use the constant, and this fails the build if the constant has
 * drifted from the chain.
 */

const ZOR = '0x9684AFe2422a0B03719201c78959b6B70e8d4ae8';
const VESTING = '0x81613D9914F7b4c02c897941757a99BC191De88e';
const SAFE = '0xC75E64Ccf3ce6E2F40939Ab58255681769BcF8C4';
const INSURANCE = '0x9D3B787a3492b4fe6D2a2C12062a4164263522Fd';

// --- arithmetic, no network ------------------------------------------------

test('custody sums to max supply for any balances', () => {
  for (const safe of [96_311_116, 66_311_116, 16_311_116, 0]) {
    const total = custodyFrom({ vesting: 800_000_000, safe, insurance: 40_000_000 }).reduce(
      (s, c) => s + c.tokens,
      0,
    );
    assert.equal(total, TOKEN.maxSupply, `safe=${safe} must still sum to max supply`);
  }
});

test('a Season 1 payout moves the reserve down and circulating up, one for one', () => {
  const before = custodyFrom({ vesting: 800_000_000, safe: 96_311_116, insurance: 40_000_000 });
  const after = custodyFrom({ vesting: 800_000_000, safe: 66_311_116, insurance: 40_000_000 });

  const get = (rows: typeof before, label: string) => rows.find((c) => c.label === label)!.tokens;
  const reserveLabel = 'Community airdrop reserve, held by governance';

  // This is the case the hardcoded table got wrong: paying out 30,000,000 left
  // it claiming 80,000,000 was still reserved and 80,000,000 was circulating.
  assert.equal(get(before, reserveLabel) - get(after, reserveLabel), 30_000_000);
  assert.equal(get(after, 'Circulating') - get(before, 'Circulating'), 30_000_000);
});

test('a Safe drawn below its own float reports no reserve, not a negative one', () => {
  const rows = custodyFrom({ vesting: 800_000_000, safe: 5_000_000, insurance: 40_000_000 });
  const reserve = rows.find((c) => c.label.startsWith('Community airdrop'))!.tokens;
  assert.equal(reserve, 0);
  assert.ok(reserve <= SEASON_1_RESERVE);
  assert.equal(rows.reduce((s, c) => s + c.tokens, 0), TOKEN.maxSupply);
});

test('the reserve is capped, so a top-up cannot inflate the claim', () => {
  const rows = custodyFrom({ vesting: 800_000_000, safe: 500_000_000, insurance: 40_000_000 });
  const reserve = rows.find((c) => c.label.startsWith('Community airdrop'))!.tokens;
  assert.equal(reserve, SEASON_1_RESERVE);
});

test('vesting is read, not assumed, so the March 2027 cliff cannot go stale silently', () => {
  // The schedule releases linearly after a 180-day cliff from 4 September 2026.
  const rows = custodyFrom({ vesting: 700_000_000, safe: 96_311_116, insurance: 40_000_000 });
  assert.equal(rows.find((c) => c.label === 'Locked in vesting')!.tokens, 700_000_000);
  assert.equal(rows.reduce((s, c) => s + c.tokens, 0), TOKEN.maxSupply);
});

test('the exported constants agree with the last measured balances', () => {
  assert.deepEqual(
    ON_CHAIN_CUSTODY.map((c) => c.tokens),
    custodyFrom(LAST_MEASURED).map((c) => c.tokens),
  );
  assert.equal(CIRCULATING_PCT, 8);
});

// --- drift against the real chain ------------------------------------------

test('LAST_MEASURED still matches the chain', async (t) => {
  const rpc = process.env.ZOR_RPC_URL;
  if (!rpc) {
    t.skip('ZOR_RPC_URL not set, so the chain was not consulted');
    return;
  }

  const balanceOf = async (holder: string): Promise<number> => {
    const data = `0x70a08231${holder.slice(2).toLowerCase().padStart(64, '0')}`;
    const res = await fetch(rpc, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        jsonrpc: '2.0',
        id: 1,
        method: 'eth_call',
        params: [{ to: ZOR, data }, 'latest'],
      }),
    });
    const json = (await res.json()) as { result?: string; error?: { message: string } };
    if (json.error) throw new Error(`eth_call failed: ${json.error.message}`);
    // Whole tokens. ZOR is 18 decimals and every balance here is a round
    // number of tokens, so integer division loses nothing that matters.
    return Number(BigInt(json.result ?? '0x0') / 10n ** 18n);
  };

  const [vesting, safe, insurance] = await Promise.all([
    balanceOf(VESTING),
    balanceOf(SAFE),
    balanceOf(INSURANCE),
  ]);

  const drift = (label: string, onChain: number, declared: number) =>
    `${label}: chain says ${onChain.toLocaleString()}, LAST_MEASURED says ${declared.toLocaleString()}. ` +
    'Update LAST_MEASURED in lib/tokenomics.ts. Three consumers cannot await a read and rely on it.';

  assert.equal(vesting, LAST_MEASURED.vesting, drift('vesting', vesting, LAST_MEASURED.vesting));
  assert.equal(safe, LAST_MEASURED.safe, drift('governance Safe', safe, LAST_MEASURED.safe));
  assert.equal(
    insurance,
    LAST_MEASURED.insurance,
    drift('insurance fund', insurance, LAST_MEASURED.insurance),
  );
});

// --- the guard that stops a wrong supply figure -----------------------------

/**
 * Not a test of readCustody itself, which needs a network and a module mock.
 * This pins the ARITHMETIC that made its missing guard dangerous, so the
 * consequence is documented in a form that runs.
 *
 * lib/custody-onchain.ts read `vesting` and `insurance` without checking them.
 * `normalise` returns the zero address for an unset env var and
 * `balanceOf(0x0)` returns zero rather than reverting, so an unset vesting
 * address fed 0 into custodyFrom. Circulating is the remainder, so it absorbed
 * the whole 800,000,000 and the page would have published 88% circulating,
 * labelled as measured from chain.
 */
test('a zero vesting balance inflates circulating to 88%, which is why every address is now checked', () => {
  const rows = custodyFrom({ vesting: 0, safe: 96_311_116, insurance: 40_000_000 });
  const circulating = rows.find((c) => c.label === 'Circulating')!.tokens;

  assert.equal(circulating, 880_000_000);
  assert.equal((circulating / TOKEN.maxSupply) * 100, 88);
  // Still internally consistent, which is exactly what made it dangerous:
  // nothing about the table looks wrong.
  assert.equal(rows.reduce((s, c) => s + c.tokens, 0), TOKEN.maxSupply);
});

test('the real balances give 8%, so the two are impossible to confuse by eye', () => {
  const rows = custodyFrom(LAST_MEASURED);
  const circulating = rows.find((c) => c.label === 'Circulating')!.tokens;
  assert.equal((circulating / TOKEN.maxSupply) * 100, 8);
});

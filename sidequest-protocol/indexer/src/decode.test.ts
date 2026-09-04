/**
 * The indexer's first tests.
 *
 * It writes the receipt feed, which is the whole "every rebalance is a public,
 * verifiable receipt" claim, and nothing exercised it. The bug that survived
 * there was `tokenLegs`: decoded from every rotation rebalance and dropped, so
 * those receipts stored a basketCommitment that could not be recomputed from
 * the row. Most of what follows is aimed at the seam where that happened --
 * three vault types sharing one event name and agreeing on almost nothing.
 */

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { planWindows, toRebalanceRow, type DecodedLog } from './decode.js';

const SPOT = { address: '0xspot', vault_type: 'spot' as const, manager_address: '0xmgr' };
const ROT = { address: '0xrot', vault_type: 'rotation' as const, manager_address: '0xmgr' };
const YIELD = { address: '0xyield', vault_type: 'yield' as const, manager_address: '0xmgr' };

const TS = '2026-09-04T00:00:00.000Z';

function log(args: Record<string, unknown>): DecodedLog {
  return { args, blockNumber: 112_522_645n, transactionHash: '0xtx', logIndex: 3 };
}

// ─── planWindows ────────────────────────────────────────────────────────────

test('planWindows covers the range with no gap and no overlap', () => {
  const w = planWindows(100n, 1000n, 250n);
  assert.equal(w[0][0], 100n);
  assert.equal(w[w.length - 1][1], 1000n);
  for (let i = 1; i < w.length; i++) {
    assert.equal(w[i][0], w[i - 1][1] + 1n, 'a block would be skipped or indexed twice');
  }
});

test('planWindows caps at 20 so a first run still reaches the live tail', () => {
  // A chain already 111m blocks deep, scanned 1k at a time, is 111,000 windows.
  const w = planWindows(1n, 111_000_000n, 1_000n);
  assert.equal(w.length, 20, 'an uncapped plan never finishes its first cycle');
});

test('planWindows returns nothing when the cursor is past the head', () => {
  assert.deepEqual(planWindows(500n, 499n, 100n), []);
});

test('planWindows handles a range smaller than one window', () => {
  assert.deepEqual(planWindows(10n, 12n, 1_000n), [[10n, 12n]]);
});

// ─── The bug this file exists for ───────────────────────────────────────────

test('a rotation receipt carries the token legs its commitment binds', () => {
  const row = toRebalanceRow(
    ROT,
    log({
      targetBps: [10000, 0, 0],
      navInBase: 1_000_000n,
      tokenLegs: [5_000_000n, 1_000_000_000_000_000_000n, 0n],
      baseLeg: 5_000_000n,
      nonce: 1n,
      commitment: '0xc0ffee',
    }),
    TS,
  );

  assert.deepEqual(
    row.token_legs,
    ['5000000', '1000000000000000000', '0'],
    'basketCommitment cannot be recomputed without these',
  );
});

test('token legs stay strings, because a JSON number would round them', () => {
  // 18 decimals plus change. As a double this becomes 1234567890123456800000.
  const exact = 1_234_567_890_123_456_789_012n;
  const row = toRebalanceRow(ROT, log({ targetBps: [10000], tokenLegs: [exact] }), TS);

  const legs = row.token_legs as string[];
  assert.equal(legs[0], '1234567890123456789012');
  assert.notEqual(
    legs[0],
    String(Number(exact)),
    'stored as a number, the low digits are gone and the hash never matches',
  );
});

test('spot and yield receipts have no token legs to carry', () => {
  assert.equal(toRebalanceRow(SPOT, log({ targetBps: 5000 }), TS).token_legs, null);
  assert.equal(toRebalanceRow(YIELD, log({ navPerShare: 1n }), TS).token_legs, null);
});

// ─── The three events agree on a name and nothing else ──────────────────────

test('targetBps is a number on spot and an array on rotation', () => {
  const spot = toRebalanceRow(SPOT, log({ targetBps: 5000 }), TS);
  assert.equal(spot.target_bps, 5000);
  assert.equal(spot.target_weights, null);

  const rot = toRebalanceRow(ROT, log({ targetBps: [6000, 4000] }), TS);
  assert.equal(rot.target_bps, null);
  assert.deepEqual(rot.target_weights, [6000, 4000]);
});

test('NAV arrives as navPerShare on spot and yield, navInBase on rotation', () => {
  assert.equal(toRebalanceRow(SPOT, log({ navPerShare: 1_00000000n }), TS).nav_per_share, '100000000');
  assert.equal(toRebalanceRow(ROT, log({ navInBase: 1_000_000n }), TS).nav_per_share, '1000000');
  assert.equal(toRebalanceRow(YIELD, log({ navPerShare: 42n }), TS).nav_per_share, '42');
});

test('the legs come from a different field on each vault type', () => {
  const spot = toRebalanceRow(SPOT, log({ assetLeg: 7n, cashLeg: 8n }), TS);
  assert.equal(spot.asset_leg, '7');
  assert.equal(spot.cash_leg, '8');

  const rot = toRebalanceRow(ROT, log({ baseLeg: 9n }), TS);
  assert.equal(rot.asset_leg, null, 'a basket has no single asset leg');
  assert.equal(rot.cash_leg, '9');

  const yld = toRebalanceRow(YIELD, log({ totalAssetsInAdapter: 10n, adapterBalance: 11n }), TS);
  assert.equal(yld.asset_leg, '10');
  assert.equal(yld.cash_leg, '11');
});

// ─── Attribution ────────────────────────────────────────────────────────────

test('authorship is the configured manager, never the submitter', () => {
  // Submission is permissionless, so the sender is usually a keeper bot.
  // Attributing the trade to it would misstate authorship on a protocol whose
  // entire product is a manager's track record.
  const row = toRebalanceRow(ROT, log({ targetBps: [10000] }), TS);
  assert.equal(row.manager, '0xmgr');
  assert.equal(row.submitter, null);
});

// ─── Degenerate logs ────────────────────────────────────────────────────────

test('a log with no decoded args produces a row rather than throwing', () => {
  // getLogs can hand back an undecodable entry if an ABI drifts. Losing the
  // cycle to an exception would park the cursor and stall the whole feed.
  const row = toRebalanceRow(SPOT, { blockNumber: 1n, transactionHash: '0xa', logIndex: 0 }, TS);
  assert.equal(row.nonce, 0);
  assert.equal(row.commitment, null);
  assert.equal(row.nav_per_share, null);
  assert.equal(row.tx_hash, '0xa');
});

test('identity fields survive so the unique (tx_hash, log_index) key holds', () => {
  const row = toRebalanceRow(SPOT, log({ targetBps: 1 }), TS);
  assert.equal(row.tx_hash, '0xtx');
  assert.equal(row.log_index, 3);
  assert.equal(row.block_number, 112_522_645);
  assert.equal(row.block_timestamp, TS);
});

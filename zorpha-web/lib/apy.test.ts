import { test } from 'node:test';
import assert from 'node:assert/strict';
import { apyFromAccrual, formatApy, SECONDS_PER_YEAR } from './apy';

/**
 * The APY is the number a depositor decides on, so it is worth more care than
 * the display code around it.
 *
 * The anchor cases below are REAL readings taken from Steakhouse USDG
 * (0xBeEff033F34C046626B8D0A041844C5d1A5409dd) on chain 4663, cross-checked
 * three ways at the time they were taken: two independent live-accrual samples
 * (3.7492% and 3.7506%) and the realised share-price growth over the preceding
 * twelve days (3.72%). If a change here moves those numbers, the change is
 * wrong until proven otherwise.
 */

// A pinned reading: block 55267819, 11 seconds after the vault last accrued.
const SAMPLE = {
  storedAssets: 450361619478714n,
  accruedAssets: 450361625260540n, // delta 5,781,826 over 11s
  lastUpdate: 1788626105n,
  now: 1788626116n,
};

test('reproduces the measured gross APY of the live Steakhouse vault', () => {
  const r = apyFromAccrual(SAMPLE, 0);
  assert.ok(r, 'expected a measurable rate');
  // 3.7492% -- agrees with the independent second sample (3.7506%) to 3 s.f.
  assert.ok(Math.abs(r.gross - 0.037492) < 0.000005, `gross was ${r.gross}`);
});

test('a second independent sample agrees to three significant figures', () => {
  // block 55268648, a 1-second window: delta 525,819 on 450,362,673,332,013.
  const r = apyFromAccrual(
    {
      storedAssets: 450362673332013n,
      accruedAssets: 450362673857832n,
      lastUpdate: 1788626610n,
      now: 1788626611n,
    },
    0
  );
  assert.ok(r);
  assert.ok(Math.abs(r.gross - 0.03750) < 0.0001, `gross was ${r.gross}`);
});

test('takes the performance fee off the rate, not off the annualised figure', () => {
  // Compounding after the fee is not the same as discounting the compounded
  // number: 3.3680% here versus 3.3743% if you multiply the APY by 0.9. The
  // fee is charged on gains as they accrue, so it belongs on the rate.
  const r = apyFromAccrual(SAMPLE, 1000);
  assert.ok(r);
  assert.ok(Math.abs(r.net - 0.033680) < 0.000005, `net was ${r.net}`);
  assert.ok(r.net < r.gross);
});

test('a zero fee leaves the depositor the whole gross rate', () => {
  const r = apyFromAccrual(SAMPLE, 0);
  assert.ok(r);
  assert.equal(r.net, r.gross);
});

test('a full fee leaves the depositor nothing', () => {
  const r = apyFromAccrual(SAMPLE, 10_000);
  assert.ok(r);
  assert.equal(r.net, 0);
});

// --- refusing to guess -----------------------------------------------------
//
// Every branch here returns null rather than 0. A vault that cannot be measured
// yet and a vault genuinely paying nothing look identical in these inputs, and
// rendering "0.00%" for the first is the kind of confident wrong number this
// codebase has shipped before.

test('returns null when no time has passed since the last accrual', () => {
  assert.equal(apyFromAccrual({ ...SAMPLE, now: SAMPLE.lastUpdate }, 0), null);
});

test('returns null when the clock is behind the last accrual', () => {
  assert.equal(apyFromAccrual({ ...SAMPLE, now: SAMPLE.lastUpdate - 5n }, 0), null);
});

test('returns null for an empty vault, rather than dividing by zero', () => {
  assert.equal(
    apyFromAccrual({ ...SAMPLE, storedAssets: 0n, accruedAssets: 0n }, 0),
    null
  );
});

test('returns null when the pending interest is below measurement resolution', () => {
  // Integer truncation cannot tell "no yield" from "too small to see yet".
  assert.equal(
    apyFromAccrual({ ...SAMPLE, accruedAssets: SAMPLE.storedAssets }, 0),
    null
  );
});

test('returns null if the accrued figure is somehow below the stored one', () => {
  assert.equal(
    apyFromAccrual({ ...SAMPLE, accruedAssets: SAMPLE.storedAssets - 1n }, 0),
    null
  );
});

test('rejects a fee outside basis points instead of inverting the rate', () => {
  assert.equal(apyFromAccrual(SAMPLE, 10_001), null);
  assert.equal(apyFromAccrual(SAMPLE, -1), null);
});

// --- precision -------------------------------------------------------------

test('keeps precision above 2^53, where Number() would start rounding', () => {
  // An 18-decimal vault holding a million units is 1e24 -- far past the point
  // where converting the operands to Number first silently loses digits.
  const big = {
    storedAssets: 1_000_000n * 10n ** 18n,
    accruedAssets: 1_000_000n * 10n ** 18n + 1_167_108_000_000_000n, // ~1.167e-9/s
    lastUpdate: 0n,
    now: 1n,
  };
  const r = apyFromAccrual(big, 0);
  assert.ok(r);
  assert.ok(Math.abs(r.gross - 0.037492) < 0.00001, `gross was ${r.gross}`);
});

test('annualises over a calendar year of seconds', () => {
  assert.equal(SECONDS_PER_YEAR, 31_536_000);
});

// --- formatting ------------------------------------------------------------

test('formats as a percentage to two places', () => {
  assert.equal(formatApy(0.037492), '3.75%');
  assert.equal(formatApy(0), '0.00%');
  assert.equal(formatApy(0.1), '10.00%');
});

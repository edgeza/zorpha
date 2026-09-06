import { test } from 'node:test';
import assert from 'node:assert/strict';
import { balanceIntervals, type ShareTransfer, allocationFor, SEASON_1_TIERS, type BalanceInterval } from './season-eligibility.js';

const ZERO = '0x0000000000000000000000000000000000000000' as const;
const ALICE = '0x1111111111111111111111111111111111111111' as const;

test('a mint opens an interval that runs to the window end', () => {
  const transfers: ShareTransfer[] = [
    { from: ZERO, to: ALICE, value: 100n, timestamp: 1000 },
  ];
  const got = balanceIntervals(transfers, 5000);
  assert.deepEqual(got.get(ALICE.toLowerCase()), [
    { balance: 100n, start: 1000, end: 5000 },
  ]);
});

test('a burn closes the interval at the burn time', () => {
  const transfers: ShareTransfer[] = [
    { from: ZERO, to: ALICE, value: 100n, timestamp: 1000 },
    { from: ALICE, to: ZERO, value: 100n, timestamp: 3000 },
  ];
  const got = balanceIntervals(transfers, 5000);
  assert.deepEqual(got.get(ALICE.toLowerCase()), [
    { balance: 100n, start: 1000, end: 3000 },
    { balance: 0n, start: 3000, end: 5000 },
  ]);
});

test('a peer transfer debits the sender and credits the receiver', () => {
  const BOB = '0x2222222222222222222222222222222222222222' as const;
  const transfers: ShareTransfer[] = [
    { from: ZERO, to: ALICE, value: 100n, timestamp: 1000 },
    { from: ALICE, to: BOB, value: 40n, timestamp: 2000 },
  ];
  const got = balanceIntervals(transfers, 5000);
  assert.deepEqual(got.get(ALICE.toLowerCase()), [
    { balance: 100n, start: 1000, end: 2000 },
    { balance: 60n, start: 2000, end: 5000 },
  ]);
  assert.deepEqual(got.get(BOB.toLowerCase()), [
    { balance: 40n, start: 2000, end: 5000 },
  ]);
});

test('the zero address never appears as a holder', () => {
  const transfers: ShareTransfer[] = [
    { from: ZERO, to: ALICE, value: 100n, timestamp: 1000 },
  ];
  assert.equal(balanceIntervals(transfers, 5000).has(ZERO.toLowerCase()), false);
});

test('transfers are processed in timestamp order regardless of input order', () => {
  const transfers: ShareTransfer[] = [
    { from: ALICE, to: ZERO, value: 100n, timestamp: 3000 },
    { from: ZERO, to: ALICE, value: 100n, timestamp: 1000 },
  ];
  const got = balanceIntervals(transfers, 5000);
  assert.equal(got.get(ALICE.toLowerCase())?.[0].balance, 100n);
});

const DAY = 86_400;
// 1 share = 1 USDG, scaled from 12 decimal shares to 6 decimal assets.
const flat = (shares: bigint) => shares / 1_000_000n;

test('below the tier 1 minimum earns nothing', () => {
  const spans: BalanceInterval[] = [{ balance: 24_000_000n * 1_000_000n, start: 0, end: 40 * DAY }];
  assert.equal(allocationFor(spans, flat, SEASON_1_TIERS), 0n);
});

test('tier 1 met exactly on both size and duration', () => {
  const spans: BalanceInterval[] = [{ balance: 25_000_000n * 1_000_000n, start: 0, end: 30 * DAY }];
  assert.equal(allocationFor(spans, flat, SEASON_1_TIERS), 15_000n * 10n ** 18n);
});

test('one day short of tier 1 earns nothing', () => {
  const spans: BalanceInterval[] = [{ balance: 25_000_000n * 1_000_000n, start: 0, end: 29 * DAY }];
  assert.equal(allocationFor(spans, flat, SEASON_1_TIERS), 0n);
});

test('tier 2 supersedes tier 1 rather than stacking', () => {
  const spans: BalanceInterval[] = [{ balance: 250_000_000n * 1_000_000n, start: 0, end: 60 * DAY }];
  assert.equal(allocationFor(spans, flat, SEASON_1_TIERS), 40_000n * 10n ** 18n);
});

test('tier 2 size but only tier 1 duration falls back to tier 1', () => {
  const spans: BalanceInterval[] = [{ balance: 250_000_000n * 1_000_000n, start: 0, end: 30 * DAY }];
  assert.equal(allocationFor(spans, flat, SEASON_1_TIERS), 15_000n * 10n ** 18n);
});

test('a withdrawal resets continuity, so two short spans do not add up', () => {
  const spans: BalanceInterval[] = [
    { balance: 25_000_000n * 1_000_000n, start: 0, end: 20 * DAY },
    { balance: 0n, start: 20 * DAY, end: 21 * DAY },
    { balance: 25_000_000n * 1_000_000n, start: 21 * DAY, end: 41 * DAY },
  ];
  assert.equal(allocationFor(spans, flat, SEASON_1_TIERS), 0n);
});

test('topping up without dropping below the threshold preserves continuity', () => {
  const spans: BalanceInterval[] = [
    { balance: 25_000_000n * 1_000_000n, start: 0, end: 15 * DAY },
    { balance: 30_000_000n * 1_000_000n, start: 15 * DAY, end: 31 * DAY },
  ];
  assert.equal(allocationFor(spans, flat, SEASON_1_TIERS), 15_000n * 10n ** 18n);
});

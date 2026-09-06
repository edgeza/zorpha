import { test } from 'node:test';
import assert from 'node:assert/strict';
import { balanceIntervals, type ShareTransfer } from './season-eligibility.js';

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

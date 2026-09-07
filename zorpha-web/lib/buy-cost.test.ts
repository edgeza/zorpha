import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  quoteBuy,
  depthForSlippage,
  poolIsDeepEnough,
  BUY_PAGE_MIN_DEPTH_USD,
  type PoolReserves,
} from './buy-cost.js';

const ZOR = (whole: number) => BigInt(Math.round(whole)) * 10n ** 18n;
const USDG = (whole: number) => BigInt(Math.round(whole * 1e6));

/**
 * The live pool as measured on 6 September 2026. Anchoring the tests on real
 * reserves rather than round numbers means a regression in the curve shows up
 * as a figure someone can compare against the chain.
 */
const LIVE: PoolReserves = { zor: ZOR(36_255_384), usdg: USDG(572.42) };

test('an empty pool has no price rather than a free trade', () => {
  assert.equal(quoteBuy({ zor: 0n, usdg: 0n }, USDG(100)), null);
  assert.equal(quoteBuy({ zor: ZOR(1000), usdg: 0n }, USDG(100)), null);
});

test('a zero buy has no cost', () => {
  assert.equal(quoteBuy(LIVE, 0n), null);
  assert.equal(quoteBuy(LIVE, -1n), null);
});

test('spot price matches the reserve ratio', () => {
  const q = quoteBuy(LIVE, USDG(100))!;
  assert.ok(Math.abs(q.spot - 572.42 / 36_255_384) < 1e-12, `spot was ${q.spot}`);
});

test('a 100 dollar buy against the live pool costs roughly 17 percent', () => {
  const q = quoteBuy(LIVE, USDG(100))!;
  assert.ok(q.slippage > 0.15 && q.slippage < 0.2, `slippage was ${q.slippage}`);
});

test('slippage rises with size, which is the whole reason the page is gated', () => {
  const sizes = [25, 100, 500, 1000].map((u) => quoteBuy(LIVE, USDG(u))!.slippage);
  for (let i = 1; i < sizes.length; i++) {
    assert.ok(sizes[i] > sizes[i - 1], `slippage did not rise from ${sizes[i - 1]} to ${sizes[i]}`);
  }
  // A thousand dollars into 572 of depth is catastrophic, not marginal.
  assert.ok(sizes[3] > 1, `1000 dollar slippage was only ${sizes[3]}`);
});

test('a deep pool makes the same buy nearly free', () => {
  const deep: PoolReserves = { zor: ZOR(36_255_384), usdg: USDG(1_000_000) };
  const q = quoteBuy(deep, USDG(100))!;
  assert.ok(q.slippage < 0.005, `slippage was ${q.slippage}`);
});

test('the effective price is always worse than spot, never better', () => {
  for (const u of [1, 25, 100, 10_000]) {
    const q = quoteBuy(LIVE, USDG(u))!;
    assert.ok(q.effective > q.spot, `at ${u} dollars effective ${q.effective} <= spot ${q.spot}`);
  }
});

test('the pool fee is charged, so a fee-free curve would return more', () => {
  const q = quoteBuy(LIVE, USDG(100))!;
  // Recompute without the 0.3% fee; it must be strictly more ZOR.
  const k = LIVE.zor * LIVE.usdg;
  const noFee = LIVE.zor - k / (LIVE.usdg + USDG(100));
  assert.ok(noFee > q.out, 'fee was not deducted from the input');
});

test('output never exceeds the pool balance', () => {
  const q = quoteBuy(LIVE, USDG(10_000_000))!;
  assert.ok(q.out < LIVE.zor, 'a swap drained or overdrew the pool');
});

test('depth needed scales with the buy and inversely with the budget', () => {
  assert.equal(depthForSlippage(100, 0.02), 5_000);
  assert.equal(depthForSlippage(100, 0.01), 10_000);
  assert.equal(depthForSlippage(1000, 0.02), 50_000);
  assert.equal(depthForSlippage(0, 0.02), 0);
  assert.equal(depthForSlippage(100, 0), 0);
});

test('the live pool does not clear the gate, and a funded one does', () => {
  assert.equal(poolIsDeepEnough(LIVE), false);
  assert.equal(poolIsDeepEnough({ zor: LIVE.zor, usdg: USDG(BUY_PAGE_MIN_DEPTH_USD) }), true);
  assert.equal(poolIsDeepEnough({ zor: LIVE.zor, usdg: USDG(BUY_PAGE_MIN_DEPTH_USD - 1) }), false);
});

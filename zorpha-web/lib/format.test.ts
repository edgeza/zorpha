import { test } from 'node:test';
import assert from 'node:assert/strict';
import { formatUnits, parseUnits, formatAddress, bpsToPct } from './format';

/**
 * The portal had no tests at all. These cover the two functions that decide how
 * much money moves and what a depositor is told they own, because every display
 * bug this project has shipped has been a decimals bug:
 *
 *   - a rotation NAV of 1.0 rendered as 0.00000 on the public feed, because a
 *     6-decimal value was divided by 10^18
 *   - the live vaults mint shares at 24 decimals, not 18, so anything assuming
 *     18 is out by a factor of a million
 *
 * parseUnits is the sharper edge of the two. formatUnits being wrong shows a
 * depositor a number they can dispute; parseUnits being wrong sends an amount
 * they did not choose.
 */

// --- formatUnits ---------------------------------------------------------

test('formats at the scale it is given, not a default', () => {
  // The exact pair that shipped broken: 1.0 in 6-decimal units.
  assert.equal(formatUnits(1_000_000n, 6), '1');
  assert.equal(formatUnits(1_000_000n, 18), '0');
});

test('handles the 24-decimal shares the live vaults actually mint', () => {
  // 100 tAAPL deposited mints 1e26 shares against an 18dp asset: a 6-place
  // decimals offset. Reading those as 18dp gives a hundred million.
  assert.equal(formatUnits(10n ** 26n, 24), '100');
  assert.equal(formatUnits(10n ** 26n, 18), '100,000,000');
});

test('renders a missing value as a dash rather than a zero', () => {
  // A dash says "unknown". A zero says "worthless", and on a receipts feed that
  // is a false statement about a manager rather than a gap.
  assert.equal(formatUnits(null, 18), '—');
  assert.equal(formatUnits(undefined, 18), '—');
  assert.equal(formatUnits('not a number', 18), '—');
});

test('trims trailing zeros but keeps significant ones', () => {
  assert.equal(formatUnits(1_500_000n, 6), '1.5');
  assert.equal(formatUnits(1_050_000n, 6), '1.05');
  assert.equal(formatUnits(1_000_000n, 6), '1');
});

test('truncates rather than rounds, so a balance is never overstated', () => {
  // 1.99999 at four places must not become 2.0 next to a Max button.
  assert.equal(formatUnits(1_999_999n, 6, 4), '1.9999');
});

test('groups thousands and respects zero fraction digits', () => {
  assert.equal(formatUnits(1_234_567_000_000n, 6), '1,234,567');
  assert.equal(formatUnits(1_500_000n, 6, 0), '1');
});

test('keeps the sign on a negative value', () => {
  assert.equal(formatUnits(-1_500_000n, 6), '-1.5');
});

// --- parseUnits ----------------------------------------------------------

test('scales what the user typed to the token decimals', () => {
  assert.equal(parseUnits('1', 6), 1_000_000n);
  assert.equal(parseUnits('1.5', 6), 1_500_000n);
  assert.equal(parseUnits('0.000001', 6), 1n);
  assert.equal(parseUnits('1', 24), 10n ** 24n);
});

test('REFUSES more precision than the token has, rather than truncating', () => {
  // The important one. Truncating 1.9999999 on a 6-decimal token would send
  // 1.999999 while the user believes they sent what they typed. Returning null
  // makes the UI refuse the input instead.
  assert.equal(parseUnits('1.9999999', 6), null);
  assert.equal(parseUnits('0.0000001', 6), null);
  assert.equal(parseUnits('1.9999999', 18), 1_999_999_900_000_000_000n);
});

test('refuses anything that is not a plain decimal number', () => {
  for (const bad of ['', '  ', 'abc', '1e18', '-1', '1,000', '0x10', '1.2.3', '1 000']) {
    assert.equal(parseUnits(bad, 18), null, `accepted ${JSON.stringify(bad)}`);
  }
});

test('accepts the shapes a real input box produces', () => {
  assert.equal(parseUnits('.5', 6), 500_000n);
  assert.equal(parseUnits('1.', 6), 1_000_000n);
  assert.equal(parseUnits('  1.5  ', 6), 1_500_000n);
  assert.equal(parseUnits('0', 6), 0n);
});

test('survives a balance larger than a JS number can hold', () => {
  // 1e9 tokens at 18dp is 1e27, far past Number.MAX_SAFE_INTEGER. Anything
  // routing through a float here loses precision silently.
  const huge = '1000000000';
  assert.equal(parseUnits(huge, 18), 10n ** 27n);
  assert.equal(formatUnits(parseUnits(huge, 18)!, 18, 0), '1,000,000,000');
});

test('round-trips a Max button through both directions', () => {
  // What Max does: read a raw balance, show it, and send back what was shown.
  const balance = 123_456_789n;               // 123.456789 of a 6dp token
  const shown = formatUnits(balance, 6, 6);
  assert.equal(shown, '123.456789');
  assert.equal(parseUnits(shown, 6), balance);
});

// --- the small ones that appear on every page ----------------------------

test('shortens an address without hiding which one it is', () => {
  const a = '0xaA7A513F2B4C35d727b16fc7233CC8C9faCE886F';
  assert.equal(formatAddress(a), '0xaA7A…886F');
  assert.equal(formatAddress(null), '—');
});

test('converts basis points the way the contracts mean them', () => {
  assert.equal(bpsToPct(10000), '100.00%');
  assert.equal(bpsToPct(1000), '10.00%');     // the vault performance fee
  assert.equal(bpsToPct(100), '1.00%');       // maxSlippageBps
  assert.equal(bpsToPct(0), '0.00%');
});

// --- the Max button invariant ---------------------------------------------
//
// VaultActions now disables the submit button when the typed amount exceeds
// the wallet's balance, which stops a depositor paying gas for a transfer that
// reverts. That guard is only safe if "Max" cannot itself produce a rejected
// amount, and Max fills the field with formatUnits(balance, decimals, 6).
//
// So the round trip has to be lossy DOWNWARD, never upward. formatUnits
// truncates the fraction rather than rounding it, and these pin that: a change
// to rounding would silently make Max un-submittable at exactly the moment
// someone tries to withdraw everything.

test('Max never re-parses to more than the balance it came from', () => {
  const cases: [bigint, number][] = [
    [1_234_567_890_123_456_789n, 18], // fraction past six places
    [999_999_999_999_999_999n, 18], // all nines, the rounding trap
    [4_925_501n, 6], // the real USDG balance
    [4_925_501_000_000n, 12], // 12dp vault shares
    [1n, 18], // one wei
  ];
  for (const [balance, decimals] of cases) {
    const shown = formatUnits(balance, decimals, 6);
    const reparsed = parseUnits(shown.replace(/,/g, ''), decimals);
    assert.ok(reparsed !== null, `Max produced something unparseable: ${shown}`);
    assert.ok(
      (reparsed as bigint) <= balance,
      `Max re-parsed above the balance: ${shown} -> ${reparsed} > ${balance}`,
    );
  }
});

test('formatUnits truncates the fraction rather than rounding it up', () => {
  // 0.9999999 at 6 places is 0.999999, not 1. Rounding here is what would
  // break the invariant above.
  assert.equal(formatUnits(999_999_900_000_000_000n, 18, 6), '0.999999');
});

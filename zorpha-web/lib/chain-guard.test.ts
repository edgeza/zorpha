import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  evaluateChainIdResponse,
  checkServerChain,
  assertServerChain,
  ChainMismatchError,
  __resetChainGuardCache,
  type FetchLike,
} from './chain-guard';
import { activeChain } from './chains';

/**
 * The guard's whole job is to tell three states apart, and getting any two of
 * them confused is worse than not having it:
 *
 *   - agreement        -> render
 *   - disagreement     -> refuse, because the page would be confidently wrong
 *   - no answer at all -> render, because the page is only stale
 *
 * The third is the one that matters most in practice. Treating an outage as a
 * mismatch would take the portal down every time a node hiccups, which is a
 * worse outcome than the bug this guard exists to prevent.
 */

const URL_ = 'https://rpc.example/rpc';

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json' },
  });
}

// --- evaluateChainIdResponse ---------------------------------------------

test('agreement is ok', () => {
  // 0x1237 is 4663, mainnet.
  const v = evaluateChainIdResponse(4663, URL_, { jsonrpc: '2.0', id: 1, result: '0x1237' });
  assert.equal(v.status, 'ok');
});

test('the one-digit transposition is caught, in both directions', () => {
  // This is the actual failure mode: 4663 and 46630 differ by one digit, and a
  // Railway config once carried CHAIN_ID=4663 beside a testnet RPC.
  const a = evaluateChainIdResponse(4663, URL_, { result: '0xb626' }); // 46630
  assert.equal(a.status, 'mismatch');
  assert.deepEqual(
    a.status === 'mismatch' ? [a.expected, a.actual] : null,
    [4663, 46630],
  );

  const b = evaluateChainIdResponse(46630, URL_, { result: '0x1237' }); // 4663
  assert.equal(b.status, 'mismatch');
  assert.deepEqual(
    b.status === 'mismatch' ? [b.expected, b.actual] : null,
    [46630, 4663],
  );
});

test('a JSON-RPC error is unreachable, NOT a mismatch', () => {
  // We learned nothing about which chain is on the other end. Claiming the
  // config is wrong on this evidence would dark the portal over a node fault.
  const v = evaluateChainIdResponse(4663, URL_, {
    jsonrpc: '2.0',
    id: 1,
    error: { code: -32602, message: 'Archive requests require a personal token' },
  });
  assert.equal(v.status, 'unreachable');
});

test('a proxy returning HTML is unreachable, not a mismatch', () => {
  assert.equal(evaluateChainIdResponse(4663, URL_, '<html>502</html>').status, 'unreachable');
  assert.equal(evaluateChainIdResponse(4663, URL_, null).status, 'unreachable');
  assert.equal(evaluateChainIdResponse(4663, URL_, { result: 'nonsense' }).status, 'unreachable');
});

// --- checkServerChain ----------------------------------------------------

test('a timeout or DNS failure renders rather than throwing', async () => {
  __resetChainGuardCache();
  const boom: FetchLike = async () => {
    throw new Error('The operation was aborted due to timeout');
  };
  const v = await checkServerChain(boom, () => 1_000);
  assert.equal(v.status, 'unreachable');
  assert.match(v.status === 'unreachable' ? v.reason : '', /timeout/i);
});

test('a non-200 is unreachable and carries the status', async () => {
  __resetChainGuardCache();
  const five0two: FetchLike = async () => new Response('bad gateway', { status: 502 });
  const v = await checkServerChain(five0two, () => 1_000);
  assert.equal(v.status, 'unreachable');
  assert.equal(v.status === 'unreachable' ? v.reason : '', 'HTTP 502');
});

test('a verdict is reused inside the TTL, so a render storm is not a request storm', async () => {
  __resetChainGuardCache();
  let calls = 0;
  const counting: FetchLike = async () => {
    calls += 1;
    return jsonResponse({ result: '0x' + activeChain.id.toString(16) });
  };

  let clock = 10_000;
  await checkServerChain(counting, () => clock);
  await checkServerChain(counting, () => clock);
  clock += 59_000; // still inside the 60s window
  await checkServerChain(counting, () => clock);
  assert.equal(calls, 1, 'three renders inside the TTL should be one RPC call');

  clock += 2_000; // now past it
  await checkServerChain(counting, () => clock);
  assert.equal(calls, 2, 'the verdict must expire, or a fixed RPC never gets noticed');
});

test('a mismatch is never cached, so the fix takes effect immediately', async () => {
  __resetChainGuardCache();
  // A cached mismatch would keep the portal dark for a further TTL after the
  // config is corrected, which reads to an operator as "the fix did not work".
  const wrong = activeChain.id === 4663 ? 46630 : 4663;
  let calls = 0;
  const flipping: FetchLike = async () => {
    calls += 1;
    return jsonResponse({ result: '0x' + (calls === 1 ? wrong : activeChain.id).toString(16) });
  };

  const first = await checkServerChain(flipping, () => 5_000);
  assert.equal(first.status, 'mismatch');

  // Same instant, so a cached verdict would be returned if we cached it.
  const second = await checkServerChain(flipping, () => 5_000);
  assert.equal(second.status, 'ok');
  assert.equal(calls, 2);
});

// --- assertServerChain ---------------------------------------------------

test('assertServerChain throws only on a mismatch, and names both chains', async () => {
  __resetChainGuardCache();
  const wrong = activeChain.id === 4663 ? 46630 : 4663;
  const bad: FetchLike = async () => jsonResponse({ result: '0x' + wrong.toString(16) });

  await assert.rejects(
    () => assertServerChain(bad, () => 20_000),
    (err: unknown) => {
      assert.ok(err instanceof ChainMismatchError);
      // Both ids must appear. An error naming only one is useless for the exact
      // confusion it exists to resolve.
      assert.match(err.message, new RegExp(String(activeChain.id)));
      assert.match(err.message, new RegExp(String(wrong)));
      assert.match(err.message, /ONE DIGIT/);
      assert.equal(err.expected, activeChain.id);
      assert.equal(err.actual, wrong);
      return true;
    },
  );
});

test('assertServerChain returns rather than throws when the RPC is simply down', async () => {
  __resetChainGuardCache();
  let called = 0;
  const down: FetchLike = async () => {
    called += 1;
    return new Response('', { status: 503 });
  };

  const v = await assertServerChain(down, () => 30_000);
  assert.equal(v.status, 'unreachable');
  assert.equal(called, 1, 'must have actually asked, not short-circuited');
});

/**
 * The startup guard, tested without a chain.
 *
 * These cover the wiring rather than the checks themselves -- `orbit-preflight`
 * has its own suite for those. What matters here is that this service asks the
 * right questions of the right endpoints, and that a failure says something an
 * operator can act on at 2am.
 *
 * The first test is the regression that motivated the change: the previous
 * implementation ran its checks through viem's `fallback` transport, which
 * consults a fallback only when the primary fails. A fallback pointed at the
 * other Robinhood Chain deployment therefore passed every check by never being
 * asked, and then served testnet data the first time the primary blipped.
 */

import { test } from 'node:test';
import assert from 'node:assert/strict';

// `config` reads the environment at import time and throws without it, so the
// module under test is imported dynamically after this block.
process.env.DRY_RUN = '1';
process.env.CHAIN_ID = '4663';
process.env.RPC_URL = 'https://primary.test';
process.env.RPC_URL_FALLBACK = 'https://fallback.test';
process.env.START_BLOCK = '100';

const { assertChainPreflight } = await import('./chain.js');

const VAULT = '0x3829bC787d4eB15Ec855A6cA33e1492a9103d130';
const MAINNET_HEAD = 55_200_000n;

type Behaviour = {
  /** The chain id this endpoint claims, or 'down' to refuse the connection. */
  chainId: number | 'down';
  head?: bigint;
  /** False makes historic eth_getLogs return the real archive refusal. */
  archive?: boolean;
  /** Address -> bytecode. Anything unlisted has code. */
  code?: Record<string, string>;
};

function transport(byUrl: Record<string, Behaviour>) {
  const json = (result: unknown) =>
    new Response(JSON.stringify({ jsonrpc: '2.0', id: 1, result }), {
      status: 200,
      headers: { 'content-type': 'application/json' },
    });
  const rpcError = (code: number, message: string) =>
    new Response(JSON.stringify({ jsonrpc: '2.0', id: 1, error: { code, message } }), {
      status: 200,
      headers: { 'content-type': 'application/json' },
    });

  return {
    fetchImpl: async (url: string, init?: RequestInit): Promise<Response> => {
      const b = byUrl[url];
      if (!b || b.chainId === 'down') throw new Error('connect ECONNREFUSED');

      const { method, params } = JSON.parse(String(init?.body)) as {
        method: string;
        params: unknown[];
      };

      switch (method) {
        case 'eth_chainId':
          return json(`0x${b.chainId.toString(16)}`);
        case 'eth_blockNumber':
          return json(`0x${(b.head ?? MAINNET_HEAD).toString(16)}`);
        case 'eth_getLogs':
          return b.archive === false
            ? rpcError(-32602, 'Archive requests require a personal token')
            : json([]);
        case 'eth_getCode':
          return json(b.code?.[params[0] as string] ?? '0x60806040');
        default:
          return json(null);
      }
    },
  };
}

const healthy: Behaviour = { chainId: 4663 };

async function rejection(promise: Promise<unknown>): Promise<Error> {
  try {
    await promise;
  } catch (error) {
    return error as Error;
  }
  throw new Error('expected preflight to reject, but it resolved');
}

// --- the regression this change exists for --------------------------------

test('a fallback pointed at the other chain is fatal, even while the primary is healthy', async () => {
  const error = await rejection(
    assertChainPreflight(
      [VAULT],
      transport({
        'https://primary.test': healthy,
        'https://fallback.test': { chainId: 46630 }, // testnet
      }),
    ),
  );
  assert.match(error.message, /chain-id-mismatch/);
  assert.match(error.message, /fallback\.test/);
  // The old implementation never asked this endpoint anything.
});

test('every configured endpoint is examined, not just the one that answers first', async () => {
  const report = await assertChainPreflight(
    [VAULT],
    transport({ 'https://primary.test': healthy, 'https://fallback.test': healthy }),
  );
  assert.equal(report.rpcs.length, 2);
  assert.deepEqual(
    report.rpcs.map((r) => r.url).sort(),
    ['https://fallback.test', 'https://primary.test'],
  );
});

// --- the failure that actually happened ------------------------------------

test('an endpoint with the right chain id that cannot serve archive is fatal', async () => {
  const error = await rejection(
    assertChainPreflight(
      [VAULT],
      transport({
        'https://primary.test': healthy,
        // Answers 4663 correctly, refuses the only query an indexer makes.
        'https://fallback.test': { chainId: 4663, archive: false },
      }),
    ),
  );
  assert.match(error.message, /rpc-cannot-serve-archive/);
  assert.match(error.message, /historic eth_getLogs/);
});

// --- a misconfiguration and an outage are different failures ---------------

test('an unreachable endpoint is a warning and does not stop startup', async () => {
  const report = await assertChainPreflight(
    [VAULT],
    transport({ 'https://primary.test': healthy, 'https://fallback.test': { chainId: 'down' } }),
  );
  assert.ok(report.ok, 'an outage must not be fatal');
  assert.ok(
    report.findings.some((f) => f.code === 'rpc-unreachable' && f.severity === 'warning'),
    'the unreachable endpoint should still be reported',
  );
});

// --- the guidance the generic package cannot supply ------------------------

test('a chain id mismatch names the RPC_URL that would be correct', async () => {
  const error = await rejection(
    assertChainPreflight(
      [VAULT],
      transport({
        'https://primary.test': { chainId: 46630 },
        'https://fallback.test': { chainId: 46630 },
      }),
    ),
  );
  assert.match(error.message, /use RPC_URL=https:\/\/rpc\.mainnet\.chain\.robinhood\.com\/rpc/);
  assert.match(error.message, /differ by one digit/);
});

test('a START_BLOCK past the head explains what a transposed height looks like', async () => {
  // START_BLOCK is 100; a head of 50 puts it beyond the tip.
  const error = await rejection(
    assertChainPreflight(
      [],
      transport({
        'https://primary.test': { chainId: 4663, head: 50n },
        'https://fallback.test': { chainId: 4663, head: 50n },
      }),
    ),
  );
  assert.match(error.message, /start-block-beyond-head/);
  assert.match(error.message, /testnet heights are ~113M, mainnet ~55M/);
});

test('a vault address with no code points at the other deployment', async () => {
  const error = await rejection(
    assertChainPreflight(
      [VAULT],
      transport({
        'https://primary.test': { chainId: 4663, code: { [VAULT]: '0x' } },
        'https://fallback.test': healthy,
      }),
    ),
  );
  assert.match(error.message, /address-has-no-code/);
  assert.match(error.message, /other Robinhood/);
});

// --- the happy path --------------------------------------------------------

test('a correct configuration passes and reports what it saw', async () => {
  const report = await assertChainPreflight(
    [VAULT],
    transport({ 'https://primary.test': healthy, 'https://fallback.test': healthy }),
  );
  assert.ok(report.ok);
  assert.equal(report.findings.length, 0);
  assert.equal(report.head, MAINNET_HEAD);
  assert.equal(report.rpcs.filter((r) => r.servesArchive === true).length, 2);
});

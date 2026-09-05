import { test } from 'node:test';
import assert from 'node:assert/strict';
import { preflight, assertPreflight, PreflightError } from './preflight.js';
import type { FetchLike } from './rpc.js';

/**
 * Every test here encodes a failure that was observed on a live mainnet, not a
 * hypothetical. The ones that matter most are the negative cases: an outage
 * must NOT be reported as a misconfiguration, because a guard that fires on a
 * node hiccup is a guard someone disables.
 */

const MAINNET = 4663;
const TESTNET = 46630;
const hex = (n: number | bigint) => '0x' + n.toString(16);

/** Build a fake endpoint from a method -> response map. */
function node(responses: Record<string, unknown>, opts: { fail?: string } = {}): FetchLike {
  return async (_url, init) => {
    const body = JSON.parse(String(init?.body));
    if (opts.fail) return new Response(opts.fail, { status: 502 });
    if (!(body.method in responses)) {
      return Response.json({ jsonrpc: '2.0', id: 1, error: { code: -32601, message: 'method not found' } });
    }
    const v = responses[body.method];
    if (v instanceof Error) {
      return Response.json({ jsonrpc: '2.0', id: 1, error: { code: -32602, message: v.message } });
    }
    return Response.json({ jsonrpc: '2.0', id: 1, result: v });
  };
}

const healthy = (chainId: number, head = 55_201_684) =>
  node({
    eth_chainId: hex(chainId),
    eth_blockNumber: hex(head),
    eth_getLogs: [],
    eth_getCode: '0x6080604052',
  });

// --- the loud one --------------------------------------------------------

test('a chain id from the other network is fatal, and names both chains', async () => {
  const r = await preflight(
    { chainId: MAINNET, rpcUrls: ['https://rpc.example'] },
    { fetchImpl: healthy(TESTNET) },
  );
  assert.equal(r.ok, false);
  const f = r.findings.find((x) => x.code === 'chain-id-mismatch');
  assert.ok(f, 'expected a chain-id-mismatch finding');
  assert.equal(f.severity, 'fatal');
  assert.match(f.message, /4663/);
  assert.match(f.message, /46630/);
});

// --- the quiet ones ------------------------------------------------------

test('a start block beyond the head is fatal', async () => {
  // 112,522,500 is a testnet height. Mainnet's head is ~55.2M. getLogs over
  // this range returns [] forever and every cycle reports success.
  const r = await preflight(
    { chainId: MAINNET, rpcUrls: ['https://rpc.example'], startBlock: 112_522_500n },
    { fetchImpl: healthy(MAINNET, 55_201_684) },
  );
  assert.equal(r.ok, false);
  assert.ok(r.findings.some((f) => f.code === 'start-block-beyond-head' && f.severity === 'fatal'));
});

test('a start block at or below the head passes', async () => {
  const r = await preflight(
    { chainId: MAINNET, rpcUrls: ['https://rpc.example'], startBlock: 55_038_004n },
    { fetchImpl: healthy(MAINNET, 55_201_684) },
  );
  assert.equal(r.ok, true, JSON.stringify(r.findings));
});

test('an address with no bytecode is fatal', async () => {
  const f = node({
    eth_chainId: hex(MAINNET),
    eth_blockNumber: hex(55_201_684),
    eth_getLogs: [],
    eth_getCode: '0x', // the signature of an address from the other network
  });
  const r = await preflight(
    { chainId: MAINNET, rpcUrls: ['https://rpc.example'], addresses: ['0xaA7A513F'] },
    { fetchImpl: f },
  );
  assert.equal(r.ok, false);
  assert.ok(r.findings.some((x) => x.code === 'address-has-no-code' && x.severity === 'fatal'));
});

test('an endpoint with the right chain id that refuses archive queries is fatal', async () => {
  // Measured against a real public endpoint: eth_chainId returns the correct
  // mainnet id, then eth_getLogs over a range is declined outright.
  const f = node({
    eth_chainId: hex(MAINNET),
    eth_blockNumber: hex(55_201_684),
    eth_getLogs: new Error('Archive requests require a personal token'),
  });
  const r = await preflight({ chainId: MAINNET, rpcUrls: ['https://rpc.example'] }, { fetchImpl: f });
  assert.equal(r.ok, false);
  const finding = r.findings.find((x) => x.code === 'rpc-cannot-serve-archive');
  assert.ok(finding);
  assert.equal(finding.severity, 'fatal');
});

test('archive probing can be turned off for a non-indexing consumer', async () => {
  const f = node({
    eth_chainId: hex(MAINNET),
    eth_blockNumber: hex(55_201_684),
    eth_getLogs: new Error('Archive requests require a personal token'),
  });
  const r = await preflight(
    { chainId: MAINNET, rpcUrls: ['https://rpc.example'], requireArchive: false },
    { fetchImpl: f },
  );
  assert.equal(r.ok, true, 'a front end that never reads logs should not be blocked by this');
});

// --- EVERY endpoint, not just the first ----------------------------------

test('a fallback pointed at the other network is caught, not just the primary', async () => {
  // This is how such a fallback survives review: it is never consulted until
  // the primary blips, and by then nobody is watching.
  let call = 0;
  const twoNodes: FetchLike = async (url, init) => {
    const body = JSON.parse(String(init?.body));
    const isFallback = url.includes('fallback');
    call += 1;
    if (body.method === 'eth_chainId') {
      return Response.json({ jsonrpc: '2.0', id: 1, result: hex(isFallback ? TESTNET : MAINNET) });
    }
    if (body.method === 'eth_blockNumber') {
      return Response.json({ jsonrpc: '2.0', id: 1, result: hex(55_201_684) });
    }
    return Response.json({ jsonrpc: '2.0', id: 1, result: [] });
  };

  const r = await preflight(
    { chainId: MAINNET, rpcUrls: ['https://primary.example', 'https://fallback.example'] },
    { fetchImpl: twoNodes },
  );
  assert.equal(r.ok, false);
  const f = r.findings.find((x) => x.code === 'chain-id-mismatch');
  assert.ok(f);
  assert.match(f.url ?? '', /fallback/);
  assert.ok(call > 2, 'the fallback must actually be probed');
});

// --- outage is NOT misconfiguration --------------------------------------

test('an unreachable endpoint is a warning, never fatal', async () => {
  const dead: FetchLike = async () => {
    throw new Error('The operation was aborted due to timeout');
  };
  const r = await preflight({ chainId: MAINNET, rpcUrls: ['https://rpc.example'] }, { fetchImpl: dead });
  assert.equal(r.ok, true, 'a node hiccup must not refuse startup');
  assert.ok(r.findings.every((f) => f.severity === 'warning'));
  assert.ok(r.findings.some((f) => f.code === 'rpc-unreachable'));
});

test('an HTTP 502 and an HTML error page are outages, not mismatches', async () => {
  for (const impl of [
    node({}, { fail: 'bad gateway' }),
    (async () => new Response('<html>502</html>', { status: 200 })) as FetchLike,
  ]) {
    const r = await preflight({ chainId: MAINNET, rpcUrls: ['https://rpc.example'] }, { fetchImpl: impl });
    assert.equal(r.ok, true);
    assert.ok(!r.findings.some((f) => f.code === 'chain-id-mismatch'));
  }
});

test('a JSON-RPC error on eth_chainId is an outage, not a mismatch', async () => {
  // We learned nothing about which chain answered. Claiming the config is
  // wrong on this evidence would dark the service over a node fault.
  const f = node({ eth_chainId: new Error('rate limited') });
  const r = await preflight({ chainId: MAINNET, rpcUrls: ['https://rpc.example'] }, { fetchImpl: f });
  assert.equal(r.ok, true);
  assert.ok(r.findings.some((x) => x.code === 'rpc-unreachable'));
});

test('start block is not judged when no endpoint reported a head', async () => {
  // Guessing in the dark is how a guard invents a failure that is not there.
  const dead: FetchLike = async () => new Response('', { status: 503 });
  const r = await preflight(
    { chainId: MAINNET, rpcUrls: ['https://rpc.example'], startBlock: 999_999_999n },
    { fetchImpl: dead },
  );
  assert.equal(r.ok, true);
  assert.ok(!r.findings.some((f) => f.code === 'start-block-beyond-head'));
});

// --- assertPreflight -----------------------------------------------------

test('assertPreflight throws on fatal and carries the report', async () => {
  await assert.rejects(
    () => assertPreflight({ chainId: MAINNET, rpcUrls: ['https://rpc.example'] }, { fetchImpl: healthy(TESTNET) }),
    (err: unknown) => {
      assert.ok(err instanceof PreflightError);
      assert.equal(err.report.ok, false);
      assert.match(err.message, /Refusing to start/);
      return true;
    },
  );
});

test('assertPreflight returns the report when only warnings were raised', async () => {
  const dead: FetchLike = async () => new Response('', { status: 503 });
  const r = await assertPreflight({ chainId: MAINNET, rpcUrls: ['https://rpc.example'] }, { fetchImpl: dead });
  assert.equal(r.ok, true);
  assert.ok(r.findings.length > 0);
});

test('a fully healthy deployment produces no findings at all', async () => {
  const r = await preflight(
    {
      chainId: MAINNET,
      rpcUrls: ['https://rpc.example'],
      startBlock: 55_038_004n,
      addresses: ['0x3829bC787d4eB15Ec855A6cA33e1492a9103d130'],
    },
    { fetchImpl: healthy(MAINNET) },
  );
  assert.equal(r.ok, true);
  assert.deepEqual(r.findings, []);
  assert.equal(r.head, 55_201_684n);
});

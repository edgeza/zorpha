import { activeChain } from './chains';

/**
 * The check the indexer has and the web app did not.
 *
 * `indexer/src/chain.ts:154` refuses to index when the RPC's chain id disagrees
 * with CHAIN_ID, "because a misconfigured URL would otherwise poison the
 * database with another chain's data, which is far harder to detect after the
 * fact than at startup". The portal had no equivalent, and it is the asymmetry
 * between those two that reached users: `www.zorpha.xyz/portal/vaults`
 * advertised three testnet vaults to mainnet visitors, all three of which
 * return `0x` for `eth_getCode` on 4663. Someone who picked one and deposited
 * would have been sending funds at an empty address.
 *
 * Migrations 011 and 012 fixed the half of that bug that lived in the database.
 * This is the other half: the app now refuses to RENDER a chain it cannot
 * confirm it is talking to, the way the indexer refuses to WRITE one.
 *
 * WHY A MISMATCH IS FATAL AND AN OUTAGE IS NOT
 *
 * These are different failures and deserve different answers.
 *
 * A mismatch means the configuration is lying. Every address on the page comes
 * from a build-time chain id, every balance beside it from whatever the RPC
 * answers, and when those disagree the page is a confident, wrong document
 * about someone's money. Refusing to render is the only safe response.
 *
 * An unreachable RPC means the page is stale, not wrong. Throwing on it would
 * take the whole portal down every time a node hiccups -- trading a real
 * outage for a cosmetic one -- so this reports and renders. `EnvBanner`
 * already surfaces browser-side unreachability to the reader.
 */

/** Milliseconds a verdict is reused before the RPC is asked again. */
const TTL_MS = 60_000;

/**
 * How long to wait on the RPC before giving up.
 *
 * Bounded deliberately: this runs inside a server render, so a hung endpoint
 * without a timeout is a hung page. Five seconds is far longer than a healthy
 * `eth_chainId` needs and far shorter than a reader will wait.
 */
const TIMEOUT_MS = 5_000;

export type ChainVerdict =
  | { status: 'ok'; chainId: number; url: string }
  | { status: 'mismatch'; expected: number; actual: number; url: string }
  | { status: 'unreachable'; expected: number; url: string; reason: string };

export class ChainMismatchError extends Error {
  readonly expected: number;
  readonly actual: number;
  readonly url: string;

  constructor(v: Extract<ChainVerdict, { status: 'mismatch' }>) {
    super(
      `Refusing to render: NEXT_PUBLIC_CHAIN_ID says ${v.expected} but ${v.url} ` +
        `serves ${v.actual}. Robinhood Chain ids differ by ONE DIGIT -- 4663 is ` +
        `mainnet, 46630 is testnet -- so this is almost certainly a transposed ` +
        `digit or an RPC URL from the other deployment. Every contract address ` +
        `on this page comes from the chain id and every balance from the RPC; ` +
        `while they disagree the portal would be a confident, wrong document ` +
        `about someone's funds.`,
    );
    this.name = 'ChainMismatchError';
    this.expected = v.expected;
    this.actual = v.actual;
    this.url = v.url;
  }
}

/**
 * Turn an `eth_chainId` response body into a verdict.
 *
 * Split out from the request so the interesting cases -- a hex id, a JSON-RPC
 * error, a proxy returning HTML -- are testable without a network.
 */
export function evaluateChainIdResponse(
  expected: number,
  url: string,
  body: unknown,
): ChainVerdict {
  const result = (body as { result?: unknown } | null)?.result;

  if (typeof result !== 'string' || !/^0x[0-9a-fA-F]+$/.test(result)) {
    // Anything that is not a hex quantity means we did not reach a working
    // JSON-RPC endpoint: a gateway error page, an auth wall, a JSON-RPC error
    // object. That is an outage, not a mismatch -- we learned nothing about
    // which chain is on the other end, so we must not claim it is wrong.
    return {
      status: 'unreachable',
      expected,
      url,
      reason: `expected a hex chain id, got ${JSON.stringify(result) ?? 'nothing'}`,
    };
  }

  const actual = Number.parseInt(result, 16);
  if (!Number.isFinite(actual)) {
    return { status: 'unreachable', expected, url, reason: `unparseable chain id ${result}` };
  }

  return actual === expected
    ? { status: 'ok', chainId: actual, url }
    : { status: 'mismatch', expected, actual, url };
}

/** Cached verdict, so a render storm is not a request storm. */
let memo: { at: number; verdict: ChainVerdict } | null = null;

/** Test seam. Production passes nothing and gets global fetch. */
export type FetchLike = (input: string, init?: RequestInit) => Promise<Response>;

export function __resetChainGuardCache(): void {
  memo = null;
}

/**
 * Ask the RPC the app actually uses which chain it is.
 *
 * Note it reads `activeChain.rpcUrls`, NOT `NEXT_PUBLIC_RPC_URL`. Those are not
 * the same thing: `robinhoodMainnet` carries a hardcoded list and ignores the
 * env var entirely, so checking the env var would verify a URL no mainnet read
 * ever goes to.
 */
export async function checkServerChain(
  fetchImpl: FetchLike = fetch,
  now: () => number = Date.now,
): Promise<ChainVerdict> {
  const expected = activeChain.id;
  const url = activeChain.rpcUrls.default.http[0];

  if (!url) {
    return { status: 'unreachable', expected, url: '(none configured)', reason: 'no RPC URL' };
  }

  const t = now();
  if (memo && t - memo.at < TTL_MS) return memo.verdict;

  let verdict: ChainVerdict;
  try {
    const res = await fetchImpl(url, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'eth_chainId', params: [] }),
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
    verdict = res.ok
      ? evaluateChainIdResponse(expected, url, await res.json())
      : { status: 'unreachable', expected, url, reason: `HTTP ${res.status}` };
  } catch (err) {
    verdict = {
      status: 'unreachable',
      expected,
      url,
      reason: err instanceof Error ? err.message : String(err),
    };
  }

  // A mismatch is never cached. It is a configuration fault someone is about to
  // fix, and a cached one would keep the portal dark for a further TTL after the
  // fix lands, which reads as "the fix did not work".
  if (verdict.status !== 'mismatch') memo = { at: t, verdict };
  return verdict;
}

/**
 * Throw if the configured chain and the live RPC disagree. Render otherwise.
 *
 * Call this from `app/portal/layout.tsx` rather than from each page: one call
 * site covers every portal route and cannot be forgotten when a route is added.
 * Forgetting a per-page step is precisely the failure `indexer/src/index.ts:277`
 * describes about vault registration -- "that is exactly the step that gets
 * forgotten after a redeploy".
 */
export async function assertServerChain(
  fetchImpl: FetchLike = fetch,
  now: () => number = Date.now,
): Promise<ChainVerdict> {
  const verdict = await checkServerChain(fetchImpl, now);

  if (verdict.status === 'mismatch') throw new ChainMismatchError(verdict);

  if (verdict.status === 'unreachable') {
    console.warn(
      `[zorpha] could not verify chain ${verdict.expected} against ${verdict.url}: ` +
        `${verdict.reason}. Rendering anyway -- an unreachable RPC makes this page ` +
        `stale, not wrong.`,
    );
  }

  return verdict;
}

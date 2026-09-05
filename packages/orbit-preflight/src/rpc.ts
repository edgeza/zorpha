/**
 * A JSON-RPC client small enough to read in one sitting.
 *
 * This package has no dependencies on purpose. It is meant to run before your
 * application starts, against configuration you do not yet trust, and pulling a
 * web3 library in to make four calls would mean the check shares a transport,
 * a retry policy and a failover strategy with the code it is supposed to be
 * checking. A fallback transport that silently retries the "next" endpoint is
 * exactly the behaviour that hides the bug in section 3 of the README.
 *
 * Every call here goes to ONE named URL and reports what THAT URL said.
 */

export type JsonRpcOk<T> = { ok: true; result: T };
export type JsonRpcErr = { ok: false; error: string };
export type JsonRpcResult<T> = JsonRpcOk<T> | JsonRpcErr;

export type FetchLike = (input: string, init?: RequestInit) => Promise<Response>;

export interface RpcOptions {
  /** Milliseconds before a call is abandoned. A hung endpoint must not hang startup. */
  timeoutMs?: number;
  /** Injectable for tests. Defaults to global fetch. */
  fetchImpl?: FetchLike;
}

const DEFAULT_TIMEOUT_MS = 5_000;

/**
 * Make one JSON-RPC call and classify the outcome.
 *
 * A JSON-RPC *error object* is reported as a failure rather than thrown,
 * because "the node answered and declined" is a different fact from "the node
 * did not answer", and several checks in this package need to tell them apart.
 */
export async function rpcCall<T = unknown>(
  url: string,
  method: string,
  params: unknown[] = [],
  opts: RpcOptions = {},
): Promise<JsonRpcResult<T>> {
  const doFetch = opts.fetchImpl ?? fetch;
  const timeoutMs = opts.timeoutMs ?? DEFAULT_TIMEOUT_MS;

  let res: Response;
  try {
    res = await doFetch(url, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
      signal: AbortSignal.timeout(timeoutMs),
    });
  } catch (err) {
    return { ok: false, error: err instanceof Error ? err.message : String(err) };
  }

  if (!res.ok) return { ok: false, error: `HTTP ${res.status}` };

  let body: unknown;
  try {
    body = await res.json();
  } catch {
    // A gateway error page, an auth wall, an HTML redirect. We reached
    // something, but not a JSON-RPC endpoint.
    return { ok: false, error: 'response was not JSON' };
  }

  const b = body as { result?: unknown; error?: { code?: number; message?: string } };
  if (b?.error) {
    const code = b.error.code === undefined ? '' : `${b.error.code}: `;
    return { ok: false, error: `${code}${b.error.message ?? 'json-rpc error'}` };
  }
  if (b?.result === undefined) return { ok: false, error: 'response had no result' };

  return { ok: true, result: b.result as T };
}

/** Parse a hex quantity. Returns null for anything that is not one. */
export function hexToBigInt(value: unknown): bigint | null {
  if (typeof value !== 'string' || !/^0x[0-9a-fA-F]+$/.test(value)) return null;
  try {
    return BigInt(value);
  } catch {
    return null;
  }
}

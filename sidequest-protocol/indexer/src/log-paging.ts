/**
 * Log-range paging helpers.
 *
 * Deliberately config-free: nothing here imports `./config.js`, so a caller
 * that only needs to page through `getLogs` calls -- season-snapshot.ts is
 * the reason this file exists -- does not have to satisfy config.ts's env
 * var requirements (RPC_URL, CHAIN_ID, SUPABASE_URL,
 * SUPABASE_SERVICE_ROLE_KEY) just to parse a CLI flag and read public logs.
 * chain.ts re-exports these three so index.ts and anything else already
 * importing them from chain.ts keeps working unchanged.
 */

/** Inclusive [from, to] ranges of at most `size` blocks. */
export function blockChunks(from: bigint, to: bigint, size: bigint): [bigint, bigint][] {
  const chunks: [bigint, bigint][] = [];
  let cursor = from;
  while (cursor <= to) {
    const end = cursor + size - 1n > to ? to : cursor + size - 1n;
    chunks.push([cursor, end]);
    cursor = end + 1n;
  }
  return chunks;
}

/**
 * True when an RPC error means "your query matched too many logs".
 *
 * Robinhood Chain caps getLogs at 10,000 RESULTS rather than on block range ,
 * measured directly: an unfiltered 2,000-block window already returns ~7,650
 * logs, while 10,000 blocks is rejected. Our queries are address- and
 * topic-filtered so they normally return far fewer, but a busy vault over a
 * wide backfill range can still trip it.
 *
 * This must be recognised rather than propagated: if it reaches the cycle
 * handler the cursor never advances, so the next poll issues the identical
 * failing request. The indexer would sit at the same block forever, logging the
 * same error, while looking alive to the health check.
 */
export function isLogLimitError(error: unknown): boolean {
  const message = (error instanceof Error ? error.message : String(error)).toLowerCase();
  return (
    message.includes('exceeds limit') ||
    message.includes('too many results') ||
    message.includes('query returned more than') ||
    message.includes('response size exceeded') ||
    message.includes('log response size exceeded')
  );
}

/**
 * Run `fetch` over [from, to], halving the range and retrying whenever the RPC
 * complains the result set is too large. Gives up below `minSize` so a genuinely
 * pathological block cannot loop forever.
 */
export async function withAdaptiveRange<T>(
  from: bigint,
  to: bigint,
  size: bigint,
  minSize: bigint,
  fetch: (f: bigint, t: bigint) => Promise<T[]>,
): Promise<{ results: T[]; scannedTo: bigint }> {
  const results: T[] = [];
  let cursor = from;
  let currentSize = size;

  while (cursor <= to) {
    const end = cursor + currentSize - 1n > to ? to : cursor + currentSize - 1n;
    try {
      results.push(...(await fetch(cursor, end)));
      cursor = end + 1n;
      // Creep back up after a success so one hot range does not permanently
      // slow the whole backfill.
      if (currentSize < size) {
        currentSize = currentSize * 2n > size ? size : currentSize * 2n;
      }
    } catch (error) {
      if (!isLogLimitError(error) || currentSize <= minSize) throw error;
      currentSize = currentSize / 2n > minSize ? currentSize / 2n : minSize;
    }
  }

  return { results, scannedTo: to };
}

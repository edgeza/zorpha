import { createServer } from 'node:http';
import { config } from './config.js';
import {
  assertChainId,
  getBlockTimestamp,
  getPublicClient,
  isValidAddress,
  rebalancedEventFor,
  RegistryEvents,
  withAdaptiveRange,
} from './chain.js';
import {
  advanceCursor,
  bumpManager,
  getCursor,
  getKnownVaults,
  insertRebalances,
  insertReputationPublish,
  markChallenged,
  markResolved,
  pingDatabase,
  recordCursorError,
  type RebalanceRow,
  type VaultRow,
} from './supabase.js';

/**
 * Zorpha receipts indexer.
 *
 * Rewritten as a long-running service. The previous revision ran `main()` once
 * and called `process.exit(0)` — `POLL_INTERVAL_MS` was defined in config and
 * never read, so there was no loop at all. On Railway that either looks like a
 * crash-loop or a job that completes and stops indexing, and the receipts feed
 * silently stops updating.
 */

// ─── Logging ────────────────────────────────────────────────────────────────

type Level = 'info' | 'warn' | 'error';

function log(level: Level, message: string, fields: Record<string, unknown> = {}): void {
  const line = JSON.stringify({
    ts: new Date().toISOString(),
    level,
    svc: 'zorpha-indexer',
    message,
    ...fields,
  });
  if (level === 'error') console.error(line);
  else console.log(line);
}

// ─── Health state, surfaced over HTTP for Railway ───────────────────────────

const health = {
  startedAt: new Date().toISOString(),
  ready: false,
  lastCycleAt: null as string | null,
  lastCycleOk: false,
  cyclesCompleted: 0,
  consecutiveFailures: 0,
  headBlock: null as string | null,
  vaultsTracked: 0,
  receiptsIndexed: 0,
  lastError: null as string | null,
};

function startHealthServer(): void {
  const server = createServer(async (req, res) => {
    if (req.url === '/healthz' || req.url === '/') {
      // Liveness only: the process is up and the loop has not given up.
      const alive = health.consecutiveFailures < config.maxConsecutiveFailures;
      res.writeHead(alive ? 200 : 503, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ status: alive ? 'ok' : 'degraded', ...health }, null, 2));
      return;
    }
    if (req.url === '/readyz') {
      // Readiness: also requires the database to answer, so a bad service-role
      // key surfaces here rather than as silently missing rows.
      const dbOk = await pingDatabase();
      const ready = health.ready && dbOk;
      res.writeHead(ready ? 200 : 503, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ status: ready ? 'ready' : 'not-ready', dbOk, ...health }, null, 2));
      return;
    }
    res.writeHead(404, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ error: 'not found' }));
  });

  server.listen(config.port, () => {
    log('info', 'health server listening', { port: config.port });
  });
  server.unref();
}

/**
 * Outer windows for a scan. Each becomes one cursor advance, so a long backfill
 * checkpoints as it goes rather than only at the very end.
 *
 * Capped at 20 windows per cycle: without a cap, a first run against a chain
 * already at block 111,000,000 would try to scan the entire history in one
 * cycle and never reach the live tail. Successive cycles pick up where this one
 * stopped.
 */
function planWindows(from: bigint, to: bigint, size: bigint): [bigint, bigint][] {
  const windows: [bigint, bigint][] = [];
  let cursor = from;
  while (cursor <= to && windows.length < 20) {
    const end = cursor + size - 1n > to ? to : cursor + size - 1n;
    windows.push([cursor, end]);
    cursor = end + 1n;
  }
  return windows;
}

// ─── Vault indexing ─────────────────────────────────────────────────────────

async function indexVault(vault: VaultRow, safeHead: bigint): Promise<number> {
  const client = getPublicClient();
  const event = rebalancedEventFor(vault.vault_type);

  const stored = await getCursor('vault', vault.address);
  const from = stored === null ? config.startBlock : stored + 1n;

  if (from > safeHead) return 0;

  let inserted = 0;

  // Walk the range in adaptive windows: on a "too many logs" error the window
  // halves and retries rather than propagating, which would leave the cursor
  // parked and re-issue the identical failing request every poll.
  const windows = planWindows(from, safeHead, config.blockChunkSize);

  for (const [chunkFrom, chunkTo] of windows) {
    const { results: logs } = await withAdaptiveRange(
      chunkFrom,
      chunkTo,
      config.blockChunkSize,
      config.minBlockChunkSize,
      (f, t) =>
        client.getLogs({
          address: vault.address as `0x${string}`,
          event,
          fromBlock: f,
          toBlock: t,
        }) as Promise<unknown[]>,
    );

    const rows: RebalanceRow[] = [];
    const bumps: { manager: string; ts: string }[] = [];

    for (const raw of logs) {
      const entry = raw as {
        args?: Record<string, unknown>;
        blockNumber: bigint;
        transactionHash: string;
        logIndex: number;
      };
      const args = entry.args ?? {};
      const blockNumber = entry.blockNumber;
      const ts = await getBlockTimestamp(blockNumber);

      const asBig = (v: unknown): string | null =>
        typeof v === 'bigint' ? v.toString() : null;

      rows.push({
        vault_address: vault.address,
        vault_type: vault.vault_type,
        // The vault's configured manager, which is what KEEPER_ROLE actually
        // enforces. Deliberately NOT tx.from: submission is permissionless, so
        // the sender is frequently a keeper and attributing the trade to them
        // would misstate authorship on a protocol built around attribution.
        manager: vault.manager_address,
        submitter: null,
        block_number: Number(blockNumber),
        tx_hash: entry.transactionHash,
        log_index: entry.logIndex,
        block_timestamp: ts,
        target_bps:
          vault.vault_type === 'spot' && typeof args.targetBps === 'number'
            ? args.targetBps
            : null,
        target_weights:
          vault.vault_type === 'rotation' && Array.isArray(args.targetBps)
            ? (args.targetBps as readonly number[]).map(Number)
            : null,
        asset_leg:
          vault.vault_type === 'spot'
            ? asBig(args.assetLeg)
            : vault.vault_type === 'yield'
              ? asBig(args.totalAssetsInAdapter)
              : null,
        cash_leg:
          vault.vault_type === 'spot'
            ? asBig(args.cashLeg)
            : vault.vault_type === 'rotation'
              ? asBig(args.baseLeg)
              : asBig(args.adapterBalance),
        nav_per_share: asBig(args.navPerShare ?? args.navInBase),
        nonce: typeof args.nonce === 'bigint' ? Number(args.nonce) : 0,
        commitment: (args.commitment as string | undefined) ?? null,
      });

      bumps.push({ manager: vault.manager_address, ts });
    }

    const newRows = await insertRebalances(rows);

    // Only bump the counter for rows that were genuinely new, so the counter
    // cannot drift above the number of receipts on a re-scan.
    for (const bump of bumps.slice(0, newRows)) {
      await bumpManager(bump.manager, bump.ts);
    }

    inserted += newRows;

    // Advance after each chunk, not once at the end: a crash mid-backfill then
    // resumes from the last completed chunk instead of starting over.
    await advanceCursor('vault', vault.address, chunkTo);
  }

  return inserted;
}

// ─── Registry indexing ──────────────────────────────────────────────────────

async function indexRegistry(address: `0x${string}`, safeHead: bigint): Promise<number> {
  const client = getPublicClient();

  const stored = await getCursor('registry', address);
  const from = stored === null ? config.startBlock : stored + 1n;
  if (from > safeHead) return 0;

  let handled = 0;

  for (const [chunkFrom, chunkTo] of planWindows(from, safeHead, config.blockChunkSize)) {
    const { results: logs } = await withAdaptiveRange(
      chunkFrom,
      chunkTo,
      config.blockChunkSize,
      config.minBlockChunkSize,
      (f, t) =>
        client.getLogs({
          address,
          events: RegistryEvents,
          fromBlock: f,
          toBlock: t,
        }) as Promise<unknown[]>,
    );

    for (const raw of logs) {
      const entry = raw as {
        eventName?: string;
        args?: Record<string, unknown>;
        blockNumber: bigint;
        transactionHash: string;
      };
      const name = entry.eventName;
      const args = entry.args ?? {};
      const ts = await getBlockTimestamp(entry.blockNumber);

      if (name === 'StatsPublished') {
        await insertReputationPublish({
          contract_address: address,
          manager_address: args.manager as string,
          commitment: args.commitment as string,
          window_start: new Date(Number(args.windowStart) * 1000).toISOString(),
          window_end: new Date(Number(args.windowEnd) * 1000).toISOString(),
          nonce: Number(args.nonce),
          challenge_deadline: new Date(Number(args.challengeDeadline) * 1000).toISOString(),
          tx_hash: entry.transactionHash,
        });
        handled++;
        continue;
      }

      // The registry's challenge and resolve events carry a history INDEX, and
      // nonce == index + 1 because publish assigns nonce starting at 1 and
      // pushes in the same order.
      const nonce = Number(args.index) + 1;

      if (name === 'StatsChallenged') {
        await markChallenged({
          contractAddress: address,
          managerAddress: args.manager as string,
          nonce,
          challenger: args.challenger as string,
          counterCommitment: args.counterCommitment as string,
          challengedAt: ts,
        });
        handled++;
      } else if (name === 'StatsUpheld' || name === 'StatsOverturned') {
        await markResolved({
          contractAddress: address,
          managerAddress: args.manager as string,
          nonce,
          upheld: name === 'StatsUpheld',
          arbiter: args.arbiter as string,
          resolvedAt: ts,
        });
        handled++;
      }
    }

    await advanceCursor('registry', address, chunkTo);
  }

  return handled;
}

// ─── Cycle ──────────────────────────────────────────────────────────────────

async function runCycle(): Promise<void> {
  const client = getPublicClient();
  const head = await client.getBlockNumber();

  // Stay behind head so a shallow reorg is re-scanned rather than written and
  // then contradicted.
  const safeHead = head > config.confirmations ? head - config.confirmations : 0n;
  health.headBlock = head.toString();

  const vaults = await getKnownVaults();
  health.vaultsTracked = vaults.length;

  if (vaults.length === 0 && config.vaultAddresses.length === 0) {
    log('info', 'no vaults registered yet, nothing to index', { head: head.toString() });
  }

  let indexed = 0;
  for (const vault of vaults) {
    try {
      indexed += await indexVault(vault, safeHead);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      log('error', 'vault indexing failed', { vault: vault.address, error: message });
      await recordCursorError('vault', vault.address, message);
      throw error;
    }
  }

  const registry = config.reputationRegistryAddress;
  if (isValidAddress(registry)) {
    try {
      await indexRegistry(registry, safeHead);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      log('error', 'registry indexing failed', { registry, error: message });
      await recordCursorError('registry', registry, message);
      throw error;
    }
  }

  health.receiptsIndexed += indexed;
  if (indexed > 0) {
    log('info', 'cycle indexed receipts', { inserted: indexed, safeHead: safeHead.toString() });
  }
}

// ─── Main loop ──────────────────────────────────────────────────────────────

let shuttingDown = false;

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function main(): Promise<void> {
  log('info', 'starting', {
    chainId: config.chainId,
    pollIntervalMs: config.pollIntervalMs,
    confirmations: config.confirmations.toString(),
    chunkSize: config.blockChunkSize.toString(),
  });

  startHealthServer();

  await assertChainId();
  log('info', 'chain id verified', { chainId: config.chainId });
  health.ready = true;

  while (!shuttingDown) {
    const startedAt = Date.now();
    try {
      await runCycle();
      health.lastCycleOk = true;
      health.consecutiveFailures = 0;
      health.lastError = null;
      health.cyclesCompleted += 1;
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      health.lastCycleOk = false;
      health.consecutiveFailures += 1;
      health.lastError = message;

      log('error', 'cycle failed', {
        error: message,
        consecutiveFailures: health.consecutiveFailures,
      });

      if (health.consecutiveFailures >= config.maxConsecutiveFailures) {
        // Exit non-zero and let the platform restart us with a clean process.
        // Spinning forever on a permanent fault just hides it.
        log('error', 'giving up after repeated failures, exiting for restart', {
          consecutiveFailures: health.consecutiveFailures,
        });
        process.exit(1);
      }
    }

    health.lastCycleAt = new Date().toISOString();

    // Back off on failure so a rate-limited or down RPC is not hammered.
    const backoff = health.lastCycleOk
      ? config.pollIntervalMs
      : Math.min(config.pollIntervalMs * 2 ** health.consecutiveFailures, 5 * 60_000);

    const elapsed = Date.now() - startedAt;
    const wait = Math.max(0, backoff - elapsed);
    if (wait > 0 && !shuttingDown) await sleep(wait);
  }

  log('info', 'shutdown complete', { cyclesCompleted: health.cyclesCompleted });
}

// Railway sends SIGTERM on redeploy and expects the process to exit promptly.
// Finishing the current cycle first avoids leaving a chunk half-written.
for (const signal of ['SIGTERM', 'SIGINT'] as const) {
  process.on(signal, () => {
    if (shuttingDown) process.exit(130);
    log('info', 'signal received, finishing current cycle then exiting', { signal });
    shuttingDown = true;
  });
}

process.on('unhandledRejection', (reason) => {
  log('error', 'unhandled rejection', { reason: String(reason) });
  process.exit(1);
});

main().catch((error: unknown) => {
  const err = error as Error;
  log('error', 'fatal', { error: err.message, stack: err.stack });
  process.exit(1);
});

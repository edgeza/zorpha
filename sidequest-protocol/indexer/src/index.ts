import { createServer } from 'node:http';
import { planWindows, toRebalanceRow, type DecodedLog } from './decode.js';
import { navDecimalsFor } from './chain.js';
import { config } from './config.js';
import {
  assertChainPreflight,
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
  dryRunTally,
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
  // Resolved once per vault per cycle rather than per log: it is immutable for
  // the life of the vault, and a receipt-rate read would be one RPC round trip
  // per rebalance for a number that never moves.
  const navDecimals = await navDecimalsFor(
    vault.address as `0x${string}`,
    vault.vault_type,
    vault.asset as `0x${string}`,
  );

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
      const entry = raw as DecodedLog;
      const ts = await getBlockTimestamp(entry.blockNumber);
      rows.push(toRebalanceRow(vault, entry, ts, navDecimals));
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
          chain_id: config.chainId,
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

  // VAULT_ADDRESSES does NOT select what gets indexed outside DRY_RUN. The
  // vault list is the `vaults` TABLE; the env var is only read by the dry-run
  // path. Setting it in production and expecting the new deployment to appear
  // is a reasonable thing to expect and it does nothing at all -- the indexer
  // carries on serving whatever the table happens to hold, silently, which on
  // this deployment meant three superseded vaults from the previous release.
  //
  // upsertVault exists and is never called, so there is no code path that
  // registers a vault. Registration is a hand-written SQL insert, and that is
  // exactly the step that gets forgotten after a redeploy.
  //
  // Reconciling here does not fix the design, but it does stop the divergence
  // being invisible: what the operator CONFIGURED is compared with what the
  // database will actually be indexed from, and any gap is named.
  if (!config.dryRun && config.vaultAddresses.length > 0) {
    const registered = new Set(vaults.map((v) => v.address.toLowerCase()));
    const missing = config.vaultAddresses.filter((a) => !registered.has(a.toLowerCase()));
    if (missing.length > 0) {
      log('warn', 'VAULT_ADDRESSES lists vaults that are not in the vaults table', {
        missing,
        hint:
          'These will NOT be indexed. VAULT_ADDRESSES only selects vaults under ' +
          'DRY_RUN=1; in production the list comes from the table. Insert them ' +
          'there (see zorpha-web/migrations) or they stay invisible.',
        indexingInstead: vaults.map((v) => v.address),
      });
    }
  }

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
    chain: config.chainName,
    pollIntervalMs: config.pollIntervalMs,
    confirmations: config.confirmations.toString(),
    chunkSize: config.blockChunkSize.toString(),
  });

  // Chain id, archive capability, START_BLOCK and the configured vault
  // addresses -- every one of them checked against the live chain, on every
  // configured endpoint rather than whichever answers first. Three of the four
  // fail SILENTLY when they come from the other deployment. See
  // assertChainPreflight.
  const preflight = await assertChainPreflight(config.vaultAddresses);

  // Endpoints that did not answer. Not fatal -- an outage is not a
  // misconfiguration -- but silence here is how a dead fallback goes unnoticed
  // until the primary blips and there is nothing behind it.
  for (const finding of preflight.findings) {
    log('warn', 'preflight warning', { code: finding.code, detail: finding.message, url: finding.url });
  }

  log('info', 'chain preflight passed', {
    chainId: config.chainId,
    chain: config.chainName,
    startBlock: config.startBlock.toString(),
    vaultAddressesChecked: config.vaultAddresses.length,
    head: preflight.head?.toString() ?? null,
    rpcsChecked: preflight.rpcs.length,
    rpcsServingArchive: preflight.rpcs.filter((r) => r.servesArchive === true).length,
  });

  // A dry run is one cycle, no health server, no writes, and a summary. It
  // exists because the indexing path could not be executed at all without a
  // Supabase service-role key, so the component between "every rebalance is a
  // public receipt" and an empty receipts feed was the one component nobody
  // could try.
  //
  // What it proves: the RPC is reachable, every vault types correctly, the
  // event ABIs still match what the contracts emit, getLogs returns the
  // receipts, and each one decodes into a well-formed row.
  //
  // What it does NOT prove: the writes, the cursor store, the unique
  // constraints, or manager attribution -- attribution reads from the `vaults`
  // table, which a dry run has no access to.
  if (config.dryRun) {
    await runCycle();

    const t = dryRunTally;
    log('info', 'DRY RUN complete, nothing was written', {
      receiptsFound: t.rebalances,
      reputationEvents: t.reputation,
      managersTouched: t.managers.size,
    });
    for (const sample of t.samples) {
      log('info', 'sample row (not inserted)', { row: JSON.parse(
        JSON.stringify(sample, (_k, v) => (typeof v === 'bigint' ? v.toString() : v)),
      ) });
    }
    if (t.rebalances === 0) {
      log('warn', 'no receipts found', {
        hint:
          'Either the vaults have never rebalanced in the scanned range, or ' +
          'START_BLOCK is ahead of the events. The scan starts at START_BLOCK ' +
          'and covers at most 20 windows of BLOCK_CHUNK_SIZE per cycle.',
        startBlock: config.startBlock.toString(),
        chunkSize: config.blockChunkSize.toString(),
      });
    }
    return;
  }

  startHealthServer();
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

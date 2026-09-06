import * as dotenv from 'dotenv';
dotenv.config();

/**
 * Dry run: read the chain, decode receipts, write nothing.
 *
 * The indexing path had never been executed against the real chain, because
 * running it at all required a Supabase service-role key -- a secret that
 * belongs in Railway and nowhere else. So the one component standing between
 * "every rebalance is a public receipt" and an empty receipts feed was also the
 * one component nobody could try. `DRY_RUN=1` removes that: no credentials, no
 * writes, and a printed summary of exactly what would have been inserted.
 */
export const dryRun = process.env.DRY_RUN === '1' || process.env.DRY_RUN === 'true';

const required = dryRun
  ? (['RPC_URL', 'CHAIN_ID'] as const)
  : (['RPC_URL', 'CHAIN_ID', 'SUPABASE_URL', 'SUPABASE_SERVICE_ROLE_KEY'] as const);

// Accept the older RH_TESTNET_RPC_URL name so an existing Railway service does
// not break on rename.
if (!process.env.RPC_URL && process.env.RH_TESTNET_RPC_URL) {
  process.env.RPC_URL = process.env.RH_TESTNET_RPC_URL;
}

const missing = required.filter((key) => !process.env[key]);
if (missing.length > 0) {
  throw new Error(
    `Missing required env var(s): ${missing.join(', ')}. ` +
      'See sidequest-protocol/indexer/.env.example.',
  );
}

function int(name: string, fallback: number): number {
  const raw = process.env[name];
  if (!raw) return fallback;
  const parsed = Number.parseInt(raw, 10);
  if (!Number.isFinite(parsed) || parsed <= 0) {
    throw new Error(`${name} must be a positive integer, got "${raw}"`);
  }
  return parsed;
}

function list(name: string): string[] {
  return (process.env[name] ?? '')
    .split(',')
    .map((v) => v.trim())
    .filter((v) => v.length > 0);
}

/**
 * The two Robinhood Chain deployments, and everything that differs between
 * them.
 *
 * These chain ids differ BY ONE DIGIT -- 4663 mainnet, 46630 testnet -- and
 * every host name differs too. Held together in one table because the failure
 * that motivated it was a Railway config carrying `CHAIN_ID=4663` beside a
 * `rpc.testnet.` URL, a testnet explorer, testnet vault addresses and a testnet
 * block height: five values, one of them flipped, no single place that could
 * notice. `assertChainPreflight()` compares this table against the live RPC,
 * so a half-flipped config now fails at startup and names the halves.
 */
export const KNOWN_CHAINS = {
  4663: {
    name: 'Robinhood Chain mainnet',
    rpcUrl: 'https://rpc.mainnet.chain.robinhood.com/rpc',
    explorerUrl: 'https://robinhoodchain.blockscout.com',
    /** Measured 2026-09-05. Documentation only -- the START_BLOCK check in
     *  assertChainPreflight() reads the LIVE head, so this never goes stale in
     *  a way that can affect behaviour. It is here to make the ~2x gap between
     *  the two chains' heights legible at a glance, since that gap is the
     *  thing that makes a transposed START_BLOCK survive review. */
    approxHead: 55_214_104n,
  },
  46630: {
    name: 'Robinhood Chain testnet',
    rpcUrl: 'https://rpc.testnet.chain.robinhood.com/rpc',
    explorerUrl: 'https://explorer.testnet.chain.robinhood.com',
    approxHead: 113_526_734n,
  },
} as const;

export type KnownChainId = keyof typeof KNOWN_CHAINS;

function knownChain(id: number) {
  return (KNOWN_CHAINS as Record<number, (typeof KNOWN_CHAINS)[KnownChainId]>)[id];
}

/**
 * CHAIN_ID is required and has no default.
 *
 * It used to default to 46630. A default is how a mainnet deployment gets
 * labelled testnet: the operator sets RPC_URL, sees the service come up, and
 * every row it writes carries the wrong chain -- which, once written, cannot be
 * told apart from real testnet history afterwards.
 */
function chainIdFromEnv(): number {
  const id = int('CHAIN_ID', 0);
  if (!knownChain(id)) {
    throw new Error(
      `CHAIN_ID=${id} is not a Robinhood Chain deployment this indexer knows. ` +
        `Expected 4663 (mainnet) or 46630 (testnet). Note they differ by one digit.`,
    );
  }
  return id;
}

const chainId = chainIdFromEnv();

export const config = {
  dryRun,
  rpcUrl: process.env.RPC_URL!,
  rpcFallbackUrls: list('RPC_URL_FALLBACK'),
  chainId,
  /** Derived from the chain, not defaulted to testnet. EXPLORER_URL overrides
   *  it only for a mirror; getting it wrong mislabels every receipt link. */
  explorerUrl: process.env.EXPLORER_URL ?? knownChain(chainId).explorerUrl,
  chainName: knownChain(chainId).name,
  approxHead: knownChain(chainId).approxHead,

  vaultAddresses: list('VAULT_ADDRESSES') as `0x${string}`[],
  reputationRegistryAddress: process.env.REPUTATION_REGISTRY_ADDRESS as
    | `0x${string}`
    | undefined,

  /** Block to start from when a source has no cursor yet. */
  startBlock: BigInt(process.env.START_BLOCK ?? '0'),

  /**
   * Blocks per getLogs call.
   *
   * Measured against Robinhood Chain testnet: the RPC caps on RESULT COUNT
   * (10,000 logs), not on block range. Our queries are address- plus
   * topic-filtered so they return far fewer, which is why the range can be
   * generous; but a busy vault can still trip the cap, so `indexVault`
   * halves the range and retries rather than treating it as fatal.
   *
   * Block time is ~0.17s, so 50k blocks is roughly 2.4 hours of history per
   * request. At the old default of 2,000 that was 5.7 minutes per request:
   * a one-week backfill would have needed ~3,500 sequential round trips.
   */
  blockChunkSize: BigInt(int('BLOCK_CHUNK_SIZE', 50_000)),

  /** Smallest range to fall back to before giving up on a chunk. */
  minBlockChunkSize: BigInt(int('MIN_BLOCK_CHUNK_SIZE', 500)),

  /**
   * Blocks to stay behind head, so a reorg inside this window is re-scanned on
   * the next pass instead of being written and then contradicted.
   *
   * At ~0.17s per block the old default of 3 bought 0.5 seconds of protection,
   * which is not protection. 120 blocks is ~20 seconds.
   */
  confirmations: BigInt(int('CONFIRMATIONS', 120)),

  /** ~70 blocks of new head per tick at 0.17s block time. */
  pollIntervalMs: int('POLL_INTERVAL_MS', 12_000),

  /** Consecutive failures before the process exits and lets Railway restart it. */
  maxConsecutiveFailures: int('MAX_CONSECUTIVE_FAILURES', 10),

  /** Health-check port. Railway injects PORT. */
  port: int('PORT', 8080),

  supabase: {
    url: process.env.SUPABASE_URL!,
    serviceRoleKey: process.env.SUPABASE_SERVICE_ROLE_KEY!,
  },
} as const;

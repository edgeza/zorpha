import * as dotenv from 'dotenv';
dotenv.config();

const required = ['RPC_URL', 'SUPABASE_URL', 'SUPABASE_SERVICE_ROLE_KEY'] as const;

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

export const config = {
  rpcUrl: process.env.RPC_URL!,
  rpcFallbackUrls: list('RPC_URL_FALLBACK'),
  chainId: int('CHAIN_ID', 46630),
  explorerUrl: process.env.EXPLORER_URL ?? 'https://explorer.testnet.chain.robinhood.com',

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
   * generous — but a busy vault can still trip the cap, so `indexVault`
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

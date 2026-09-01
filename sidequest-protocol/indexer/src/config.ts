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
  explorerUrl: process.env.EXPLORER_URL ?? 'https://testnet-explorer.robinhood.com',

  vaultAddresses: list('VAULT_ADDRESSES') as `0x${string}`[],
  reputationRegistryAddress: process.env.REPUTATION_REGISTRY_ADDRESS as
    | `0x${string}`
    | undefined,

  /** Block to start from when a source has no cursor yet. */
  startBlock: BigInt(process.env.START_BLOCK ?? '0'),

  /**
   * Blocks per getLogs call. Most RPC providers cap the range (commonly at
   * 10_000) and reject anything wider with an opaque error, so the scan is
   * chunked rather than issued as one span from the deploy block to head.
   */
  blockChunkSize: BigInt(int('BLOCK_CHUNK_SIZE', 2_000)),

  /**
   * Blocks to stay behind head. A reorg inside this window is re-scanned on the
   * next pass instead of being written and then contradicted.
   */
  confirmations: BigInt(int('CONFIRMATIONS', 3)),

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

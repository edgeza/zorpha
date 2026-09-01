import { createPublicClient, http, fallback, defineChain, getAddress, type PublicClient } from 'viem';
import { config } from './config.js';

const chain = defineChain({
  id: config.chainId,
  name: 'Robinhood Chain',
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: { default: { http: [config.rpcUrl] } },
  blockExplorers: { default: { name: 'Explorer', url: config.explorerUrl } },
});

// ─── Vault events ───────────────────────────────────────────────────────────

export const SpotVaultRebalanced = {
  name: 'Rebalanced',
  type: 'event',
  anonymous: false,
  inputs: [
    { name: 'targetBps', type: 'uint16', indexed: false },
    { name: 'assetLeg', type: 'uint256', indexed: false },
    { name: 'cashLeg', type: 'uint256', indexed: false },
    { name: 'navPerShare', type: 'uint256', indexed: false },
    { name: 'nonce', type: 'uint256', indexed: false },
    { name: 'commitment', type: 'bytes32', indexed: false },
  ],
} as const;

export const RotationVaultRebalanced = {
  name: 'Rebalanced',
  type: 'event',
  anonymous: false,
  inputs: [
    { name: 'targetBps', type: 'uint16[]', indexed: false },
    { name: 'navInBase', type: 'uint256', indexed: false },
    { name: 'tokenLegs', type: 'uint256[]', indexed: false },
    { name: 'baseLeg', type: 'uint256', indexed: false },
    { name: 'nonce', type: 'uint256', indexed: false },
    { name: 'commitment', type: 'bytes32', indexed: false },
  ],
} as const;

export const YieldVaultRebalanced = {
  name: 'Rebalanced',
  type: 'event',
  anonymous: false,
  inputs: [
    { name: 'navPerShare', type: 'uint256', indexed: false },
    { name: 'totalAssetsInAdapter', type: 'uint256', indexed: false },
    { name: 'adapterBalance', type: 'uint256', indexed: false },
    { name: 'nonce', type: 'uint256', indexed: false },
    { name: 'commitment', type: 'bytes32', indexed: false },
  ],
} as const;

// ─── Reputation registry events ─────────────────────────────────────────────
//
// These signatures changed when audit findings V-03 and V-06 were fixed, and
// the previous indexer ABI was left behind:
//
//   - StatsChallenged was ABSENT entirely, so no dispute was ever recorded and
//     the portal displayed a challenged commitment as unchallenged.
//   - StatsUpheld / StatsOverturned gained an indexed `arbiter`, because
//     `upheld` can now only be set by a governance arbiter rather than by a
//     hash comparison the disputing parties supply themselves.
//
// An event signature is part of the ABI: a stale one does not throw, it simply
// matches nothing, which is the quietest possible failure.

export const StatsPublished = {
  name: 'StatsPublished',
  type: 'event',
  anonymous: false,
  inputs: [
    { name: 'manager', type: 'address', indexed: true },
    { name: 'commitment', type: 'bytes32', indexed: false },
    { name: 'windowStart', type: 'uint256', indexed: false },
    { name: 'windowEnd', type: 'uint256', indexed: false },
    { name: 'nonce', type: 'uint256', indexed: false },
    { name: 'challengeDeadline', type: 'uint256', indexed: false },
  ],
} as const;

export const StatsChallenged = {
  name: 'StatsChallenged',
  type: 'event',
  anonymous: false,
  inputs: [
    { name: 'manager', type: 'address', indexed: true },
    { name: 'index', type: 'uint256', indexed: false },
    { name: 'challenger', type: 'address', indexed: true },
    { name: 'counterCommitment', type: 'bytes32', indexed: false },
  ],
} as const;

export const StatsUpheld = {
  name: 'StatsUpheld',
  type: 'event',
  anonymous: false,
  inputs: [
    { name: 'manager', type: 'address', indexed: true },
    { name: 'index', type: 'uint256', indexed: false },
    { name: 'arbiter', type: 'address', indexed: true },
  ],
} as const;

export const StatsOverturned = {
  name: 'StatsOverturned',
  type: 'event',
  anonymous: false,
  inputs: [
    { name: 'manager', type: 'address', indexed: true },
    { name: 'index', type: 'uint256', indexed: false },
    { name: 'arbiter', type: 'address', indexed: true },
  ],
} as const;

export const RegistryEvents = [
  StatsPublished,
  StatsChallenged,
  StatsUpheld,
  StatsOverturned,
] as const;

export function rebalancedEventFor(vaultType: 'spot' | 'rotation' | 'yield') {
  if (vaultType === 'spot') return SpotVaultRebalanced;
  if (vaultType === 'rotation') return RotationVaultRebalanced;
  return YieldVaultRebalanced;
}

// ─── Client ─────────────────────────────────────────────────────────────────

function buildTransport() {
  const urls = [config.rpcUrl, ...config.rpcFallbackUrls];
  if (urls.length === 1) return http(urls[0], { retryCount: 3, timeout: 20_000 });
  return fallback(urls.map((u) => http(u, { retryCount: 2, timeout: 20_000 })));
}

let cached: PublicClient | null = null;

export function getPublicClient(): PublicClient {
  if (!cached) {
    cached = createPublicClient({ transport: buildTransport(), chain }) as PublicClient;
  }
  return cached;
}

let chainIdVerified = false;

/**
 * Confirm the RPC really answers with the expected chain id before any read.
 * A misconfigured URL would otherwise poison the database with another chain's
 * data, which is far harder to detect after the fact than at startup.
 */
export async function assertChainId(): Promise<void> {
  if (chainIdVerified) return;
  const actual = await getPublicClient().getChainId();
  if (actual !== config.chainId) {
    throw new Error(
      `RPC chain id mismatch: expected ${config.chainId}, got ${actual}. ` +
        'Refusing to index — check RPC_URL and CHAIN_ID.',
    );
  }
  chainIdVerified = true;
}

export function isValidAddress(value: string | undefined): value is `0x${string}` {
  if (!value) return false;
  try {
    getAddress(value);
    return true;
  } catch {
    return false;
  }
}

/**
 * Block-timestamp cache.
 *
 * The previous revision called getBlock once per log. A chunk containing 200
 * receipts across 40 blocks issued 200 requests for 40 distinct answers, which
 * is what gets an indexer rate-limited.
 */
const blockTimestamps = new Map<string, string>();

export async function getBlockTimestamp(blockNumber: bigint): Promise<string> {
  const key = blockNumber.toString();
  const hit = blockTimestamps.get(key);
  if (hit) return hit;

  const block = await getPublicClient().getBlock({ blockNumber });
  const iso = new Date(Number(block.timestamp) * 1000).toISOString();

  // Bounded so a long backfill cannot grow the map without limit.
  if (blockTimestamps.size > 5_000) blockTimestamps.clear();
  blockTimestamps.set(key, iso);
  return iso;
}

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

import { createPublicClient, http, fallback, defineChain, getAddress, type PublicClient } from 'viem';
import { config, KNOWN_CHAINS } from './config.js';

const chain = defineChain({
  id: config.chainId,
  name: config.chainName,
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
    const known = KNOWN_CHAINS as Record<number, { name: string; rpcUrl: string }>;
    const expected = known[config.chainId];
    const served = known[actual];
    throw new Error(
      `RPC chain id mismatch: CHAIN_ID says ${config.chainId}` +
        (expected ? ` (${expected.name})` : '') +
        `, but RPC_URL serves ${actual}` +
        (served ? ` (${served.name})` : '') +
        `. Refusing to index.` +
        (expected ? ` For ${config.chainId} use RPC_URL=${expected.rpcUrl}` : ''),
    );
  }
  chainIdVerified = true;
}

/**
 * Everything that must be true before the first getLogs, checked against the
 * live chain rather than against config.
 *
 * `assertChainId` alone is not enough. It catches the loud half of a
 * half-flipped config -- a mainnet CHAIN_ID beside a testnet RPC -- and misses
 * both quiet halves, which are worse because the service comes up green and
 * indexes nothing:
 *
 *   START_BLOCK from the other chain. It is read only when a source has no
 *   cursor (index.ts:107). A testnet height of 112,522,500 against mainnet's
 *   head of ~55.2M makes every window empty. No error, no rows, healthy.
 *
 *   Vault addresses from the other chain. getLogs on an address with no code
 *   is not an error, it is an empty array. Three testnet vaults scanned on
 *   mainnet look exactly like three quiet vaults.
 *
 * Both are cheap to check once and impossible to notice later, so they are
 * checked once, here, and the process refuses to start.
 */
export async function assertChainPreflight(vaultAddresses: readonly string[]): Promise<void> {
  await assertChainId();

  const client = getPublicClient();
  const head = await client.getBlockNumber();

  if (config.startBlock > head) {
    throw new Error(
      `START_BLOCK=${config.startBlock} is beyond the head of chain ` +
        `${config.chainId} (${config.chainName}), currently ${head}. ` +
        'Nothing would ever be scanned and every cycle would report success. ' +
        'This is what a block height from the other chain looks like: testnet ' +
        'heights are ~113M, mainnet ~55M. Set START_BLOCK to the deployment ' +
        'block on THIS chain.',
    );
  }

  // Only the addresses the operator named. The vaults table is the real source
  // outside DRY_RUN, and it is checked by getKnownVaults' chain filter.
  const codeless: string[] = [];
  for (const address of vaultAddresses) {
    const code = await client.getBytecode({ address: address as `0x${string}` });
    if (!code || code === '0x') codeless.push(address);
  }

  if (codeless.length > 0) {
    throw new Error(
      `${codeless.length} of ${vaultAddresses.length} configured vault ` +
        `address(es) have no code on chain ${config.chainId} ` +
        `(${config.chainName}): ${codeless.join(', ')}. getLogs on an address ` +
        'with no code returns an empty array rather than an error, so these ' +
        'would be scanned forever and never yield a receipt. They are almost ' +
        'certainly addresses from the other Robinhood Chain deployment.',
    );
  }
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

// ─── Dry-run vault discovery ────────────────────────────────────────────────

/**
 * Type a vault by which accessor answers, for `DRY_RUN` where there is no
 * `vaults` table to read.
 *
 * The probes must be MUTUALLY EXCLUSIVE, and the previous set stopped being so.
 * It used cashAsset / baseAsset / firstLossEscrow, on the premise that
 * firstLossEscrow existed only on the yield vault. RWRotationVault later gained
 * a firstLossEscrow field, so a rotation vault answered two probes, "exactly
 * one" could never hold, and DRY_RUN died on every deployment that included
 * one:
 *
 *     spot      cashAsset=YES  baseAsset=no   firstLossEscrow=no
 *     rotation  cashAsset=no   baseAsset=YES  firstLossEscrow=YES   <-- two
 *     yield     cashAsset=no   baseAsset=no   firstLossEscrow=YES
 *
 * DRY_RUN exists so the indexing path can be exercised without a service-role
 * key -- the one component that otherwise nobody can try. It was broken by a
 * field added to a contract in a different package, which is exactly the kind
 * of drift nothing was watching for.
 *
 * The set below is exclusive again, verified against the live testnet
 * deployment:
 *
 *     spot      cashAsset=YES  basketLength=no   adapter=no
 *     rotation  cashAsset=no   basketLength=YES  adapter=no
 *     yield     cashAsset=no   basketLength=no   adapter=YES
 *
 * `matched !== 1` is kept deliberately. Falling back to "neither of the others
 * replied, so it must be the third" would let one dropped RPC call mistype a
 * vault, and its receipts would then be decoded with the wrong event ABI --
 * which does not throw. It matches nothing, and the feed goes quietly empty.
 */
export async function detectVaultType(
  address: `0x${string}`,
): Promise<'spot' | 'rotation' | 'yield' | null> {
  const client = getPublicClient();

  const probe = async (name: string, outputType: string): Promise<boolean> => {
    try {
      await client.readContract({
        address,
        abi: [
          {
            name,
            type: 'function',
            stateMutability: 'view',
            inputs: [],
            outputs: [{ type: outputType }],
          },
        ] as const,
        functionName: name,
      });
      return true;
    } catch {
      return false;
    }
  };

  const [cash, basket, adapter] = await Promise.all([
    probe('cashAsset', 'address'),
    probe('basketLength', 'uint256'),
    probe('adapter', 'address'),
  ]);

  const matched = [cash, basket, adapter].filter(Boolean).length;
  if (matched !== 1) return null;
  if (cash) return 'spot';
  if (basket) return 'rotation';
  return 'yield';
}


/**
 * Decimals of the unit a vault denominates its NAV and high-water mark in.
 *
 * NOT simply asset().decimals(). On a rotation basket asset() is tokens[0] --
 * which on an equity-led basket is the equity -- while navPerShare and
 * highWaterMark are measured in baseAsset(). The two differ by 10^12 on the
 * live deployment, which is the whole reason receipts and the manager terminal
 * were rendering a NAV of 1.000000 as 0.00000.
 *
 *   spot      asset() decimals
 *   rotation  baseDecimals()
 *   yield     asset() decimals
 *
 * Undefined rather than a guess when the reads fail: nav_decimals is nullable
 * and the renderer falls back to its previous behaviour, which is better than
 * recording a scale we are not sure of onto a receipt meant to be verifiable.
 */
export async function navDecimalsFor(
  vaultAddress: `0x${string}`,
  vaultType: 'spot' | 'rotation' | 'yield',
  assetAddress: `0x${string}`,
): Promise<number | undefined> {
  const client = getPublicClient();
  const u8 = [{ type: 'uint8' }] as const;

  try {
    if (vaultType === 'rotation') {
      return Number(
        await client.readContract({
          address: vaultAddress,
          abi: [
            { name: 'baseDecimals', type: 'function', stateMutability: 'view', inputs: [], outputs: u8 },
          ] as const,
          functionName: 'baseDecimals',
        }),
      );
    }
    return Number(
      await client.readContract({
        address: assetAddress,
        abi: [
          { name: 'decimals', type: 'function', stateMutability: 'view', inputs: [], outputs: u8 },
        ] as const,
        functionName: 'decimals',
      }),
    );
  } catch {
    return undefined;
  }
}

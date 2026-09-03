/**
 * Oracle keeper — a second long-running process, deployed from this same
 * package with a different start command.
 *
 * WHY IT IS HERE AND NOT A SHELL SCRIPT
 *
 * `script/oracle-keeper.sh` does this job and cannot be hosted: it needs
 * Foundry's `cast`, which a Node container does not have, and it signs with an
 * interactive keystore, which cron cannot unlock. So it stayed on a laptop,
 * which is why the price went stale for ten hours and nothing noticed:
 *
 *     latestRoundData()  ->  execution reverted: InsufficientFreshReports(0, 1)
 *     last report age    ->  35,468s against a 3,600s window
 *
 * Same package as the indexer deliberately: same build, same deps, same deploy.
 * Two Railway services pointed at this directory, differing only in their start
 * command -- `npm start` for the indexer, `npm run start:keeper` for this.
 *
 * THE KEY THIS RUNS AS
 *
 * It must NOT be the governance key. On testnet the sole updater is governance,
 * so hosting that would put the credential controlling the whole protocol into
 * a process that posts a number every few minutes. Give this its own key with
 * only UPDATER_ROLE: worth nothing if stolen beyond the ability to post a price
 * that the quorum should be guarding anyway. Startup checks the role and exits
 * rather than discovering it on the first send.
 *
 * THE PRICE
 *
 * PRICE_USD is a constant, which is honest for a testnet whose tAAPL is a mock
 * nobody trades, and is not an oracle on mainnet -- it is a number the operator
 * chose, from which every depositor's NAV derives. Replace it with a real feed,
 * and raise minQuorum above one, before any of this is live.
 */

import {
  createPublicClient,
  createWalletClient,
  http,
  type Address,
  type Hex,
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';

const log = (level: string, message: string, extra: Record<string, unknown> = {}) =>
  console.log(
    JSON.stringify({
      ts: new Date().toISOString(),
      level,
      svc: 'zorpha-oracle-keeper',
      message,
      ...extra,
    }),
  );

function required(name: string): string {
  const v = process.env[name];
  if (!v) {
    log('error', 'missing required env var', { name });
    process.exit(1);
  }
  return v;
}

const RPC_URL = process.env.RPC_URL ?? process.env.RH_TESTNET_RPC_URL ?? '';
const ORACLE = required('ORACLE_ADDRESS') as Address;
const PRIVATE_KEY = required('ORACLE_KEEPER_PRIVATE_KEY') as Hex;
const CHAIN_ID = Number(process.env.CHAIN_ID ?? '46630');

/** Post once the price is older than this. Well inside maxStaleness so a few
 *  consecutive failures are survivable rather than an outage. */
const REFRESH_AFTER = Number(process.env.REFRESH_AFTER_SECONDS ?? '900');
const POLL_MS = Number(process.env.POLL_INTERVAL_MS ?? '60000');
const PRICE_USD = Number(process.env.PRICE_USD ?? '250');

if (!RPC_URL) {
  log('error', 'missing required env var', { name: 'RPC_URL' });
  process.exit(1);
}

const oracleAbi = [
  { type: 'function', name: 'maxStaleness', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'minQuorum', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'minAnswer', stateMutability: 'view', inputs: [], outputs: [{ type: 'int256' }] },
  { type: 'function', name: 'maxAnswer', stateMutability: 'view', inputs: [], outputs: [{ type: 'int256' }] },
  { type: 'function', name: 'decimals', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint8' }] },
  { type: 'function', name: 'updaterCount', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'updaters', stateMutability: 'view', inputs: [{ type: 'uint256' }], outputs: [{ type: 'address' }] },
  { type: 'function', name: 'reports', stateMutability: 'view', inputs: [{ type: 'address' }], outputs: [{ type: 'int256' }, { type: 'uint64' }] },
  { type: 'function', name: 'UPDATER_ROLE', stateMutability: 'view', inputs: [], outputs: [{ type: 'bytes32' }] },
  { type: 'function', name: 'hasRole', stateMutability: 'view', inputs: [{ type: 'bytes32' }, { type: 'address' }], outputs: [{ type: 'bool' }] },
  { type: 'function', name: 'report', stateMutability: 'nonpayable', inputs: [{ type: 'int256' }], outputs: [] },
] as const;

const chain = {
  id: CHAIN_ID,
  name: 'Robinhood Chain',
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: { default: { http: [RPC_URL] } },
} as const;

const account = privateKeyToAccount(PRIVATE_KEY);
const publicClient = createPublicClient({ chain, transport: http(RPC_URL) });
const walletClient = createWalletClient({ account, chain, transport: http(RPC_URL) });

const read = <T>(functionName: string, args: readonly unknown[] = []) =>
  publicClient.readContract({ address: ORACLE, abi: oracleAbi, functionName, args } as never) as Promise<T>;

/**
 * The newest report across every updater.
 *
 * `latestRoundData` cannot be used here: it REVERTS when the quorum is not
 * fresh, which is exactly the condition this process exists to detect and
 * repair. Reading the raw per-updater reports is the only way to measure how
 * stale things are while they are stale.
 */
async function newestReportAge(now: bigint): Promise<number> {
  const count = await read<bigint>('updaterCount');
  let newest = 0n;
  for (let i = 0n; i < count; i++) {
    const updater = await read<Address>('updaters', [i]);
    const [, ts] = await read<readonly [bigint, bigint]>('reports', [updater]);
    if (ts > newest) newest = ts;
  }
  return newest === 0n ? Number.MAX_SAFE_INTEGER : Number(now - newest);
}

async function preflight() {
  const [id, role, staleness, quorum, count, decimals] = await Promise.all([
    publicClient.getChainId(),
    read<Hex>('UPDATER_ROLE'),
    read<bigint>('maxStaleness'),
    read<bigint>('minQuorum'),
    read<bigint>('updaterCount'),
    read<number>('decimals'),
  ]);

  if (id !== CHAIN_ID) {
    log('error', 'chain id mismatch', { expected: CHAIN_ID, actual: id });
    process.exit(1);
  }

  // Checked at startup rather than discovered on the first send, when the only
  // symptom would be a revert every REFRESH_AFTER seconds forever.
  const permitted = await read<boolean>('hasRole', [role, account.address]);
  if (!permitted) {
    log('error', 'this key does not hold UPDATER_ROLE on the oracle', {
      keeper: account.address,
      oracle: ORACLE,
    });
    process.exit(1);
  }

  const balance = await publicClient.getBalance({ address: account.address });
  if (balance === 0n) {
    log('error', 'keeper has no gas', { keeper: account.address });
    process.exit(1);
  }

  log('info', 'keeper ready', {
    keeper: account.address,
    oracle: ORACLE,
    chainId: id,
    maxStaleness: Number(staleness),
    refreshAfter: REFRESH_AFTER,
    minQuorum: Number(quorum),
    updaters: Number(count),
    decimals,
  });

  if (count <= 1n) {
    log('warn', 'a single updater against this quorum has no redundancy and no median', {
      updaters: Number(count),
      minQuorum: Number(quorum),
    });
  }
  return { decimals, staleness };
}

async function tick(decimals: number) {
  const block = await publicClient.getBlock();
  const age = await newestReportAge(block.timestamp);

  if (age < REFRESH_AFTER) {
    log('info', 'price still fresh', { ageSeconds: age, refreshAfter: REFRESH_AFTER });
    return;
  }

  const price = BigInt(Math.round(PRICE_USD * 10 ** decimals));
  const [min, max] = await Promise.all([read<bigint>('minAnswer'), read<bigint>('maxAnswer')]);
  if (price < min || price > max) {
    log('error', 'price outside the oracle bounds, refusing to post', {
      price: price.toString(), min: min.toString(), max: max.toString(),
    });
    return;
  }

  const hash = await walletClient.writeContract({
    address: ORACLE, abi: oracleAbi, functionName: 'report', args: [price],
  });
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  log('info', 'price posted', {
    priceUsd: PRICE_USD, ageWas: age, tx: hash, status: receipt.status,
  });
}

async function main() {
  const { decimals } = await preflight();

  // Health endpoint, so Railway can tell a wedged process from a working one.
  const port = Number(process.env.PORT ?? '8080');
  const { createServer } = await import('node:http');
  let lastOk = Date.now();
  createServer((req, res) => {
    const stale = Date.now() - lastOk > (REFRESH_AFTER + 300) * 1000;
    res.writeHead(stale ? 503 : 200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ ok: !stale, lastCycleAt: new Date(lastOk).toISOString() }));
  }).listen(port, () => log('info', 'health server listening', { port }));

  for (;;) {
    try {
      await tick(decimals);
      lastOk = Date.now();
    } catch (err) {
      // Never exit on a cycle failure. A transient RPC error must not take the
      // price feed down -- that is the failure this whole process prevents.
      log('error', 'cycle failed', { error: err instanceof Error ? err.message : String(err) });
    }
    await new Promise((r) => setTimeout(r, POLL_MS));
  }
}

main().catch((err) => {
  log('error', 'fatal', { error: err instanceof Error ? err.message : String(err) });
  process.exit(1);
});

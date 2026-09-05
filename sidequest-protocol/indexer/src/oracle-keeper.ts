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
import {
  checkKeeper,
  MAINNET_CHAIN_ID as MAINNET,
  TESTNET_CHAIN_ID as TESTNET,
  type ChainReader,
} from './keeper-preflight.js';

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

/**
 * Normalise and check the signing key BEFORE viem sees it.
 *
 * viem's own failure is a stack trace from inside @noble/curves:
 *
 *     Error: invalid private key, expected hex or 32 bytes, got string
 *       at normPrivateKeyToScalar (.../weierstrass.js:269:19)
 *
 * which says nothing about WHICH of the plausible mistakes was made -- a
 * missing 0x, a trailing newline from a copy-paste, an address pasted where a
 * key belongs, or a truncated value. In a container that restarts on failure,
 * that trace repeats forever and the operator has to guess.
 *
 * The value itself is never logged. Only its shape.
 */
function privateKeyFrom(name: string): Hex {
  const raw = required(name).trim();
  const body = raw.startsWith('0x') || raw.startsWith('0X') ? raw.slice(2) : raw;

  if (body.length === 40) {
    log('error', 'that looks like an ADDRESS, not a private key', {
      name, expected: '64 hex characters', got: `${body.length} characters`,
    });
    process.exit(1);
  }
  if (body.length !== 64) {
    log('error', 'private key is the wrong length', {
      name,
      expected: '64 hex characters, with or without a 0x prefix',
      got: `${body.length} characters`,
      hint: body.length > 64 ? 'check for quotes or trailing whitespace' : 'the value looks truncated',
    });
    process.exit(1);
  }
  if (!/^[0-9a-fA-F]{64}$/.test(body)) {
    log('error', 'private key contains non-hex characters', {
      name, hint: 'check for quotes, spaces or a newline in the pasted value',
    });
    process.exit(1);
  }
  return `0x${body.toLowerCase()}` as Hex;
}

const PRIVATE_KEY = privateKeyFrom('ORACLE_KEEPER_PRIVATE_KEY');

/**
 * THIS PROCESS CANNOT FOLLOW THE PROTOCOL TO MAINNET.
 *
 * There is no oracle on Robinhood Chain mainnet 4663. The minimal deploy path
 * shipped no MedianOracle -- `NEXT_PUBLIC_ORACLE_ADDRESS` is deliberately
 * blank in `zorpha-web/.env.mainnet.template` -- and the only mainnet vault,
 * zsUSDG, is a yield vault that prices from its ERC-4626 target rather than a
 * feed. That is precisely why it could launch without one.
 *
 * So `CHAIN_ID=4663` here is not a repoint, it is a mistake, and the preflight
 * below would catch it as "ORACLE_ADDRESS is not a contract on this chain" --
 * true, but it reads like a typo rather than an architectural fact. Named
 * here instead, at the point where someone would change the value.
 *
 * Required rather than defaulted for the same reason as the indexer: a default
 * chain is how a process ends up reporting prices to the wrong network.
 */

const rawChainId = process.env.CHAIN_ID;
if (!rawChainId) {
  log('error', 'missing required env var', {
    name: 'CHAIN_ID',
    hint: `${TESTNET} (testnet). There is no oracle deployed on mainnet ${MAINNET}.`,
  });
  process.exit(1);
}
const CHAIN_ID = Number(rawChainId);
if (CHAIN_ID === MAINNET) {
  log('error', 'there is no oracle on mainnet, so there is nothing to keep', {
    chainId: MAINNET,
    hint:
      'The 4663 deploy shipped no MedianOracle and the only mainnet vault ' +
      '(zsUSDG) prices from its ERC-4626 target. Keep this service on ' +
      `CHAIN_ID=${TESTNET}, or retire it.`,
  });
  process.exit(1);
}
if (!Number.isInteger(CHAIN_ID) || CHAIN_ID <= 0) {
  log('error', 'CHAIN_ID is not a chain id', { got: rawChainId });
  process.exit(1);
}

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

/**
 * The live chain, narrowed to the four questions startup asks.
 *
 * The checks themselves live in keeper-preflight.ts, which knows nothing about
 * viem, the environment, or this process. That is what makes them testable: a
 * fake implementing this interface exercises every diagnosis below without a
 * chain, a key, or a running keeper.
 */
const liveChain: ChainReader = {
  getChainId: () => publicClient.getChainId(),
  getBytecode: (address) => publicClient.getBytecode({ address }),
  getBalance: (address) => publicClient.getBalance({ address }),
  readOracle: <T,>(functionName: string, args: readonly unknown[] = []) =>
    read<T>(functionName, args),
};

/**
 * Run the startup checks and turn the verdict into log lines and an exit code.
 *
 * Everything that decides IF the keeper may run is in `checkKeeper`. All this
 * does is report the answer, which is the part that has to touch the process.
 */
async function preflight() {
  const result = await checkKeeper(
    { chainId: CHAIN_ID, rpcUrl: RPC_URL, oracle: ORACLE, keeper: account.address },
    liveChain,
  );

  if (!result.ok) {
    log('error', result.message, result.fields);
    process.exit(1);
  }

  const { ready, warnings } = result;

  log('info', 'keeper ready', {
    keeper: account.address,
    oracle: ORACLE,
    chainId: ready.chainId,
    maxStaleness: Number(ready.maxStaleness),
    refreshAfter: REFRESH_AFTER,
    minQuorum: Number(ready.minQuorum),
    updaters: Number(ready.updaterCount),
    decimals: ready.decimals,
  });

  for (const warning of warnings) {
    log('warn', warning.message, warning.fields);
  }

  return { decimals: ready.decimals, staleness: ready.maxStaleness };
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

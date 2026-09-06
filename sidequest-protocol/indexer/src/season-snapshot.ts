/**
 * Season 1 eligibility snapshot.
 *
 * Emits the CSV that scripts/generate-airdrop.ts consumes. Run it after the
 * window closes:
 *
 *   npx tsx src/season-snapshot.ts \
 *     --vault 0x3829bC787d4eB15Ec855A6cA33e1492a9103d130 \
 *     --from-block <window open> --to-block <window close> \
 *     --rpc https://rpc.mainnet.chain.robinhood.com/rpc > snapshot.csv
 */
import { createPublicClient, http, formatUnits, parseAbi, getAddress, type Address } from 'viem';
import {
  balanceIntervals, allocationFor, clusterOf, SEASON_1_TIERS,
  type ShareTransfer, type Funding,
} from './season-eligibility.js';

function arg(name: string, fallback?: string): string {
  const i = process.argv.indexOf(`--${name}`);
  if (i !== -1 && process.argv[i + 1]) return process.argv[i + 1];
  if (fallback !== undefined) return fallback;
  throw new Error(`missing --${name}`);
}

const TRANSFER = {
  type: 'event', name: 'Transfer',
  inputs: [
    { indexed: true, name: 'from', type: 'address' },
    { indexed: true, name: 'to', type: 'address' },
    { indexed: false, name: 'value', type: 'uint256' },
  ],
} as const;

async function main() {
  const vault = getAddress(arg('vault')) as Address;
  const fromBlock = BigInt(arg('from-block'));
  const toBlock = BigInt(arg('to-block'));
  const client = createPublicClient({ transport: http(arg('rpc')) });

  // Robinhood Chain caps getLogs at 10,000 RESULTS rather than on block range,
  // so page by block and stop widening if a chunk comes back full.
  const STEP = 100_000n;
  const logs = [];
  for (let lo = fromBlock; lo <= toBlock; lo += STEP) {
    const hi = lo + STEP - 1n > toBlock ? toBlock : lo + STEP - 1n;
    logs.push(...(await client.getLogs({ address: vault, event: TRANSFER, fromBlock: lo, toBlock: hi })));
  }

  // Timestamps come from the block, not the log, so cache per block.
  const tsCache = new Map<bigint, number>();
  const timestampOf = async (b: bigint): Promise<number> => {
    const hit = tsCache.get(b);
    if (hit !== undefined) return hit;
    const block = await client.getBlock({ blockNumber: b });
    const t = Number(block.timestamp);
    tsCache.set(b, t);
    return t;
  };

  const transfers: ShareTransfer[] = [];
  for (const l of logs) {
    transfers.push({
      from: l.args.from as Address,
      to: l.args.to as Address,
      value: l.args.value as bigint,
      timestamp: await timestampOf(l.blockNumber!),
    });
  }

  const windowEnd = await timestampOf(toBlock);
  const intervals = balanceIntervals(transfers, windowEnd);

  // Price shares in assets at the chain head: convertToAssets below is called
  // with no blockNumber, so it resolves against 'latest' at the moment this
  // script runs, not against each interval's start. That is deliberate.
  // Archive queries are not reliable on Robinhood Chain (the orbit-preflight
  // package exists because of that), and this vault's share price only ever
  // goes up, so pricing at the head can under no circumstance exclude a
  // wallet that genuinely qualified; the worst it can do is over-include one
  // that was marginally short of a tier back at deposit time. Over-inclusion
  // at the margin is an acceptable cost for a distribution mechanism;
  // wrongly excluding someone from an immutable Merkle root is not.
  const vaultAbi = parseAbi(['function convertToAssets(uint256) view returns (uint256)']);
  const priceCache = new Map<string, bigint>();
  const toAssets = (shares: bigint): bigint => {
    const key = shares.toString();
    const hit = priceCache.get(key);
    if (hit !== undefined) return hit;
    throw new Error(`price for ${key} not prefetched`);
  };
  for (const spans of intervals.values()) {
    for (const s of spans) {
      const key = s.balance.toString();
      if (priceCache.has(key)) continue;
      priceCache.set(key, await client.readContract({
        address: vault, abi: vaultAbi, functionName: 'convertToAssets', args: [s.balance],
      }));
    }
  }

  // Funding edges: native transfers into each candidate. Kept separate from the
  // allocation maths so the exclusion is auditable on its own.
  const fundings: Funding[] = [];
  const clusters = clusterOf(fundings);

  const rows: { address: string; amount: bigint }[] = [];
  for (const [addr, spans] of intervals) {
    const amount = allocationFor(spans, toAssets, SEASON_1_TIERS);
    if (amount > 0n) rows.push({ address: getAddress(addr), amount });
  }

  // One member per cluster, the earliest seen, so a shared funder does not
  // punish a genuine user.
  const kept = new Map<string, { address: string; amount: bigint }>();
  for (const r of rows) {
    const root = clusters.get(r.address.toLowerCase()) ?? r.address.toLowerCase();
    if (!kept.has(root)) kept.set(root, r);
  }

  console.log('address,amount');
  for (const r of kept.values()) console.log(`${r.address},${formatUnits(r.amount, 18)}`);
  console.error(`${kept.size} qualifying addresses, ${rows.length - kept.size} excluded by clustering`);
}

main().catch((e) => { console.error(e); process.exit(1); });

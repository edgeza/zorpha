import type { Address } from 'viem';

/**
 * One ERC20 Transfer of vault shares.
 *
 * Shares are the unit, not assets. A holder can acquire them by depositing (a
 * mint, `from` the zero address) or by being sent them by another wallet, so
 * reading the vault's Deposit and Withdraw events would miss the second case
 * and undercount real holders.
 */
export interface ShareTransfer {
  from: Address;
  to: Address;
  value: bigint;
  /** Unix seconds of the block the transfer landed in. */
  timestamp: number;
}

/** A span over which an address held a constant share balance. */
export interface BalanceInterval {
  balance: bigint;
  start: number;
  end: number;
}

const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000';

/**
 * Turn a Transfer log into, per address, the spans over which its balance did
 * not change. The last span of every address runs to `windowEnd`, which is
 * what makes "held continuously until the snapshot" expressible.
 */
export function balanceIntervals(
  transfers: ShareTransfer[],
  windowEnd: number,
): Map<string, BalanceInterval[]> {
  const ordered = [...transfers].sort((a, b) => a.timestamp - b.timestamp);
  const balances = new Map<string, bigint>();
  const out = new Map<string, BalanceInterval[]>();

  const touch = (addr: string, at: number, delta: bigint) => {
    if (addr === ZERO_ADDRESS) return;
    const prior = balances.get(addr) ?? 0n;
    const spans = out.get(addr) ?? [];
    if (spans.length > 0) spans[spans.length - 1].end = at;
    const next = prior + delta;
    spans.push({ balance: next, start: at, end: windowEnd });
    balances.set(addr, next);
    out.set(addr, spans);
  };

  for (const t of ordered) {
    touch(t.from.toLowerCase(), t.timestamp, -t.value);
    touch(t.to.toLowerCase(), t.timestamp, t.value);
  }
  return out;
}

/** A qualifying band. Tiers are evaluated best first, and do not stack. */
export interface Tier {
  /** Minimum asset value, in the asset's own decimals (USDG, 6dp). */
  minAssets: bigint;
  /** Minimum continuous seconds at or above `minAssets`. */
  minSeconds: number;
  /** Fixed allocation, in ZOR wei. */
  allocation: bigint;
}

const ZOR = (whole: bigint) => whole * 10n ** 18n;
const USDG = (whole: bigint) => whole * 10n ** 6n;
const DAYS = (n: number) => n * 86_400;

/**
 * Ten times the capital and twice the duration earns 2.67 times the
 * allocation. The compression is the point: this is a gate with a nod to
 * commitment, not a weight. Tier 2 is a hard cap, so no amount of capital
 * concentrates the tranche.
 */
export const SEASON_1_TIERS: Tier[] = [
  { minAssets: USDG(250n), minSeconds: DAYS(60), allocation: ZOR(40_000n) },
  { minAssets: USDG(25n), minSeconds: DAYS(30), allocation: ZOR(15_000n) },
];

/**
 * The best allocation these intervals earn, or 0n.
 *
 * Continuity is per tier: a run of consecutive intervals each priced at or
 * above the tier's minimum counts, and any interval that dips below breaks it.
 * That is why a withdraw and redeposit does not accumulate.
 */
export function allocationFor(
  intervals: BalanceInterval[],
  toAssets: (shares: bigint, at: number) => bigint,
  tiers: Tier[],
): bigint {
  for (const tier of tiers) {
    let run = 0;
    for (const span of intervals) {
      if (toAssets(span.balance, span.start) >= tier.minAssets) {
        run += span.end - span.start;
        if (run >= tier.minSeconds) return tier.allocation;
      } else {
        run = 0;
      }
    }
  }
  return 0n;
}

/** "from funded to", at `timestamp`. Native or USDG, the caller decides. */
export interface Funding {
  from: string;
  to: string;
  timestamp: number;
}

/**
 * Union find over funding edges. Returns address to cluster root.
 *
 * Sharing a funder is evidence, not proof: an exchange hot wallet funds
 * thousands of unrelated people. The caller decides what to do with a cluster;
 * this only reports the grouping.
 */
export function clusterOf(fundings: Funding[]): Map<string, string> {
  const parent = new Map<string, string>();
  const find = (x: string): string => {
    const p = parent.get(x);
    if (p === undefined || p === x) return x;
    const root = find(p);
    parent.set(x, root);
    return root;
  };
  const union = (a: string, b: string) => {
    const ra = find(a);
    const rb = find(b);
    if (ra !== rb) parent.set(ra, rb);
  };
  for (const f of fundings) {
    const from = f.from.toLowerCase();
    const to = f.to.toLowerCase();
    if (!parent.has(from)) parent.set(from, from);
    if (!parent.has(to)) parent.set(to, to);
    union(from, to);
  }
  const out = new Map<string, string>();
  for (const a of parent.keys()) out.set(a, find(a));
  return out;
}

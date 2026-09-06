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

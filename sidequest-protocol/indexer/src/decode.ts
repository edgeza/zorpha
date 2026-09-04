/**
 * Pure decoding for the receipts indexer.
 *
 * Extracted from index.ts because that module starts a service on import --
 * it builds an RPC client, reads config that throws on missing env vars, and
 * calls main(). None of that can be imported by a test, so the one part of the
 * indexer where a mistake is invisible had no way to be exercised.
 *
 * The mistake it was hiding: `tokenLegs` was decoded from every rotation
 * rebalance and dropped on the floor. basketCommitment binds it, so those
 * receipts carried a hash that could not be recomputed from the stored row.
 * A hash nobody can check looks exactly like a hash nobody has checked yet,
 * which is why it survived. See migration 006.
 *
 * Nothing in here does I/O. That is the point.
 */

import type { RebalanceRow, VaultRow, VaultType } from './supabase.js';

/** The shape viem hands back from getLogs for a decoded event. */
export type DecodedLog = {
  args?: Record<string, unknown>;
  blockNumber: bigint;
  transactionHash: string;
  logIndex: number;
};

/**
 * Outer windows for a scan. Each becomes one cursor advance, so a long backfill
 * checkpoints as it goes rather than only at the very end.
 *
 * Capped at 20 windows per cycle: without a cap, a first run against a chain
 * already at block 111,000,000 would try to scan the entire history in one
 * cycle and never reach the live tail. Successive cycles pick up where this one
 * stopped.
 */
export function planWindows(from: bigint, to: bigint, size: bigint): [bigint, bigint][] {
  const windows: [bigint, bigint][] = [];
  let cursor = from;
  while (cursor <= to && windows.length < 20) {
    const end = cursor + size - 1n > to ? to : cursor + size - 1n;
    windows.push([cursor, end]);
    cursor = end + 1n;
  }
  return windows;
}

/** uint256 values stay STRINGS. See the note on token_legs below. */
const asBig = (v: unknown): string | null =>
  typeof v === 'bigint' ? v.toString() : null;

/**
 * Map one decoded `Rebalanced` log to the row that gets written.
 *
 * The three vault types share an event NAME and nothing else:
 *
 *   spot      Rebalanced(uint16 targetBps, uint256 assetLeg, uint256 cashLeg,
 *                        uint256 navPerShare, uint256 nonce, bytes32 commitment)
 *   rotation  Rebalanced(uint16[] targetBps, uint256 navInBase,
 *                        uint256[] tokenLegs, uint256 baseLeg,
 *                        uint256 nonce, bytes32 commitment)
 *   yield     Rebalanced(uint256 navPerShare, uint256 totalAssetsInAdapter,
 *                        uint256 adapterBalance, uint256 nonce,
 *                        bytes32 commitment)
 *
 * so `targetBps` is a number on one and an array on another, and the NAV
 * arrives under two different names. Every branch below is that, not taste.
 */
export function toRebalanceRow(
  vault: Pick<VaultRow, 'address' | 'vault_type' | 'manager_address'>,
  entry: DecodedLog,
  blockTimestamp: string,
  navDecimals?: number,
): RebalanceRow {
  const args = entry.args ?? {};
  const type: VaultType = vault.vault_type;

  return {
    vault_address: vault.address,
    vault_type: type,
    // The vault's configured manager, which is what KEEPER_ROLE actually
    // enforces. Deliberately NOT tx.from: submission is permissionless, so
    // the sender is frequently a keeper and attributing the trade to them
    // would misstate authorship on a protocol built around attribution.
    manager: vault.manager_address,
    submitter: null,
    block_number: Number(entry.blockNumber),
    tx_hash: entry.transactionHash,
    log_index: entry.logIndex,
    block_timestamp: blockTimestamp,

    target_bps: type === 'spot' && typeof args.targetBps === 'number' ? args.targetBps : null,

    target_weights:
      type === 'rotation' && Array.isArray(args.targetBps)
        ? (args.targetBps as readonly number[]).map(Number)
        : null,

    // Decoded all along and discarded until migration 006. basketCommitment
    // binds it, so a receipt without it cannot be verified. Decimal STRINGS,
    // not numbers: these are uint256 balances and a JSON number is a double, so
    // Number() silently rounds an 18-decimal leg -- the same class of error as
    // the hash this exists to let somebody check.
    token_legs:
      type === 'rotation' && Array.isArray(args.tokenLegs)
        ? (args.tokenLegs as readonly bigint[]).map((v) => v.toString())
        : null,

    asset_leg:
      type === 'spot'
        ? asBig(args.assetLeg)
        : type === 'yield'
          ? asBig(args.totalAssetsInAdapter)
          : null,

    cash_leg:
      type === 'spot'
        ? asBig(args.cashLeg)
        : type === 'rotation'
          ? asBig(args.baseLeg)
          : asBig(args.adapterBalance),

    nav_per_share: asBig(args.navPerShare ?? args.navInBase),
    // The SCALE of the number above, stored beside it. Without it a renderer
    // has to guess, and guessing 18 put every rotation and yield receipt out by
    // 10^12 -- a NAV of 1.000000 displayed as 0.00000 on the public feed.
    nav_decimals: navDecimals ?? null,
    nonce: typeof args.nonce === 'bigint' ? Number(args.nonce) : 0,
    commitment: (args.commitment as string | undefined) ?? null,
  };
}

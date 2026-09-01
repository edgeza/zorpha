import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { config } from './config.js';

export const supabase: SupabaseClient = createClient(
  config.supabase.url,
  config.supabase.serviceRoleKey,
  { auth: { persistSession: false, autoRefreshToken: false } },
);

/** Postgres unique-violation. Used to treat a re-indexed log as a no-op. */
const UNIQUE_VIOLATION = '23505';

export type VaultType = 'spot' | 'rotation' | 'yield';

export type VaultRow = {
  address: string;
  vault_type: VaultType;
  name: string;
  symbol: string;
  asset: string;
  cash?: string | null;
  base_asset?: string | null;
  oracle?: string | null;
  strategy: string;
  manager_address: string;
};

export type RebalanceRow = {
  vault_address: string;
  vault_type: VaultType;
  manager: string;
  submitter: string | null;
  block_number: number;
  tx_hash: string;
  log_index: number;
  block_timestamp: string;
  target_bps?: number | null;
  target_weights?: unknown | null;
  asset_leg?: string | null;
  cash_leg?: string | null;
  nav_per_share?: string | null;
  nonce: number;
  commitment?: string | null;
};

export type ReputationRow = {
  contract_address: string;
  manager_address: string;
  commitment: string;
  window_start: string;
  window_end: string;
  nonce: number;
  challenge_deadline: string;
  tx_hash: string;
};

export async function upsertVault(v: VaultRow): Promise<void> {
  const { error } = await supabase.from('vaults').upsert(v, { onConflict: 'address' });
  if (error) throw new Error(`upsertVault failed: ${error.message}`);
}

export async function getKnownVaults(): Promise<VaultRow[]> {
  const { data, error } = await supabase
    .from('vaults')
    .select('address,vault_type,name,symbol,asset,cash,base_asset,oracle,strategy,manager_address');
  if (error) throw new Error(`getKnownVaults failed: ${error.message}`);
  return (data ?? []) as VaultRow[];
}

/**
 * Insert a batch of receipts, ignoring ones already indexed.
 *
 * A single statement rather than a loop: the previous revision issued one
 * INSERT per log and one RPC per insert, so a 500-log backfill chunk became
 * 1000 sequential round trips to Supabase.
 *
 * @returns how many rows were newly inserted.
 */
export async function insertRebalances(rows: RebalanceRow[]): Promise<number> {
  if (rows.length === 0) return 0;

  const { data, error } = await supabase
    .from('rebalances')
    // (tx_hash, log_index) is unique; ignoreDuplicates makes a re-scan a no-op
    // instead of an error, which is what makes the whole pipeline idempotent.
    .upsert(rows, { onConflict: 'tx_hash,log_index', ignoreDuplicates: true })
    .select('id');

  if (error) {
    if (error.code === UNIQUE_VIOLATION) return 0;
    throw new Error(`insertRebalances failed: ${error.message}`);
  }
  return data?.length ?? 0;
}

/** Atomic counter bump. Requires migration 002. */
export async function bumpManager(address: string, blockTimestamp: string): Promise<void> {
  const { error } = await supabase.rpc('bump_manager', {
    p_address: address,
    p_last_seen: blockTimestamp,
  });
  if (error) {
    // Deliberately fatal. The previous revision swallowed this and fell back to
    // an upsert that never touched total_rebalances, so the leaderboard silently
    // read zero for every manager forever. A missing migration should be loud.
    throw new Error(
      `bumpManager RPC failed: ${error.message}. ` +
        'Has migration 002_indexer_state_and_counters.sql been applied?',
    );
  }
}

export async function insertReputationPublish(r: ReputationRow): Promise<boolean> {
  const { error } = await supabase
    .from('reputation_publishes')
    .upsert([r], { onConflict: 'contract_address,manager_address,nonce', ignoreDuplicates: true });
  if (error) {
    if (error.code === UNIQUE_VIOLATION) return false;
    throw new Error(`insertReputationPublish failed: ${error.message}`);
  }
  return true;
}

/** Record a dispute against a published commitment. */
export async function markChallenged(args: {
  contractAddress: string;
  managerAddress: string;
  nonce: number;
  challenger: string;
  counterCommitment: string;
  challengedAt: string;
}): Promise<void> {
  const { error } = await supabase
    .from('reputation_publishes')
    .update({
      challenged: true,
      challenger: args.challenger,
      counter_commitment: args.counterCommitment,
      challenged_at: args.challengedAt,
      // upheld stays NULL: disputed-and-unresolved is not the same as
      // overturned, and conflating them is what made the on-chain `upheld` flag
      // forgeable in the first place (audit V-06).
      upheld: null,
    })
    .eq('contract_address', args.contractAddress)
    .eq('manager_address', args.managerAddress)
    .eq('nonce', args.nonce);
  if (error) throw new Error(`markChallenged failed: ${error.message}`);
}

/** Record an arbiter's resolution of a dispute. */
export async function markResolved(args: {
  contractAddress: string;
  managerAddress: string;
  nonce: number;
  upheld: boolean;
  arbiter: string;
  resolvedAt: string;
}): Promise<void> {
  const { error } = await supabase
    .from('reputation_publishes')
    .update({
      upheld: args.upheld,
      arbiter: args.arbiter,
      resolved_at: args.resolvedAt,
    })
    .eq('contract_address', args.contractAddress)
    .eq('manager_address', args.managerAddress)
    .eq('nonce', args.nonce);
  if (error) throw new Error(`markResolved failed: ${error.message}`);
}

// ─── Cursor ─────────────────────────────────────────────────────────────────

export type CursorKind = 'vault' | 'registry';

export async function getCursor(kind: CursorKind, address: string): Promise<bigint | null> {
  const { data, error } = await supabase
    .from('indexer_cursor')
    .select('last_block')
    .eq('source_kind', kind)
    .eq('source_address', address)
    .maybeSingle();

  if (error) {
    throw new Error(
      `getCursor failed: ${error.message}. ` +
        'Has migration 002_indexer_state_and_counters.sql been applied?',
    );
  }
  if (!data) return null;
  return BigInt(data.last_block as number | string);
}

export async function advanceCursor(
  kind: CursorKind,
  address: string,
  block: bigint,
): Promise<void> {
  const { error } = await supabase.rpc('advance_cursor', {
    p_kind: kind,
    p_address: address,
    p_block: Number(block),
  });
  if (error) throw new Error(`advanceCursor failed: ${error.message}`);
}

export async function recordCursorError(
  kind: CursorKind,
  address: string,
  message: string,
): Promise<void> {
  // Best-effort: never let error reporting mask the original error.
  const { error } = await supabase.rpc('record_cursor_error', {
    p_kind: kind,
    p_address: address,
    p_error: message.slice(0, 1000),
  });
  if (error) console.error(`[indexer] recordCursorError failed: ${error.message}`);
}

/** Cheap connectivity probe for the health endpoint. */
export async function pingDatabase(): Promise<boolean> {
  const { error } = await supabase.from('vaults').select('address').limit(1);
  return !error;
}

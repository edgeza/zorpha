import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { config } from './config.js';

/**
 * The client, built on first use rather than at import.
 *
 * `createClient` throws on an empty URL, and in `DRY_RUN` there are
 * deliberately no credentials -- so constructing this at module scope made the
 * dry run impossible before a single line of it could execute.
 */
let _client: SupabaseClient | null = null;

function db(): SupabaseClient {
  if (config.dryRun) {
    throw new Error(
      'supabase: a write path was reached during DRY_RUN. This is a bug in the ' +
        'dry-run wiring, not a configuration problem -- every writer should be ' +
        'short-circuited before it gets here.',
    );
  }
  if (_client === null) {
    _client = createClient(config.supabase.url, config.supabase.serviceRoleKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
  }
  return _client;
}

/** Kept for callers that hold the client directly. */
export function getSupabaseClient(): SupabaseClient {
  return db();
}

/** What a dry run would have written, for the summary at the end. */
export const dryRunTally = {
  rebalances: 0,
  managers: new Set<string>(),
  reputation: 0,
  samples: [] as unknown[],
};

/** Postgres unique-violation. Used to treat a re-indexed log as a no-op. */
const UNIQUE_VIOLATION = '23505';

export type VaultType = 'spot' | 'rotation' | 'yield';

/**
 * Which Robinhood Chain a row belongs to. 46630 testnet, 4663 mainnet.
 *
 * Required rather than optional on every row type below. An optional field
 * lets a writer that forgets it type-check cleanly, and a forgotten chain is
 * the exact bug migrations 011 and 012 exist to stop -- once a mainnet row is
 * written as testnet it is indistinguishable from real testnet history.
 */
export type ChainScoped = { chain_id: number };

export type VaultRow = ChainScoped & {
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

export type RebalanceRow = ChainScoped & {
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
  /** Rotation only. uint256 balances as decimal STRINGS -- see migration 006.
   *  Needed to recompute basketCommitment; without it a rotation receipt
   *  carries a hash nobody can check. */
  token_legs?: unknown | null;
  asset_leg?: string | null;
  cash_leg?: string | null;
  nav_per_share?: string | null;
  /** Unit nav_per_share is in: asset() for spot and yield, baseAsset() for
   *  rotation. Stored per receipt so a row can be read without joining a
   *  mutable table beside it -- see migration 007. */
  nav_decimals?: number | null;
  nonce: number;
  commitment?: string | null;
};

export type ReputationRow = ChainScoped & {
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
  const { error } = await db()
    .from('vaults')
    .upsert(v, { onConflict: 'chain_id,address' });
  if (error) throw new Error(`upsertVault failed: ${error.message}`);
}

export async function getKnownVaults(): Promise<VaultRow[]> {
  if (config.dryRun) {
    // No `vaults` table to read, so take the list from VAULT_ADDRESSES and
    // resolve each one's type on chain. `manager_address` is left as the zero
    // address: attribution comes from the table, so a dry run cannot exercise
    // it, and inventing a plausible-looking address would make the output look
    // like it had verified something it has not.
    const { detectVaultType } = await import('./chain.js');
    const rows: VaultRow[] = [];
    for (const address of config.vaultAddresses) {
      const vault_type = await detectVaultType(address);
      if (vault_type === null) {
        throw new Error(
          `DRY_RUN: could not type ${address}. Exactly one of cashAsset(), ` +
            'basketLength() or adapter() must answer. Either this is not a Zorpha ' +
            'vault, or the RPC is dropping calls.',
        );
      }
      rows.push({
        chain_id: config.chainId,
        address,
        vault_type,
        name: '(dry run)',
        symbol: '(dry run)',
        asset: '0x0000000000000000000000000000000000000000',
        strategy: '(dry run)',
        manager_address: '0x0000000000000000000000000000000000000000',
      });
    }
    return rows;
  }

  // The chain filter is the whole point of migration 012. Without it this
  // returns every vault in the table, and an indexer on 4663 scans the three
  // testnet vaults 008 registered -- addresses with no code on mainnet, so
  // getLogs returns [] rather than an error and every cycle reports success.
  //
  // `listed` is deliberately NOT filtered on: an unlisted vault is hidden from
  // the storefront, not retired from history, and its receipts should keep
  // arriving. Chain is the thing that makes a row unscannable, not visibility.
  const { data, error } = await db()
    .from('vaults')
    .select(
      'chain_id,address,vault_type,name,symbol,asset,cash,base_asset,oracle,strategy,manager_address',
    )
    .eq('chain_id', config.chainId);
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

  if (config.dryRun) {
    dryRunTally.rebalances += rows.length;
    for (const r of rows) {
      if (dryRunTally.samples.length < 5) dryRunTally.samples.push(r);
    }
    return rows.length;
  }

  const { data, error } = await db()
    .from('rebalances')
    // (chain_id, tx_hash, log_index) is unique since migration 011;
    // ignoreDuplicates makes a re-scan a no-op instead of an error, which is
    // what makes the whole pipeline idempotent. The arbiter must name every
    // column of the constraint or PostgREST answers 42P10.
    .upsert(rows, { onConflict: 'chain_id,tx_hash,log_index', ignoreDuplicates: true })
    .select('id');

  if (error) {
    if (error.code === UNIQUE_VIOLATION) return 0;
    throw new Error(`insertRebalances failed: ${error.message}`);
  }
  return data?.length ?? 0;
}

/** Atomic counter bump. Requires migration 012. */
export async function bumpManager(address: string, blockTimestamp: string): Promise<void> {
  if (config.dryRun) {
    dryRunTally.managers.add(address.toLowerCase());
    return;
  }

  // Three arguments, chain first. The two-argument signature is retired and
  // raises with an explanation -- see migration 012. `managers` is keyed
  // (address, chain_id), so the same manager operating on both chains keeps
  // two independent receipt counts rather than one merged total.
  const { error } = await db().rpc('bump_manager', {
    p_chain_id: config.chainId,
    p_address: address,
    p_last_seen: blockTimestamp,
  });
  if (error) {
    // Deliberately fatal. The previous revision swallowed this and fell back to
    // an upsert that never touched total_rebalances, so the leaderboard silently
    // read zero for every manager forever. A missing migration should be loud.
    throw new Error(
      `bumpManager RPC failed: ${error.message}. ` +
        'Has migration 012-cursor-and-vault-chain-scope.sql been applied?',
    );
  }
}

export async function insertReputationPublish(r: ReputationRow): Promise<boolean> {
  if (config.dryRun) {
    dryRunTally.reputation += 1;
    return true;
  }

  const { error } = await db()
    .from('reputation_publishes')
    .upsert([r], {
      onConflict: 'chain_id,contract_address,manager_address,nonce',
      ignoreDuplicates: true,
    });
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
  if (config.dryRun) return;

  const { error } = await db()
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
    // Chain-scoped to match the (chain_id, contract_address, manager_address,
    // nonce) key. Without it a dispute on one chain would also mark the
    // same-nonce publish on the other, since registry addresses and nonces
    // both restart per deployment.
    .eq('chain_id', config.chainId)
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
  if (config.dryRun) return;

  const { error } = await db()
    .from('reputation_publishes')
    .update({
      upheld: args.upheld,
      arbiter: args.arbiter,
      resolved_at: args.resolvedAt,
    })
    .eq('chain_id', config.chainId)
    .eq('contract_address', args.contractAddress)
    .eq('manager_address', args.managerAddress)
    .eq('nonce', args.nonce);
  if (error) throw new Error(`markResolved failed: ${error.message}`);
}

// ─── Cursor ─────────────────────────────────────────────────────────────────

export type CursorKind = 'vault' | 'registry';

export async function getCursor(kind: CursorKind, address: string): Promise<bigint | null> {
  if (config.dryRun) return null;

  // Chain-scoped. This is the read that decides where a scan resumes, and it
  // is the one that made repointing look safe: the testnet cursors sit at
  // ~112.5M, mainnet's head is ~55.2M, so an unscoped read returned a testnet
  // height and every mainnet window came back empty with no error at all.
  const { data, error } = await db()
    .from('indexer_cursor')
    .select('last_block')
    .eq('chain_id', config.chainId)
    .eq('source_kind', kind)
    .eq('source_address', address)
    .maybeSingle();

  if (error) {
    throw new Error(
      `getCursor failed: ${error.message}. ` +
        'Has migration 012-cursor-and-vault-chain-scope.sql been applied?',
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
  if (config.dryRun) return;

  const { error } = await db().rpc('advance_cursor', {
    p_chain_id: config.chainId,
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
  if (config.dryRun) return;

  // Best-effort: never let error reporting mask the original error.
  const { error } = await db().rpc('record_cursor_error', {
    p_chain_id: config.chainId,
    p_kind: kind,
    p_address: address,
    p_error: message.slice(0, 1000),
  });
  if (error) console.error(`[indexer] recordCursorError failed: ${error.message}`);
}

/** Cheap connectivity probe for the health endpoint. */
export async function pingDatabase(): Promise<boolean> {
  if (config.dryRun) return true;

  // Filters on chain_id so /readyz fails if migration 012 has not been applied
  // -- a plain select would pass against the old schema and the service would
  // report ready while every write path was about to raise 42P10.
  const { error } = await db()
    .from('vaults')
    .select('address')
    .eq('chain_id', config.chainId)
    .limit(1);
  return !error;
}

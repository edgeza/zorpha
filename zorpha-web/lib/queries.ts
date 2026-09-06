import { activeChain } from './chains';
import {
  getSupabase,
  supabaseConfigured,
  type ManagerRow,
  type RebalanceRow,
  type ReputationRow,
  type VaultRow,
} from './supabase';

/**
 * Every query degrades to empty rather than throwing.
 *
 * The marketing site and the portal shell must render before the indexer and
 * Supabase project exist. A hard throw here would turn "backend not wired yet"
 * into a 500 on the home page, which is the worst possible failure mode during
 * a launch window. Callers render an explicit empty state instead.
 */

/**
 * The chain this build serves. Every query below filters on it.
 *
 * One Supabase project holds both deployments' rows, separated only by
 * `chain_id` (migrations 011 and 012). An unfiltered query returns both, and
 * the failure is silent and public: pointing the site at mainnet changed the
 * RPC and the contract addresses but not the data, so /portal/vaults served
 * three TESTNET vaults to mainnet visitors, each with a mandate and a manager,
 * none of which has any code on 4663. Someone who picked one and deposited
 * would have sent funds to an empty address.
 *
 * Migration 010 patched that by unlisting those three rows by hand, and said
 * of itself: "correct only while production points at mainnet". Run the app
 * against testnet after 010 and it shows the mainnet vault -- the same bug
 * mirrored. Filtering on chain_id is the fix 010 was standing in for, and it
 * is correct in both directions.
 */
const CHAIN_ID = activeChain.id;

/** Postgres "column does not exist" -- i.e. migration 012 has not been run. */
const UNDEFINED_COLUMN = '42703';

async function safe<T>(label: string, run: () => Promise<T>, fallback: T): Promise<T> {
  if (!supabaseConfigured) return fallback;
  try {
    return await run();
  } catch (error) {
    // Surfaced in server logs; the page shows an empty state.
    console.error(`[zorpha] query "${label}" failed:`, error);
    return fallback;
  }
}

/**
 * Is this a vault we would show a depositor?
 *
 * Belt to migration 004's braces. The drills deploy real contracts with real
 * names -- "Zorpha Loss Drill Vault", "Zorpha Leader Test Vault", "Zorpha
 * Staleness Drill" -- and those are recognisable without a database column.
 *
 * Deliberately conservative in the direction of hiding: a real vault
 * accidentally matching one of these words is a support ticket, while a drill
 * vault on the storefront is someone depositing into a contract whose bond has
 * been slashed. It also runs in JS rather than SQL so it still applies when the
 * query above has fallen back.
 */
function isNotADrill(v: VaultRow): boolean {
  if (v.listed === false) return false;
  const hay = `${v.name ?? ''} ${v.symbol ?? ''}`.toLowerCase();
  return !/drill|test|stale|bond|lead/.test(hay);
}

export async function listVaults(): Promise<VaultRow[]> {
  return safe(
    'listVaults',
    async () => {
      // Two layers, because they fail in opposite directions.
      //
      // `listed` is the durable fix (migration 004): unlisting becomes a
      // property of the row, so a re-seed or an indexer backfill cannot
      // silently promote a drill vault to the storefront the way a DELETE
      // allowed. Without it this did `select('*')` unfiltered, and "Zorpha
      // Leader Test Vault" and "Zorpha Loss Drill Vault" were advertised to
      // users as live products with mandates and manager addresses.
      //
      // But the column only exists once someone runs the migration, and until
      // then the filtered query fails with 42703 and `safe()` returns [] --
      // an EMPTY vault list, which is worse than the problem. So the name
      // exclusion below runs regardless, and the query degrades to unfiltered
      // when the column is missing. The fix works before the migration and
      // gets stronger after it.
      let { data, error } = await getSupabase()!
        .from('vaults')
        .select('*')
        .eq('chain_id', CHAIN_ID)
        .eq('listed', true)
        .order('deployed_at', { ascending: true });

      if (error && error.code === UNDEFINED_COLUMN) {
        // One of the two columns is not migrated yet. Degrade rather than
        // showing nothing: an EMPTY vault list is worse than an imprecise one,
        // and migration 010 already unlisted the testnet rows by hand, so the
        // fallback is still correct for the mainnet build it was written for.
        console.warn(
          '[zorpha] vaults.chain_id or vaults.listed missing: run ' +
            'migrations/012-cursor-and-vault-chain-scope.sql (and 004). ' +
            'Falling back to name-based exclusion, which cannot tell the two ' +
            'chains apart.',
        );
        ({ data, error } = await getSupabase()!
          .from('vaults')
          .select('*')
          .order('deployed_at', { ascending: true }));
      }
      if (error) throw error;

      return ((data ?? []) as VaultRow[]).filter(isNotADrill);
    },
    [],
  );
}

export async function getVault(address: string): Promise<VaultRow | null> {
  return safe(
    'getVault',
    async () => {
      const { data, error } = await getSupabase()!
        .from('vaults')
        .select('*')
        .eq('chain_id', CHAIN_ID)
        .ilike('address', address)
        .maybeSingle();
      if (error) throw error;
      return (data as VaultRow | null) ?? null;
    },
    null,
  );
}

export async function listRebalancesForVault(
  address: string,
  limit = 200,
): Promise<RebalanceRow[]> {
  return safe(
    'listRebalancesForVault',
    async () => {
      const { data, error } = await getSupabase()!
        .from('rebalances')
        .select('*')
        .eq('chain_id', CHAIN_ID)
        .ilike('vault_address', address)
        .order('block_timestamp', { ascending: false })
        .limit(limit);
      if (error) throw error;
      return (data ?? []) as RebalanceRow[];
    },
    [],
  );
}

export async function listRebalancesForManager(
  manager: string,
  limit = 200,
): Promise<RebalanceRow[]> {
  return safe(
    'listRebalancesForManager',
    async () => {
      const { data, error } = await getSupabase()!
        .from('rebalances')
        .select('*')
        .eq('chain_id', CHAIN_ID)
        .ilike('manager', manager)
        .order('block_timestamp', { ascending: false })
        .limit(limit);
      if (error) throw error;
      return (data ?? []) as RebalanceRow[];
    },
    [],
  );
}

export async function listLatestRebalances(limit = 50): Promise<RebalanceRow[]> {
  return safe(
    'listLatestRebalances',
    async () => {
      const { data, error } = await getSupabase()!
        .from('rebalances')
        .select('*')
        .eq('chain_id', CHAIN_ID)
        .order('block_timestamp', { ascending: false })
        .limit(limit);
      if (error) throw error;
      return (data ?? []) as RebalanceRow[];
    },
    [],
  );
}

export async function listManagers(): Promise<ManagerRow[]> {
  return safe(
    'listManagers',
    async () => {
      const { data, error } = await getSupabase()!
        .from('managers')
        .select('*')
        .eq('chain_id', CHAIN_ID)
        .order('total_rebalances', { ascending: false });
      if (error) throw error;
      return (data ?? []) as ManagerRow[];
    },
    [],
  );
}

export async function getManager(address: string): Promise<ManagerRow | null> {
  return safe(
    'getManager',
    async () => {
      const { data, error } = await getSupabase()!
        .from('managers')
        .select('*')
        .eq('chain_id', CHAIN_ID)
        .ilike('address', address)
        .maybeSingle();
      if (error) throw error;
      return (data as ManagerRow | null) ?? null;
    },
    null,
  );
}

export async function listReputationForManager(manager: string): Promise<ReputationRow[]> {
  return safe(
    'listReputationForManager',
    async () => {
      const { data, error } = await getSupabase()!
        .from('reputation_publishes')
        .select('*')
        .eq('chain_id', CHAIN_ID)
        .ilike('manager_address', manager)
        .order('created_at', { ascending: false });
      if (error) throw error;
      return (data ?? []) as ReputationRow[];
    },
    [],
  );
}

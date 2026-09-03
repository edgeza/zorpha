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
      const q = getSupabase()!.from('vaults').select('*');
      let { data, error } = await q
        .eq('listed', true)
        .order('deployed_at', { ascending: true });

      if (error && error.code === '42703') {
        // Column not migrated yet. Fall back rather than showing nothing.
        console.warn(
          '[zorpha] vaults.listed missing — run migrations/004-vault-visibility.sql. ' +
            'Falling back to name-based exclusion.',
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
        .ilike('manager_address', manager)
        .order('created_at', { ascending: false });
      if (error) throw error;
      return (data ?? []) as ReputationRow[];
    },
    [],
  );
}

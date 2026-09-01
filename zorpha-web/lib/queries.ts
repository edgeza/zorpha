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

export async function listVaults(): Promise<VaultRow[]> {
  return safe(
    'listVaults',
    async () => {
      const { data, error } = await getSupabase()!
        .from('vaults')
        .select('*')
        .order('deployed_at', { ascending: true });
      if (error) throw error;
      return (data ?? []) as VaultRow[];
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

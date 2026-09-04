import { createClient, type SupabaseClient } from '@supabase/supabase-js';

/**
 * Lazily-created Supabase client, safe on both server and client.
 *
 * Two deliberate changes from the previous revision:
 *
 *  1. No `'use client'`. This module is imported by server components (the
 *     receipts and leaderboard pages render on the server), and marking a
 *     data-access module as client-only puts it on the wrong side of the RSC
 *     boundary.
 *
 *  2. The client is created on first use, not at import time. `createClient('',
 *     '')` throws, so an unset NEXT_PUBLIC_SUPABASE_URL used to blow up the
 *     whole build during prerender. The marketing site has to render before
 *     the indexer exists, so an unconfigured backend degrades to "no data"
 *     rather than a failed deploy.
 */

const url = process.env.NEXT_PUBLIC_SUPABASE_URL ?? '';
const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY ?? '';

let cached: SupabaseClient | null = null;

export const supabaseConfigured = Boolean(url && anonKey);

export function getSupabase(): SupabaseClient | null {
  if (!supabaseConfigured) return null;
  if (!cached) cached = createClient(url, anonKey);
  return cached;
}

export type VaultType = 'spot' | 'rotation' | 'yield';

export type VaultRow = {
  /**
   * False hides the vault from the portal index. See migration 004.
   *
   * Optional because rows written before that migration have no value for it,
   * and the column defaults to true -- a real vault should appear without
   * anyone remembering a flag. What must not happen by accident is a drill
   * vault appearing, and the migration's trigger handles that on write.
   */
  listed?: boolean;
  address: `0x${string}`;
  vault_type: VaultType;
  name: string;
  symbol: string;
  asset: `0x${string}`;
  cash: `0x${string}` | null;
  base_asset: `0x${string}` | null;
  oracle: `0x${string}` | null;
  strategy: string;
  manager_address: `0x${string}`;
  deployed_at: string;
};

export type RebalanceRow = {
  id: string;
  vault_address: `0x${string}`;
  vault_type: VaultType;
  manager: `0x${string}`;
  block_number: number;
  tx_hash: `0x${string}`;
  log_index: number;
  block_timestamp: string;
  target_bps: number | null;
  target_weights: number[] | null;
  asset_leg: string | null;
  cash_leg: string | null;
  nav_per_share: string | null;
  /** Scale of nav_per_share. Null on rows indexed before migration 007,
   *  where 18 is the historical fallback. */
  nav_decimals?: number | null;
  nonce: number;
  commitment: string | null;
};

export type ManagerRow = {
  address: `0x${string}`;
  label: string | null;
  avatar_url: string | null;
  first_seen_at: string;
  total_rebalances: number;
  last_active_at: string | null;
};

export type ReputationRow = {
  id: string;
  manager_address: `0x${string}`;
  contract_address: `0x${string}`;
  commitment: `0x${string}`;
  window_start: string;
  window_end: string;
  nonce: number;
  challenge_deadline: string;
  challenged: boolean;
  upheld: boolean | null;
  tx_hash: `0x${string}`;
};

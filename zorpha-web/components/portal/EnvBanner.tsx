'use client';

import { useBlockNumber } from 'wagmi';
import { activeChain } from '@/lib/chains';
import { misconfiguredContracts } from '@/lib/contracts';

const LABELS: Record<string, string> = {
  zor: 'ZOR token',
  vaultLauncher: 'Vault launcher',
  vesting: 'Vesting',
  merkleDistributor: 'Airdrop distributor',
  buyback: 'Buyback',
  treasury: 'Treasury',
  insurance: 'Insurance fund',
  timelock: 'Timelock',
  vaultFactory: 'Vault factory',
  strategyExecutor: 'Strategy executor',
  reputationRegistry: 'Reputation registry',
  // Was missing, so the banner printed the raw key `leaderFaucet` at a reader
  // who has no reason to know the codebase's variable names.
  leaderFaucet: 'Bond faucet',
  oracle: 'Price oracle',
  spotVault: 'Spot vault',
  rotationVault: 'Rotation vault',
  yieldVault: 'Yield vault',
};

/**
 * Honest environment banner.
 *
 * Before this existed, an unconfigured address silently became the zero address
 * and the UI rendered a confident "0" for every balance. Saying "not deployed"
 * out loud is the difference between an empty state and a wrong one.
 *
 * IT NOW ALSO CHECKS THE CHAIN IS REACHABLE, which is a different failure and
 * was the one actually biting production. Every address was configured
 * correctly and the site still showed an em dash in every on-chain field,
 * because the CSP's `connect-src` named a different RPC host than
 * `NEXT_PUBLIC_RPC_URL` did and the browser blocked all of it:
 *
 *     Connecting to 'https://testnet.rpc.robinhood.com/' violates the
 *     following Content Security Policy directive: "connect-src ..."
 *
 * Nothing surfaced that. The page rendered, the Supabase-backed panels worked,
 * the vault list was correct, and only the chain reads were dead -- so the site
 * looked healthy while being unable to read a single number. The launch form's
 * buttons stayed greyed out with no stated reason, because they wait on a bond
 * amount that could never arrive.
 *
 * A block-number read is the cheapest possible proof of reachability: if it
 * fails, nothing else on the page can work either, and the banner says so
 * instead of leaving a reader to guess from a screen of dashes.
 *
 * IT NOW REPORTS ONLY UNEXPECTED ABSENCES. It previously counted every unset
 * address, which on mainnet meant permanently announcing "7 contract addresses
 * are unset, so the panels below have nothing to read" while those panels read
 * perfectly well. Six of the seven are deliberate -- the oracle, executor and
 * two priced vaults are not on 4663 by decision, the bond faucet is testnet-
 * only -- and the seventh, the yield vault, is deployed and simply not named by
 * an env var any more. See `isExpectedAbsence` for the per-key reasoning.
 *
 * A banner that is always on is a banner nobody reads on the day it matters.
 */
export function EnvBanner() {
  const missing = misconfiguredContracts();

  const { isError: chainUnreachable, error } = useBlockNumber({
    chainId: activeChain.id,
    query: { retry: 1, staleTime: 30_000, refetchInterval: 60_000 },
  });

  if (chainUnreachable) {
    const blockedByCsp = /Content Security Policy|violates|Refused to connect/i.test(
      error?.message ?? '',
    );
    return (
      <div className="border-b border-red-600/30 bg-red-500/[0.07]">
        <div className="shell flex flex-col gap-1.5 py-3 sm:flex-row sm:items-start sm:gap-3">
          <span className="badge-danger shrink-0">Chain unreachable</span>
          <p className="text-xs leading-relaxed text-red-200/90">
            This build cannot reach {activeChain.name}, so every on-chain figure below is blank
            and every transaction button is disabled. Nothing is wrong with your wallet.{' '}
            {blockedByCsp
              ? "The browser is blocking the request under this site's own Content Security Policy — the configured RPC host is not on its allowlist."
              : 'The configured RPC endpoint is not responding.'}
          </p>
        </div>
      </div>
    );
  }

  if (missing.length === 0) return null;

  return (
    <div className="border-b border-amber-600/30 bg-amber-500/[0.07]">
      <div className="shell flex flex-col gap-1.5 py-3 sm:flex-row sm:items-center sm:gap-3">
        <span className="badge-warn shrink-0">Not configured</span>
        <p className="text-xs leading-relaxed text-amber-200/90">
          {missing.length} contract {missing.length === 1 ? 'address is' : 'addresses are'} unset
          in this environment, so the panels below have nothing to read:{' '}
          <span className="font-mono">{missing.map((k) => LABELS[k] ?? k).join(', ')}</span>.
        </p>
      </div>
    </div>
  );
}

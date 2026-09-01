'use client';

import { missingContracts } from '@/lib/contracts';

const LABELS: Record<string, string> = {
  zor: 'ZOR token',
  vesting: 'Vesting',
  merkleDistributor: 'Airdrop distributor',
  buyback: 'Buyback',
  treasury: 'Treasury',
  insurance: 'Insurance fund',
  timelock: 'Timelock',
  vaultFactory: 'Vault factory',
  strategyExecutor: 'Strategy executor',
  reputationRegistry: 'Reputation registry',
};

/**
 * Honest environment banner.
 *
 * Before this existed, an unconfigured address silently became the zero address
 * and the UI rendered a confident "0" for every balance. Saying "not deployed"
 * out loud is the difference between an empty state and a wrong one.
 */
export function EnvBanner() {
  const missing = missingContracts();
  if (missing.length === 0) return null;

  return (
    <div className="border-b border-amber-600/30 bg-amber-500/[0.07]">
      <div className="shell flex flex-col gap-1.5 py-3 sm:flex-row sm:items-center sm:gap-3">
        <span className="badge-warn shrink-0">Not configured</span>
        <p className="text-xs leading-relaxed text-amber-200/90">
          {missing.length} contract {missing.length === 1 ? 'address is' : 'addresses are'} unset
          in this environment, so the panels below have nothing to read:{' '}
          <span className="font-mono">
            {missing.map((k) => LABELS[k] ?? k).join(', ')}
          </span>
          .
        </p>
      </div>
    </div>
  );
}

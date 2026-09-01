import type { Metadata } from 'next';
import { VestingPanel } from '@/components/portal/VestingPanel';
import { RequireWallet } from '@/components/portal/WalletButton';

export const metadata: Metadata = { title: 'Vesting' };

export default function VestingPage() {
  return (
    <div className="flex max-w-3xl flex-col gap-8">
      <header>
        <h1 className="text-2xl font-semibold tracking-tight sm:text-3xl">Vesting</h1>
        <p className="mt-3 text-sm leading-relaxed text-ink-400">
          Contributor and backer allocations vest linearly behind a cliff. Tokens are pre-deposited
          into the vesting contract when a schedule is created, so a claim can never fail because
          the treasury is short.
        </p>
      </header>

      <RequireWallet message="Connect the wallet your allocation was assigned to.">
        <VestingPanel />
      </RequireWallet>
    </div>
  );
}

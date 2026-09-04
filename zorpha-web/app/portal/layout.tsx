import type { Metadata } from 'next';
import type { ReactNode } from 'react';
import { PortalNav } from '@/components/portal/PortalNav';
import { EnvBanner } from '@/components/portal/EnvBanner';
import { activeChain } from '@/lib/chains';

export const metadata: Metadata = {
  title: 'Portal',
  description:
    'Zorpha portal. Vault positions, live rebalance receipts, manager records, airdrop and vesting claims, governance.',
  robots: { index: false, follow: false },
};

export default function PortalLayout({ children }: { children: ReactNode }) {
  return (
    <div className="flex min-h-dvh flex-col">
      <PortalNav />
      <EnvBanner />
      <main id="main" className="shell flex-1 py-8 sm:py-10">
        {children}
      </main>
      <footer className="hairline mt-10">
        <div className="shell flex flex-col gap-2 py-6 text-2xs text-ink-500 sm:flex-row sm:items-center sm:justify-between">
          <p>Zorpha portal · {activeChain.name}</p>
          <p>All values are read directly from contracts. Nothing here is investment advice.</p>
        </div>
      </footer>
    </div>
  );
}

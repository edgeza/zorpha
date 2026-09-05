import type { Metadata } from 'next';
import type { ReactNode } from 'react';
import { PortalNav } from '@/components/portal/PortalNav';
import { EnvBanner } from '@/components/portal/EnvBanner';
import { activeChain } from '@/lib/chains';
import { assertServerChain } from '@/lib/chain-guard';

export const metadata: Metadata = {
  /**
   * A template, not a bare string. A plain `title` in a layout stops the root
   * template reaching this subtree, so /portal rendered as "Portal · Zorpha"
   * while every page under it rendered as bare "Vesting", "Receipts",
   * "Governance" -- the whole portal losing the site name in the browser tab
   * and in bookmarks.
   */
  title: {
    // Bare 'Portal': the ROOT template still applies to this segment's own
    // default, so spelling the suffix here renders "Portal - Zorpha - Zorpha".
    default: 'Portal',
    template: '%s · Zorpha',
  },
  description:
    'Zorpha portal. Vault positions, live rebalance receipts, manager records, airdrop and vesting claims, governance.',
  robots: { index: false, follow: false },
};

/**
 * The chain check lives here, not on each page, so a route added tomorrow gets
 * it for free. `indexer/src/index.ts:277` describes the cost of the other
 * arrangement: a per-page step "is exactly the step that gets forgotten after a
 * redeploy".
 *
 * It throws only when the RPC serves a different chain than NEXT_PUBLIC_CHAIN_ID
 * claims -- a state in which every address on the page comes from one chain and
 * every balance beside it from another. An unreachable RPC is logged and
 * rendered through; see lib/chain-guard.ts for why those two are not the same
 * failure.
 */
export default async function PortalLayout({ children }: { children: ReactNode }) {
  await assertServerChain();

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

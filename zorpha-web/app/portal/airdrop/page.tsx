import type { Metadata } from 'next';
import { AirdropClaim } from '@/components/portal/AirdropClaim';
import { RequireWallet } from '@/components/portal/WalletButton';
import { ALLOCATIONS, TOKEN, tokensFor } from '@/lib/tokenomics';
import { formatCompact } from '@/lib/format';

export const metadata: Metadata = { title: 'Airdrop' };

export default function AirdropPage() {
  const community = ALLOCATIONS.find((a) => a.key === 'community')!;

  return (
    <div className="flex max-w-3xl flex-col gap-8">
      <header>
        <h1 className="text-2xl font-semibold tracking-tight sm:text-3xl">Season 1 airdrop</h1>
        <p className="mt-3 text-sm leading-relaxed text-ink-400">
          {formatCompact(tokensFor(community.tgeBps))} {TOKEN.ticker}, or {community.tgeBps / 100}% of
          max supply, is funded on-chain and reserved for the Season 1 airdrop. The snapshot criteria
          have not been published yet, so no wallet has an allocation to check against. Claims will be
          pull-based: nothing is airdropped into your wallet without you asking for it.
        </p>
      </header>

      <RequireWallet message="Connect the wallet you want to check for a Season 1 allocation.">
        <AirdropClaim />
      </RequireWallet>
    </div>
  );
}

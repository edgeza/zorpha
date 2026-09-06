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
          max supply, is funded on-chain and reserved for the Season 1 airdrop. Season 1 allocates
          8,000,000 of it; the rest stays with governance for later seasons. Claims are pull-based:
          nothing is airdropped into your wallet without you asking for it.
        </p>
        <p className="mt-3 text-sm leading-relaxed text-ink-400">
          Two tiers, measured over a 90 day window. Depositing at least 25 USDG into a Zorpha vault
          and holding it for 30 continuous days earns 15,000 {TOKEN.ticker}. At least 250 USDG held
          for 60 continuous days earns 40,000 {TOKEN.ticker}. Tier 2 is a cap, not a rate: more
          capital earns no more than 40,000. Wallets funded from a common source are treated as one
          participant.
        </p>
        <p className="mt-3 text-sm leading-relaxed text-ink-400">
          Worth saying plainly: at the current market price 15,000 {TOKEN.ticker} is worth about
          twenty cents. This is a claim on the token being worth something later, not a payment, and
          you should treat it that way when deciding whether to take part.
        </p>
      </header>

      <RequireWallet message="Connect the wallet you want to check for a Season 1 allocation.">
        <AirdropClaim />
      </RequireWallet>
    </div>
  );
}

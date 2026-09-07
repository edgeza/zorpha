import type { Metadata } from 'next';
import { AirdropClaim } from '@/components/portal/AirdropClaim';
import { RequireWallet } from '@/components/portal/WalletButton';
import { Callout } from '@/components/ui/Primitives';
import { formatCompact } from '@/lib/format';
import { ALLOCATIONS, TOKEN, tokensFor } from '@/lib/tokenomics';

export const metadata: Metadata = { title: 'Airdrop' };

/**
 * Season 1's fixed slice of the tranche below, 8,000,000 (10% of the
 * tranche, 0.8% of max supply). This is a design constant from the Season 1
 * plan, not a bps split of max supply, so it is not part of lib/tokenomics.ts.
 */
const SEASON_1_TOKENS = 8_000_000;

export default function AirdropPage() {
  const community = ALLOCATIONS.find((a) => a.key === 'community')!;
  const tranche = tokensFor(community.tgeBps);

  return (
    <div className="flex max-w-3xl flex-col gap-8">
      <header>
        <h1 className="text-2xl font-semibold tracking-tight sm:text-3xl">Season 1 airdrop</h1>
        <p className="mt-3 text-sm leading-relaxed text-ink-400">
          {formatCompact(tranche)} {TOKEN.ticker}, or {community.tgeBps / 100}% of max supply, is
          funded on-chain and held by governance. Season 1 uses {formatCompact(SEASON_1_TOKENS)} of
          that; the remaining {formatCompact(tranche - SEASON_1_TOKENS)} is not part of Season 1 and
          stays with governance for later seasons.
        </p>
        <p className="mt-3 text-sm leading-relaxed text-ink-400">
          Claims are meant to be pull-based: nothing sent to your wallet without you asking for it.
          That is not live yet. The distributor deployed today already paid out this whole tranche in
          one claim to governance, and it cannot pay Season 1 allocations. A second distributor,
          funded with exactly the qualifying total, is deployed only after the 90 day window closes
          and the snapshot runs.
        </p>
        <p className="mt-3 text-sm leading-relaxed text-ink-400">
          Two tiers, measured over a 90 day window. Depositing at least 25 USDG into a Zorpha vault
          and holding it for 30 continuous days earns 15,000 {TOKEN.ticker}. At least 250 USDG held
          for 60 continuous days earns 40,000 {TOKEN.ticker}. Tier 2 is a cap, not a rate: more
          capital earns no more than 40,000. The protocol reserves the right to exclude wallets it
          judges to be one participant splitting a deposit across many addresses; no automated
          clustering runs today.
        </p>
        <p className="mt-3 text-sm leading-relaxed text-ink-400">
          Worth saying plainly: at the market price as of 6 September 2026, 15,000 {TOKEN.ticker}
          (tier 1) is worth about twenty cents, and 40,000 {TOKEN.ticker} (tier 2) is worth about
          fifty-six cents. This is a claim on the token being worth something later, not a payment,
          and you should treat it that way when deciding whether to take part.
        </p>
      </header>

      <Callout tone="warn" title="Before you lock money for 30 to 60 days">
        <p>
          The vault contracts are not externally audited yet; see the roadmap for detail. Principal
          is at risk from adapter and venue failure: a first-loss escrow absorbs losses before
          depositors do, but it is a limited buffer, not a guarantee. Withdrawing even one day early
          forfeits the whole allocation rather than a pro-rated share, so 29 days into a 30 day tier
          still earns zero. Gas for the deposit, the withdrawal and the claim will likely cost more
          than the reward is worth at today&apos;s price.
        </p>
      </Callout>

      <RequireWallet message="Connect the wallet you want to check for a Season 1 allocation.">
        <AirdropClaim />
      </RequireWallet>
    </div>
  );
}

import type { Metadata } from 'next';
import Link from 'next/link';
import { LaunchVaultForm } from '@/components/portal/LaunchVaultForm';
import { LeaderFaucetClaim } from '@/components/portal/LeaderFaucetClaim';

export const metadata: Metadata = {
  title: 'Launch a vault',
  description:
    'Post a $ZOR bond and your own first-loss capital, and run a vault on Zorpha. No permission needed, and no way to launch one without capital behind your depositors.',
};

export default function LaunchVaultPage() {
  return (
    <div className="space-y-8">
      <div>
        <Link href="/portal/leaders" className="text-xs text-ink-500 hover:text-ink-300">
          ← Vault leaders
        </Link>
        <h1 className="mt-3 text-2xl font-semibold tracking-tight sm:text-3xl">
          Launch a vault
        </h1>
        <p className="mt-3 max-w-2xl text-sm leading-relaxed text-ink-400">
          Anyone can run a vault here. The gate is capital, not permission: a refundable $ZOR
          bond, and your own money standing in front of your depositors&rsquo;.
        </p>
      </div>

      {/*
        Before the form, not after. The bond requirement is the first thing
        that stops a prospective leader, and $ZOR has no mint function -- so
        somebody arriving here without a bond previously had no route forward
        at all and no explanation of why. Putting the faucet above the form
        means the blocker and its remedy are in the same glance.
      */}
      <LeaderFaucetClaim />

      <LaunchVaultForm />

      <div className="card-pad">
        <h2 className="text-sm font-semibold text-ink-100">What you are agreeing to</h2>
        <ul className="mt-3 space-y-2 text-xs leading-relaxed text-ink-400">
          <li>
            <strong className="text-ink-300">Your capital absorbs losses first.</strong> That is the
            entire point of the design and it is not a formality. If the venue loses money, your
            escrow pays before any depositor is touched, up to its full balance.
          </li>
          <li>
            <strong className="text-ink-300">You cannot withdraw it freely.</strong> Withdrawals
            require a request, a seven-day delay, and coverage staying above the floor at the moment
            of execution — not merely at the moment you asked.
          </li>
          <li>
            <strong className="text-ink-300">Fees rebuild the buffer before they pay you.</strong>{' '}
            While coverage is short, your 80% share is retained into the escrow rather than sent to
            you.
          </li>
          <li>
            <strong className="text-ink-300">You cannot touch depositor funds.</strong> A leader
            directs allocation between approved venues. There is no path from that role to
            withdrawing someone else&rsquo;s deposit, changing the mandate, or raising the fee.
          </li>
          <li>
            <strong className="text-ink-300">The bond comes back.</strong> Call{' '}
            <code className="font-mono text-ink-300">reclaimBond</code> once the vault is empty.
            Governance can slash it for misconduct; the contract comments are explicit that a
            market drawdown is not misconduct, because slashing for beta would make bonding
            irrational.
          </li>
        </ul>
      </div>
    </div>
  );
}

import Link from 'next/link';
import type { Metadata } from 'next';
import { BridgePanel } from '@/components/tools/BridgePanel';
import { SectionHeading } from '@/components/ui/Primitives';
import { robinhoodMainnet } from '@/lib/chains';

export const metadata: Metadata = {
  title: 'Zorpha Bridging',
  description:
    'Move assets onto Robinhood Chain from Ethereum, Arbitrum, Base, Solana, Bitcoin and 65 other chains. Best-price routing across every major bridge and DEX, fully non-custodial.',
};

const FACTS = [
  {
    k: 'Coverage',
    v: '70 chains',
    note: 'Ethereum, Arbitrum, Base, Optimism, Polygon, BNB, Solana, Bitcoin and Robinhood Chain among them.',
  },
  {
    k: 'Custody',
    v: 'None',
    note: 'Every route settles onchain between your wallet and the bridge contract. Zorpha never holds the funds and cannot stop a transfer.',
  },
  {
    k: 'Routing',
    v: 'Aggregated',
    note: 'Quotes are compared across every major bridge and DEX aggregator, and the best-priced route is the one presented.',
  },
  {
    k: 'Minimum',
    v: '$20',
    note: 'Below that, gas on both sides plus the bridge fee costs more than the transfer is worth.',
  },
];

export default function BridgePage() {
  return (
    <>
      {/* ─── Title ────────────────────────────────────────────────────────── */}
      <section className="relative overflow-hidden border-b border-void-700">
        <div className="spotlight absolute inset-0 -z-10" aria-hidden="true" />
        <div className="shell py-14 sm:py-16">
          <div className="flex flex-wrap items-center gap-2">
            <span className="badge">Tools</span>
            <span className="badge font-mono">chain {robinhoodMainnet.id}</span>
          </div>
          <h1 className="mt-6 max-w-3xl text-3xl leading-tight sm:text-5xl">
            Bring your assets to Robinhood Chain
          </h1>
          <p className="lede mt-5 max-w-2xl">
            The vaults settle on Robinhood Chain. If your capital is on Ethereum, Arbitrum, Base,
            Solana or anywhere else, this moves it across in one step, at the best price available
            from any bridge.
          </p>
        </div>
      </section>

      {/* ─── Widget ───────────────────────────────────────────────────────── */}
      <section className="shell py-14">
        <div className="grid gap-12 lg:grid-cols-[minmax(0,420px)_minmax(0,1fr)] lg:gap-16">
          {/* Full-bleed on phones. The widget will not render narrower than
              360px, and the shell's 20px gutters leave only 335px on a 375px
              screen, so keeping them makes the entire page scroll sideways.
              Cancelling them here gives the widget the full viewport width. */}
          <div className="-mx-5 min-w-0 sm:mx-0">
            <BridgePanel />
          </div>

          <div className="space-y-8">
            <div>
              <SectionHeading
                eyebrow="How it routes"
                title="One form, every bridge"
                lede="Pick where your funds are and where you want them. The route is assembled across whichever bridges and exchanges give the best net output, and executed as a single flow from your wallet."
              />
            </div>

            <dl className="divide-hair rounded-card border border-void-700 bg-void-900/60">
              {FACTS.map((f) => (
                <div key={f.k} className="p-5">
                  <div className="flex items-baseline justify-between gap-6">
                    <dt className="eyebrow">{f.k}</dt>
                    <dd className="font-mono text-sm text-ink-100">{f.v}</dd>
                  </div>
                  <p className="mt-2 text-sm leading-relaxed text-ink-400">{f.note}</p>
                </div>
              ))}
            </dl>

            <div className="card-pad">
              <h2 className="text-base font-semibold text-ink-100">Once you have arrived</h2>
              <p className="mt-2.5 text-sm leading-relaxed text-ink-400">
                The portal shows every vault, its mandate, its fee, and the full history of signed
                rebalances behind it. Read the receipts before you deposit.
              </p>
              <div className="mt-5 flex flex-wrap gap-3">
                <Link href="/portal" className="btn-primary btn-sm">
                  Open the portal
                </Link>
                <Link href="/portal/receipts" className="btn btn-sm">
                  Browse receipts
                </Link>
              </div>
            </div>

            <p className="text-xs leading-relaxed text-ink-500">
              Bridging is provided by LI.FI, a third-party routing aggregator. Zorpha does not
              custody, control, or insure funds in transit, and a bridge transaction that fails or
              is delayed is a matter between you and the bridge that carried it. Robinhood Chain has
              no canonical USDC deployment, so the form opens on USDG, the Paxos-issued stablecoin
              that circulates there. Both sides of the form can be changed to any supported asset.
            </p>
          </div>
        </div>
      </section>
    </>
  );
}

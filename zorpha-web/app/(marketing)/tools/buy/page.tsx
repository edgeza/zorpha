import Link from 'next/link';
import type { Metadata } from 'next';
import { BuyOrGas } from '@/components/tools/BuyOrGas';
import { BuyCost } from '@/components/tools/BuyCost';
import { robinhoodMainnet } from '@/lib/chains';
import { TOKEN } from '@/lib/tokenomics';

export const metadata: Metadata = {
  alternates: { canonical: '/tools/buy' },
  title: 'Buy ZOR',
  description:
    'Buy $ZOR from any chain and any asset in one step. Routes are compared across every major bridge and DEX, the best one is presented, and the pool cost is stated before you sign.',
};

/**
 * Three claims, no prose. The long-form detail these used to carry now sits in
 * one sentence in the fine print, which keeps the hero to a single focal
 * point: an earlier version of this page put four explained facts in a grid
 * below the widget and everything on the screen ended up the same weight.
 */
const CLAIMS = [
  { k: 'Origin', v: '70 chains' },
  { k: 'Wallets', v: 'Any' },
  { k: 'Custody', v: 'Yours' },
] as const;

export default function BuyPage() {
  return (
    <>
      {/* ─── Hero ─────────────────────────────────────────────────────────── */}
      <section className="relative overflow-hidden">
        {/* Ambient only. `grid-lines` is masked to fade out below the fold and
            `spotlight` throws the violet cast from above, both procedural, so
            the hero costs no image request and nothing to lay out. */}
        <div className="spotlight absolute inset-0 -z-20" aria-hidden="true" />
        <div className="grid-lines absolute inset-0 -z-10" aria-hidden="true" />

        <div className="shell py-16 sm:py-24">
          <div className="grid items-center gap-12 lg:grid-cols-[1fr,minmax(0,420px)] lg:gap-16">
            {/* The words. Staggered with the site's own five-delay utilities
                rather than a new keyframe; `prefers-reduced-motion` is handled
                globally in globals.css, which collapses these to their final
                state instead of hiding them. */}
            <div>
              <div className="fade-in-1 flex flex-wrap items-center gap-2">
                <span className="badge">Buy {TOKEN.ticker}</span>
                <span className="badge font-mono">chain {robinhoodMainnet.id}</span>
              </div>

              {/*
                Deliberately not gradient-filled. The site's `text-gradient` is
                tempting here and it would make four accented things compete on
                one screen; the hero holds on size and the display serif alone,
                which leaves the violet free to mark the widget and the one
                number that matters.
              */}
              <h1 className="fade-in-2 mt-7 text-4xl leading-[1.05] sm:text-6xl lg:text-7xl">
                Any wallet.
                <br />
                Any chain.
                <br />
                One step.
              </h1>

              <p className="lede fade-in-3 mt-7 max-w-lg">
                Pay with whatever you already hold, wherever it sits. The best route is worked out
                for you, and the whole cost is on this page before you sign anything.
              </p>

              <dl className="fade-in-4 mt-10 flex flex-wrap gap-x-10 gap-y-5">
                {CLAIMS.map((c) => (
                  <div key={c.k}>
                    <dt className="stat-label">{c.k}</dt>
                    <dd className="mt-1.5 text-lg text-ink-100">{c.v}</dd>
                  </div>
                ))}
              </dl>
            </div>

            {/* The widget, framed as the object you act on.

                `min-w-0` is load-bearing: a grid item defaults to min-width
                auto and the widget carries a 360px min-width, so without it
                the track refuses to shrink and the whole page scrolls sideways
                on a phone. The negative margin cancels the shell padding at
                that size to give the widget the full viewport, which is the
                same wrapper the bridge page uses, and the frame only appears
                from `sm` up because a glowing ring bleeding off both edges of
                a phone reads as a rendering fault. */}
            <div className="fade-in-5 relative -mx-5 min-w-0 sm:mx-0">
              <div
                aria-hidden="true"
                className="absolute -inset-8 -z-10 rounded-full bg-zor-700/20 blur-3xl"
              />
              <BuyOrGas />
            </div>
          </div>
        </div>
      </section>

      {/* ─── What it costs ────────────────────────────────────────────────── */}
      <section className="border-t border-void-700 bg-void-900/40">
        <div className="shell py-14 sm:py-20">
          <h2 className="text-2xl sm:text-3xl">What it costs</h2>
          <p className="mt-4 max-w-2xl text-sm leading-relaxed text-ink-400">
            {TOKEN.ticker} trades against a single pool, and that pool is small. These are not
            warnings about a hypothetical worst case. They are the prices you get, computed from the
            pool a moment ago.
          </p>
          <div className="mt-12">
            <BuyCost />
          </div>
        </div>
      </section>

      {/* ─── Fine print ───────────────────────────────────────────────────── */}
      <section className="border-t border-void-700">
        <div className="shell grid gap-x-16 gap-y-6 py-14 lg:grid-cols-[minmax(0,1fr),minmax(0,1.25fr)]">
          <h2 className="text-lg text-ink-300">Before you buy</h2>
          <div className="space-y-4 text-sm leading-relaxed text-ink-400">
            <p>
              Any wallet reachable over WalletConnect works, which is most of them, MetaMask,
              Coinbase Wallet and Safe included. Origin chains include Ethereum, Arbitrum, Base,
              Optimism, Polygon and BNB, and you do not need anything on Robinhood Chain first.
              Every leg settles onchain from your own wallet, so Zorpha never holds your funds and
              cannot.
            </p>
            <p>
              Robinhood Chain charges gas in ETH, and buying {TOKEN.ticker} does not leave you any:
              the bridge pays for its own delivery, so nothing warns you at the time and the bill
              arrives the first time you try to move or sell. Two dollars of ETH covers roughly a
              dozen transactions at current gas. The panel above will send it, under Get gas.
            </p>
            <p>
              The contracts are deployed and source-verified, and the external audit is still
              outstanding. See the{' '}
              <Link href="/roadmap" className="link-quiet">
                roadmap
              </Link>{' '}
              for what is finished and what is not, and{' '}
              <Link href="/token" className="link-quiet">
                the token page
              </Link>{' '}
              for where every token sits. Nothing here is investment advice, and you should not buy
              more than you are willing to lose entirely.
            </p>
            <p>
              Moving assets across without buying {TOKEN.ticker}?{' '}
              <Link href="/tools/bridge" className="link-quiet">
                The bridge
              </Link>{' '}
              does the same routing to any token on any supported chain.
            </p>
          </div>
        </div>
      </section>
    </>
  );
}

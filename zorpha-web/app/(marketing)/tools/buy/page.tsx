import Link from 'next/link';
import type { Metadata } from 'next';
import { BridgePanel } from '@/components/tools/BridgePanel';
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
 * ZOR, the destination. The bridge page defaults to USDG because its job is
 * funding a vault; this page pins the token instead, so the only decision left
 * to the visitor is what they are paying with.
 */
const ZOR_ADDRESS = '0x9684AFe2422a0B03719201c78959b6B70e8d4ae8';

const FACTS = [
  {
    k: 'Wallets',
    v: 'Any',
    note: 'MetaMask, Coinbase Wallet, Safe, and every wallet reachable over WalletConnect, which is most of them. The widget reads what you already hold and prices the route from there.',
  },
  {
    k: 'Origin',
    v: '70 chains',
    note: 'Ethereum, Arbitrum, Base, Optimism, Polygon, BNB, Solana and Bitcoin among them. You do not need anything on Robinhood Chain first.',
  },
  {
    k: 'Routing',
    v: 'Best of all',
    note: 'Quotes are compared across every major bridge and DEX aggregator and only the best-priced route is shown, rather than inviting you to hand-pick a thin one.',
  },
  {
    k: 'Custody',
    v: 'None',
    note: 'Every leg settles onchain from your own wallet. Zorpha never holds your funds at any point, and cannot.',
  },
];

export default function BuyPage() {
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
            Buy {TOKEN.ticker} from anywhere
          </h1>
          <p className="lede mt-5 max-w-2xl">
            Connect any wallet, pay with whatever you already hold on whichever chain it sits on, and
            the best route is worked out for you. One signature, no bridging first, no account.
          </p>
        </div>
      </section>

      {/* ─── The widget, and what it will cost ────────────────────────────── */}
      <section className="shell py-12 sm:py-16">
        <div className="grid gap-8 lg:grid-cols-[420px,1fr] lg:items-start lg:gap-12">
          {/* `min-w-0` is load-bearing: a grid item defaults to min-width auto
              and the widget carries a 360px min-width, so without it the track
              refuses to shrink and the whole page scrolls sideways on a phone.
              The negative margin cancels the shell's padding at that size, which
              gives the widget the full viewport. Same wrapper as the bridge
              page, which hit this first. */}
          <div className="-mx-5 min-w-0 sm:mx-0">
            <BridgePanel toToken={ZOR_ADDRESS} />
          </div>

          <div className="flex flex-col gap-6">
            <BuyCost />

            {/*
              The honest paragraph. It sits beside the widget rather than below
              it because a cost disclosure a reader has to scroll to find is a
              disclosure designed not to be read.
            */}
            <div className="card p-5">
              <h2 className="text-sm font-semibold">Read this before you buy</h2>
              <p className="mt-3 text-sm leading-relaxed text-ink-400">
                {TOKEN.ticker} trades against a single pool, and that pool is small. The table above
                is not a warning about a hypothetical worst case; it is the price you will get at
                each size, computed from the pool a moment ago. A larger order costs
                disproportionately more, so several small purchases beat one large one.
              </p>
              <p className="mt-3 text-sm leading-relaxed text-ink-400">
                The contracts are deployed and source-verified, and the external audit is still
                outstanding. See the{' '}
                <Link href="/roadmap" className="link-quiet">
                  roadmap
                </Link>{' '}
                for what is finished and what is not, and{' '}
                <Link href="/token" className="link-quiet">
                  the token page
                </Link>{' '}
                for where every token sits. Nothing here is investment advice, and you should not
                buy more than you are willing to lose entirely.
              </p>
            </div>
          </div>
        </div>
      </section>

      {/* ─── Facts ────────────────────────────────────────────────────────── */}
      <section className="border-t border-void-700">
        <div className="shell grid gap-6 py-12 sm:grid-cols-2 lg:grid-cols-4">
          {FACTS.map((f) => (
            <div key={f.k}>
              <p className="font-mono text-2xs uppercase tracking-wide text-ink-500">{f.k}</p>
              <p className="mt-2 text-xl">{f.v}</p>
              <p className="mt-2 text-sm leading-relaxed text-ink-400">{f.note}</p>
            </div>
          ))}
        </div>
      </section>

      {/* ─── Onward ───────────────────────────────────────────────────────── */}
      <section className="border-t border-void-700">
        <div className="shell py-12">
          <p className="text-sm leading-relaxed text-ink-400">
            Moving assets across without buying {TOKEN.ticker}?{' '}
            <Link href="/tools/bridge" className="link-quiet">
              The bridge
            </Link>{' '}
            does the same routing to any token on any supported chain.
          </p>
        </div>
      </section>
    </>
  );
}

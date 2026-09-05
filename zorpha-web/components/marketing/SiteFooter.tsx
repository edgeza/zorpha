import Link from 'next/link';
import { Logo } from '@/components/ui/Primitives';
import { TOKEN } from '@/lib/tokenomics';
import { contracts, explorerAddress } from '@/lib/contracts';

/**
 * Listing aggregators (GeckoTerminal, Blockscout token info) verify a project's
 * socials and contract address against the official site before they will show
 * them. Both therefore have to be publicly rendered here, not just handed to a
 * submission form.
 */
const SOCIALS: { href: string; label: string }[] = [
  { href: 'https://x.com/ZorphaProtocol', label: 'X' },
];

const COLUMNS: { heading: string; links: { href: string; label: string; external?: boolean }[] }[] =
  [
    {
      heading: 'Protocol',
      links: [
        { href: '/whitepaper', label: 'Whitepaper' },
        { href: '/protocol', label: 'How it works' },
        { href: '/protocol#vaults', label: 'Vaults' },
        { href: '/tools/bridge', label: 'Zorpha Bridging' },
        { href: '/roadmap', label: 'Roadmap' },
      ],
    },
    {
      heading: 'Token',
      links: [
        { href: '/token', label: 'Overview' },
        { href: '/token#allocation', label: 'Allocation' },
        { href: '/token#unlocks', label: 'Unlock schedule' },
        { href: '/token#value', label: 'Buyback and burn' },
      ],
    },
    {
      heading: 'Trust',
      links: [
        { href: '/whitepaper#risk', label: 'Risk' },
        { href: '/whitepaper#governance', label: 'Governance' },
        { href: '/portal/governance', label: 'Admin roles' },
        { href: '/faq', label: 'FAQ' },
      ],
    },
    {
      heading: 'Legal',
      links: [
        { href: '/legal/terms', label: 'Terms of use' },
        { href: '/legal/privacy', label: 'Privacy' },
        { href: '/legal/disclaimer', label: 'Risk disclaimer' },
      ],
    },
  ];

export function SiteFooter() {
  return (
    <footer className="mt-24 border-t border-void-700 bg-void-950">
      <div className="shell py-14">
        <div className="grid grid-cols-2 gap-10 sm:grid-cols-3 lg:grid-cols-6">
          <div className="col-span-2 lg:col-span-2">
            <div className="flex items-center gap-2.5">
              <Logo className="h-6 w-auto" />
              <span className="font-display text-base font-semibold text-ink-100">Zorpha</span>
            </div>
            <p className="mt-4 max-w-xs text-sm leading-relaxed text-ink-400">
              Curated vaults on {TOKEN.chain}. Every rebalance is signed onchain and published
              as a receipt anyone can verify.
            </p>
            <div className="mt-5 flex items-center gap-2">
              <span className="badge-zor">{TOKEN.ticker}</span>
              <span className="badge">{TOKEN.domain}</span>
            </div>

            <div className="mt-5 flex items-center gap-3">
              {SOCIALS.map((s) => (
                <a
                  key={s.href}
                  href={s.href}
                  target="_blank"
                  rel="noopener noreferrer me"
                  aria-label={`Zorpha on ${s.label}`}
                  className="inline-flex h-8 w-8 items-center justify-center rounded-md border border-void-700 text-ink-400 transition-colors hover:border-void-600 hover:text-ink-100"
                >
                  <svg viewBox="0 0 24 24" aria-hidden="true" className="h-3.5 w-3.5 fill-current">
                    <path d="M18.244 2.25h3.308l-7.227 8.26 8.502 11.24H16.17l-5.214-6.817L4.99 21.75H1.68l7.73-8.835L1.254 2.25H8.08l4.713 6.231zm-1.161 17.52h1.833L7.084 4.126H5.117z" />
                  </svg>
                </a>
              ))}
            </div>

            <p className="mt-5 text-2xs leading-relaxed text-ink-500">
              {TOKEN.ticker} contract
              <br />
              <a
                href={explorerAddress(contracts.zor)}
                target="_blank"
                rel="noopener noreferrer"
                className="break-all font-mono text-ink-400 underline-offset-2 transition-colors hover:text-ink-100 hover:underline"
              >
                {contracts.zor}
              </a>
            </p>
          </div>

          {COLUMNS.map((col) => (
            <div key={col.heading}>
              <h3 className="text-2xs font-medium uppercase tracking-[0.16em] text-ink-500">
                {col.heading}
              </h3>
              <ul className="mt-4 space-y-2.5">
                {col.links.map((link) => (
                  <li key={link.href + link.label}>
                    <Link
                      href={link.href}
                      className="text-sm text-ink-400 transition-colors hover:text-ink-100"
                    >
                      {link.label}
                    </Link>
                  </li>
                ))}
              </ul>
            </div>
          ))}
        </div>

        <div className="mt-12 flex flex-col gap-4 border-t border-void-700 pt-7 text-xs text-ink-500 sm:flex-row sm:items-center sm:justify-between">
          <p>© {new Date().getFullYear()} Zorpha. Contracts released under MIT.</p>
          <p className="max-w-2xl leading-relaxed">
            Nothing on this site is investment advice, an offer to sell, or a solicitation to
            buy any asset. {TOKEN.ticker} is a utility and governance token, not a claim on
            revenue or profit. Digital assets carry risk of total loss.
          </p>
        </div>
      </div>
    </footer>
  );
}

import Link from 'next/link';
import { Logo } from '@/components/ui/Primitives';
import { TOKEN } from '@/lib/tokenomics';

const COLUMNS: { heading: string; links: { href: string; label: string; external?: boolean }[] }[] =
  [
    {
      heading: 'Protocol',
      links: [
        { href: '/protocol', label: 'How it works' },
        { href: '/protocol#vaults', label: 'Vaults' },
        { href: '/protocol#receipts', label: 'Receipts' },
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
        { href: '/security', label: 'Security posture' },
        { href: '/security#audit', label: 'Audit status' },
        { href: '/security#roles', label: 'Admin roles' },
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
              <Logo className="h-6 w-6" />
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

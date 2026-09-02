'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { Wordmark } from '@/components/ui/Primitives';
import { WalletButton } from './WalletButton';

/**
 * Portal navigation.
 *
 * Eight destinations is too many for one undifferentiated row: it read as a
 * wall of same-weight words that scrolled sideways on anything narrow, and the
 * two things a visitor actually comes to do — look at vaults, be a leader —
 * had no more prominence than the vesting page.
 *
 * Grouped instead. "Vaults" and "Leaders" are the product; the rest is record
 * and account. On mobile it becomes a real menu rather than a horizontal
 * scroll, because a nav you have to swipe is a nav most people never finish
 * reading.
 */
const GROUPS: Array<{ label: string; items: Array<{ href: string; label: string }> }> = [
  {
    label: 'Invest',
    items: [
      { href: '/portal/vaults', label: 'Vaults' },
      { href: '/portal/leaders', label: 'Leaders' },
    ],
  },
  {
    label: 'Record',
    items: [
      { href: '/portal/receipts', label: 'Receipts' },
      { href: '/portal/leaderboard', label: 'Managers' },
    ],
  },
  {
    label: 'Your $ZOR',
    items: [
      { href: '/portal/airdrop', label: 'Airdrop' },
      { href: '/portal/vesting', label: 'Vesting' },
      { href: '/portal/governance', label: 'Governance' },
    ],
  },
];

const DASHBOARD = { href: '/portal', label: 'Dashboard' };
const ALL = [DASHBOARD, ...GROUPS.flatMap((g) => g.items)];

function isActive(pathname: string, href: string) {
  return href === '/portal' ? pathname === '/portal' : pathname.startsWith(href);
}

export function PortalNav() {
  const pathname = usePathname();

  return (
    <header className="sticky top-0 z-40 border-b border-void-700 bg-void-950/95 backdrop-blur">
      <div className="shell flex h-14 items-center justify-between gap-4">
        <div className="flex min-w-0 items-center gap-3">
          <Wordmark href="/" />
          <span className="hidden h-4 w-px shrink-0 bg-void-600 sm:block" />
          <span className="hidden shrink-0 text-2xs uppercase tracking-[0.16em] text-ink-500 sm:block">
            Portal
          </span>
        </div>

        {/* Desktop: grouped, with separators carrying the grouping rather than
            labels, which would add a third row of text to a header. */}
        <nav
          className="hidden flex-1 items-center justify-center lg:flex"
          aria-label="Portal sections"
        >
          <NavPill item={DASHBOARD} pathname={pathname} />
          {GROUPS.map((group) => (
            <div key={group.label} className="flex items-center">
              <span className="mx-2 h-4 w-px bg-void-700" aria-hidden />
              {group.items.map((item) => (
                <NavPill key={item.href} item={item} pathname={pathname} />
              ))}
            </div>
          ))}
        </nav>

        <div className="shrink-0">
          <WalletButton />
        </div>
      </div>

      {/* Below lg: a single scrollable row is still the least-bad option, but
          it gets the active item's own label as an anchor and does not pretend
          to be a full menu. */}
      <nav
        className="shell scroll-x flex gap-1 border-t border-void-800 py-2 lg:hidden"
        aria-label="Portal sections"
      >
        {ALL.map((item) => (
          <NavPill key={item.href} item={item} pathname={pathname} />
        ))}
      </nav>
    </header>
  );
}

function NavPill({
  item,
  pathname,
}: {
  item: { href: string; label: string };
  pathname: string;
}) {
  const active = isActive(pathname, item.href);
  return (
    <Link
      href={item.href}
      aria-current={active ? 'page' : undefined}
      className={`shrink-0 rounded-md px-2.5 py-1.5 text-sm transition-colors ${
        active
          ? 'bg-void-800 font-medium text-ink-100'
          : 'text-ink-400 hover:bg-void-800/60 hover:text-ink-200'
      }`}
    >
      {item.label}
    </Link>
  );
}

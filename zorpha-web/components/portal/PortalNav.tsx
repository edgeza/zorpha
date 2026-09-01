'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { Wordmark } from '@/components/ui/Primitives';
import { WalletButton } from './WalletButton';

const NAV = [
  { href: '/portal', label: 'Dashboard' },
  { href: '/portal/vaults', label: 'Vaults' },
  { href: '/portal/receipts', label: 'Receipts' },
  { href: '/portal/leaderboard', label: 'Managers' },
  { href: '/portal/airdrop', label: 'Airdrop' },
  { href: '/portal/vesting', label: 'Vesting' },
  { href: '/portal/governance', label: 'Governance' },
];

export function PortalNav() {
  const pathname = usePathname();

  return (
    <header className="sticky top-0 z-40 border-b border-void-700 bg-void-950">
      <div className="shell flex h-16 items-center justify-between gap-4">
        <div className="flex items-center gap-4">
          <Wordmark href="/" />
          <span className="hidden h-5 w-px bg-void-600 sm:block" />
          <span className="hidden text-xs uppercase tracking-[0.14em] text-ink-500 sm:block">
            Portal
          </span>
        </div>
        <WalletButton />
      </div>

      <nav
        className="shell scroll-x flex gap-1 border-t border-void-800 py-2"
        aria-label="Portal sections"
      >
        {NAV.map((item) => {
          const active =
            item.href === '/portal' ? pathname === '/portal' : pathname.startsWith(item.href);
          return (
            <Link
              key={item.href}
              href={item.href}
              aria-current={active ? 'page' : undefined}
              className={`shrink-0 rounded-md px-3 py-1.5 text-sm transition-colors ${
                active
                  ? 'bg-void-800 text-ink-100'
                  : 'text-ink-400 hover:bg-void-800/60 hover:text-ink-200'
              }`}
            >
              {item.label}
            </Link>
          );
        })}
      </nav>
    </header>
  );
}

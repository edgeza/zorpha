'use client';

import { useEffect, useId, useRef, useState } from 'react';
import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { Wordmark } from '@/components/ui/Primitives';
import { WalletButton } from './WalletButton';

/**
 * Portal navigation.
 *
 * Nine destinations in one undifferentiated row read as a wall of same-weight
 * words. Grouping existed in the data here and was then thrown away at render:
 * every group's items were spread back into a single flat strip with hairline
 * separators, so the structure was invisible and the row still ran to ten
 * items. Below lg it degraded further into a horizontal scroll, and a nav you
 * have to swipe is a nav most people never finish reading.
 *
 * Now the grouping is real. The four things people arrive to do stay one click
 * away; the record and the token pages collapse into two menus. Six top-level
 * targets instead of ten, and the header stops competing with the page.
 *
 * The menus are click-to-open rather than hover-to-open. A hover menu cannot be
 * opened on a touch screen without a tap that also navigates, and it opens by
 * accident on the way to something else.
 */

interface NavItem {
  href: string;
  label: string;
  /** Shown under the label inside a menu. Menus have room; the top bar does not. */
  hint?: string;
}

/** Always visible, because these are what the portal is for. */
const PRIMARY: NavItem[] = [
  { href: '/portal', label: 'Dashboard' },
  { href: '/portal/vaults', label: 'Vaults' },
  { href: '/portal/leaders', label: 'Leaders' },
  { href: '/portal/manage', label: 'Terminal' },
];

const MENUS: Array<{ label: string; items: NavItem[] }> = [
  {
    label: 'Record',
    items: [
      { href: '/portal/receipts', label: 'Receipts', hint: 'Every signed rebalance' },
      { href: '/portal/leaderboard', label: 'Managers', hint: 'Ranked by activity' },
    ],
  },
  {
    label: 'Your $ZOR',
    items: [
      { href: '/portal/airdrop', label: 'Airdrop', hint: 'Season 1 allocation' },
      { href: '/portal/vesting', label: 'Vesting', hint: 'Contributor schedules' },
      { href: '/portal/governance', label: 'Governance', hint: 'Voting weight and control' },
    ],
  },
];

function isActive(pathname: string, href: string) {
  return href === '/portal' ? pathname === '/portal' : pathname.startsWith(href);
}

export function PortalNav() {
  const pathname = usePathname();
  const [openMenu, setOpenMenu] = useState<string | null>(null);
  const [mobileOpen, setMobileOpen] = useState(false);

  // Any navigation closes everything. Without this a menu stays open over the
  // page you just asked for.
  useEffect(() => {
    setOpenMenu(null);
    setMobileOpen(false);
  }, [pathname]);

  useEffect(() => {
    if (!openMenu && !mobileOpen) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        setOpenMenu(null);
        setMobileOpen(false);
      }
    };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [openMenu, mobileOpen]);

  return (
    <header className="sticky top-0 z-40 border-b border-void-700 bg-void-950/95 backdrop-blur">
      <div className="shell flex h-14 items-center gap-4">
        <div className="flex min-w-0 shrink-0 items-center gap-3">
          <Wordmark href="/" />
          <span className="hidden h-4 w-px shrink-0 bg-void-600 sm:block" />
          <span className="hidden shrink-0 text-2xs uppercase tracking-[0.16em] text-ink-500 sm:block">
            Portal
          </span>
        </div>

        <nav className="hidden flex-1 items-center gap-0.5 lg:flex" aria-label="Portal sections">
          {PRIMARY.map((item) => (
            <NavLink key={item.href} item={item} pathname={pathname} />
          ))}
          <span className="mx-2 h-4 w-px bg-void-700" aria-hidden />
          {MENUS.map((menu) => (
            <NavMenu
              key={menu.label}
              label={menu.label}
              items={menu.items}
              pathname={pathname}
              open={openMenu === menu.label}
              onToggle={() => setOpenMenu((cur) => (cur === menu.label ? null : menu.label))}
              onClose={() => setOpenMenu(null)}
            />
          ))}
        </nav>

        <div className="ml-auto flex shrink-0 items-center gap-2">
          <WalletButton />
          <button
            type="button"
            className="btn btn-quiet btn-sm lg:hidden"
            aria-expanded={mobileOpen}
            aria-controls="portal-mobile-nav"
            onClick={() => setMobileOpen((v) => !v)}
          >
            {mobileOpen ? 'Close' : 'Menu'}
          </button>
        </div>
      </div>

      {/*
        A real menu below lg, not a scrolling strip. It shows the group labels
        the desktop bar hides behind a dropdown, so the structure is the same in
        both places.
      */}
      {mobileOpen && (
        <nav
          id="portal-mobile-nav"
          className="shell border-t border-void-800 py-3 lg:hidden"
          aria-label="Portal sections"
        >
          <div className="flex flex-col gap-1">
            {PRIMARY.map((item) => (
              <MobileLink key={item.href} item={item} pathname={pathname} />
            ))}
          </div>
          {MENUS.map((menu) => (
            <div key={menu.label} className="mt-4">
              <p className="stat-label mb-1.5">{menu.label}</p>
              <div className="flex flex-col gap-1">
                {menu.items.map((item) => (
                  <MobileLink key={item.href} item={item} pathname={pathname} />
                ))}
              </div>
            </div>
          ))}
        </nav>
      )}
    </header>
  );
}

function NavLink({ item, pathname }: { item: NavItem; pathname: string }) {
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

function NavMenu({
  label,
  items,
  pathname,
  open,
  onToggle,
  onClose,
}: {
  label: string;
  items: NavItem[];
  pathname: string;
  open: boolean;
  onToggle: () => void;
  onClose: () => void;
}) {
  const ref = useRef<HTMLDivElement>(null);
  const id = useId();

  // A menu that only closes on its own trigger traps the pointer: click
  // anywhere else and it stays open over the content you were reaching for.
  useEffect(() => {
    if (!open) return;
    const onPointerDown = (e: PointerEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) onClose();
    };
    document.addEventListener('pointerdown', onPointerDown);
    return () => document.removeEventListener('pointerdown', onPointerDown);
  }, [open, onClose]);

  // The group carries the active state of whichever child you are on, so the
  // header still tells you where you are while the menu is shut.
  const groupActive = items.some((i) => isActive(pathname, i.href));

  return (
    <div ref={ref} className="relative shrink-0">
      <button
        type="button"
        aria-expanded={open}
        aria-haspopup="true"
        aria-controls={id}
        onClick={onToggle}
        className={`flex items-center gap-1.5 rounded-md px-2.5 py-1.5 text-sm transition-colors ${
          groupActive || open
            ? 'bg-void-800 font-medium text-ink-100'
            : 'text-ink-400 hover:bg-void-800/60 hover:text-ink-200'
        }`}
      >
        {label}
        <svg
          viewBox="0 0 12 12"
          className={`h-2.5 w-2.5 transition-transform ${open ? 'rotate-180' : ''}`}
          aria-hidden
        >
          <path d="M2 4.5 6 8.5 10 4.5" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
        </svg>
      </button>

      {open && (
        <div
          id={id}
          className="absolute left-0 top-full z-50 mt-1.5 min-w-56 rounded-lg border border-void-700 bg-void-900 p-1.5 shadow-xl shadow-black/40"
        >
          {items.map((item) => {
            const active = isActive(pathname, item.href);
            return (
              <Link
                key={item.href}
                href={item.href}
                aria-current={active ? 'page' : undefined}
                className={`flex flex-col gap-0.5 rounded-md px-2.5 py-2 transition-colors ${
                  active ? 'bg-void-800' : 'hover:bg-void-800/70'
                }`}
              >
                <span className={`text-sm ${active ? 'font-medium text-ink-100' : 'text-ink-200'}`}>
                  {item.label}
                </span>
                {item.hint && <span className="text-xs text-ink-500">{item.hint}</span>}
              </Link>
            );
          })}
        </div>
      )}
    </div>
  );
}

function MobileLink({ item, pathname }: { item: NavItem; pathname: string }) {
  const active = isActive(pathname, item.href);
  return (
    <Link
      href={item.href}
      aria-current={active ? 'page' : undefined}
      className={`rounded-md px-3 py-2 text-sm transition-colors ${
        active ? 'bg-void-800 font-medium text-ink-100' : 'text-ink-300 hover:bg-void-800/60'
      }`}
    >
      {item.label}
    </Link>
  );
}

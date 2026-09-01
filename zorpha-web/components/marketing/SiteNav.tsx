'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { useCallback, useEffect, useRef, useState } from 'react';
import { Wordmark } from '@/components/ui/Primitives';

type NavItem =
  | { href: string; label: string }
  | { label: string; items: { href: string; label: string; blurb: string }[] };

const LINKS: NavItem[] = [
  { href: '/protocol', label: 'Protocol' },
  { href: '/whitepaper', label: 'Whitepaper' },
  { href: '/token', label: 'Token' },
  {
    label: 'Tools',
    items: [
      {
        href: '/tools/bridge',
        label: 'Zorpha Bridging',
        blurb: 'Move assets onto Robinhood Chain from 70 chains',
      },
    ],
  },
  { href: '/faq', label: 'FAQ' },
];

function isGroup(item: NavItem): item is Extract<NavItem, { items: unknown[] }> {
  return 'items' in item;
}

const CHEVRON = (
  <svg
    viewBox="0 0 24 24"
    fill="none"
    stroke="currentColor"
    strokeWidth="2"
    strokeLinecap="round"
    strokeLinejoin="round"
    className="h-3 w-3 opacity-70 transition-transform duration-200 group-aria-expanded:rotate-180"
    aria-hidden="true"
  >
    <path d="m6 9 6 6 6-6" />
  </svg>
);

/**
 * Desktop dropdown.
 *
 * Opens on hover and on click, because those are two different audiences: a
 * mouse user expects hover, and a keyboard or touch user has no hover at all.
 * Hover alone would make the menu unreachable without a pointer.
 *
 * The panel is opaque rather than glass. Legibility of a floating panel over
 * arbitrary page content cannot depend on `backdrop-filter` being supported and
 * composited, and where it is not, a translucent panel renders as text over
 * whatever happens to be behind it.
 */
function NavDropdown({
  group,
  pathname,
}: {
  group: Extract<NavItem, { items: unknown[] }>;
  pathname: string;
}) {
  const [open, setOpen] = useState(false);
  const wrapRef = useRef<HTMLDivElement>(null);
  const buttonRef = useRef<HTMLButtonElement>(null);
  const active = group.items.some((i) => pathname.startsWith(i.href));

  // Close on outside pointer-down and on Escape. Escape also returns focus to
  // the trigger, otherwise the focus ring is left orphaned on a hidden panel.
  useEffect(() => {
    if (!open) return;

    const onPointerDown = (e: PointerEvent) => {
      if (!wrapRef.current?.contains(e.target as Node)) setOpen(false);
    };
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        setOpen(false);
        buttonRef.current?.focus();
      }
    };

    document.addEventListener('pointerdown', onPointerDown);
    document.addEventListener('keydown', onKeyDown);
    return () => {
      document.removeEventListener('pointerdown', onPointerDown);
      document.removeEventListener('keydown', onKeyDown);
    };
  }, [open]);

  // Close when focus leaves the whole group, so tabbing past the last item
  // dismisses the panel instead of leaving it hanging open behind the page.
  const onBlur = useCallback((e: React.FocusEvent<HTMLDivElement>) => {
    if (!e.currentTarget.contains(e.relatedTarget as Node | null)) setOpen(false);
  }, []);

  return (
    <div
      ref={wrapRef}
      className="relative"
      onMouseEnter={() => setOpen(true)}
      onMouseLeave={() => setOpen(false)}
      onBlur={onBlur}
    >
      <button
        ref={buttonRef}
        type="button"
        /**
         * Opens, never toggles. A pointer user cannot reach this button
         * without hovering it first, which has already opened the menu, so a
         * toggle would read as "clicking Tools closes Tools". Keyboard and
         * touch users get the open they asked for. Escape, an outside click,
         * moving the pointer away, or a route change all close it.
         */
        onClick={() => setOpen(true)}
        aria-expanded={open}
        aria-haspopup="true"
        className={`group nav-link inline-flex items-center gap-1.5 ${
          active ? 'nav-link-active' : ''
        }`}
      >
        {group.label}
        {CHEVRON}
      </button>

      <div
        className={`absolute left-0 top-full z-50 w-[19rem] pt-2 transition-[opacity,transform] duration-150 ${
          open
            ? 'pointer-events-auto translate-y-0 opacity-100'
            : 'pointer-events-none -translate-y-1 opacity-0'
        }`}
        // Hidden from assistive tech while closed, so a screen reader does not
        // read out links that are not reachable.
        aria-hidden={!open}
      >
        <div className="overflow-hidden rounded-card border border-void-700 bg-void-900 p-1.5 shadow-panel">
          {group.items.map((item) => {
            const itemActive = pathname.startsWith(item.href);
            return (
              <Link
                key={item.href}
                href={item.href}
                tabIndex={open ? undefined : -1}
                aria-current={itemActive ? 'page' : undefined}
                className={`block rounded-lg px-3 py-2.5 transition-colors ${
                  itemActive ? 'bg-void-800' : 'hover:bg-void-800'
                }`}
              >
                <span className="flex items-center gap-2 text-sm font-medium text-ink-100">
                  {item.label}
                  <span className="h-1 w-1 rounded-full bg-zor-400" aria-hidden="true" />
                </span>
                <span className="mt-1 block text-xs leading-relaxed text-ink-400">
                  {item.blurb}
                </span>
              </Link>
            );
          })}
        </div>
      </div>
    </div>
  );
}

/**
 * Floating glass nav.
 *
 * Links and the primary action share one pill, so the header reads as a single
 * floating object over the hero rather than a bar with a button parked beside
 * it.
 *
 * Two states: transparent while the hero is behind it, and an opaque bar once
 * scrolled. The scrolled state is deliberately NOT translucent, legibility
 * would then depend on `backdrop-filter` being both supported and composited,
 * and where it is not the nav renders as text over whatever is behind it.
 * Glass is fine for a pill floating on a controlled gradient; it is not fine
 * for a bar that has to stay readable over arbitrary page content.
 */
export function SiteNav() {
  const pathname = usePathname();
  const [open, setOpen] = useState(false);
  const [scrolled, setScrolled] = useState(false);

  useEffect(() => {
    const onScroll = () => setScrolled(window.scrollY > 24);
    onScroll();
    window.addEventListener('scroll', onScroll, { passive: true });
    return () => window.removeEventListener('scroll', onScroll);
  }, []);

  useEffect(() => setOpen(false), [pathname]);

  return (
    <header
      className={`fixed inset-x-0 top-0 z-40 transition-colors duration-300 ${
        scrolled
          ? 'border-b border-void-700 bg-void-950 shadow-[0_8px_24px_-16px_rgba(0,0,0,0.9)]'
          : 'border-b border-transparent'
      }`}
    >
      <nav
        className={`shell flex items-center justify-between gap-6 transition-[height] duration-300 ${
          scrolled ? 'h-16' : 'h-20'
        }`}
        aria-label="Main"
      >
        <Wordmark />

        <div className="hidden md:flex">
          <div className="nav-pill">
            {LINKS.map((link) =>
              isGroup(link) ? (
                <NavDropdown key={link.label} group={link} pathname={pathname} />
              ) : (
                <Link
                  key={link.href}
                  href={link.href}
                  aria-current={pathname === link.href ? 'page' : undefined}
                  className={`nav-link ${pathname === link.href ? 'nav-link-active' : ''}`}
                >
                  {link.label}
                </Link>
              ),
            )}
            <Link
              href="/portal"
              className="ml-1 inline-flex items-center gap-1.5 rounded-full bg-white px-3.5 py-2 text-sm font-medium text-void-950 transition-colors hover:bg-white/90"
            >
              Open portal
              <svg
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                strokeWidth="2"
                strokeLinecap="round"
                strokeLinejoin="round"
                className="h-3.5 w-3.5"
                aria-hidden="true"
              >
                <path d="M7 7h10v10" />
                <path d="M7 17 17 7" />
              </svg>
            </Link>
          </div>
        </div>

        <button
          type="button"
          onClick={() => setOpen((v) => !v)}
          className="glass inline-flex h-10 w-10 items-center justify-center rounded-full md:hidden"
          aria-expanded={open}
          aria-controls="mobile-nav"
        >
          <span className="sr-only">Toggle navigation</span>
          <svg
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            strokeWidth="1.8"
            strokeLinecap="round"
            className="h-5 w-5 text-white/90"
            aria-hidden="true"
          >
            {open ? (
              <path d="M6 6l12 12M18 6L6 18" />
            ) : (
              <>
                <path d="M4 7h16" />
                <path d="M4 12h16" />
                <path d="M4 17h16" />
              </>
            )}
          </svg>
        </button>
      </nav>

      {open ? (
        <div id="mobile-nav" className="border-t border-void-700 bg-void-950 md:hidden">
          <div className="shell flex flex-col py-3">
            {LINKS.map((link) =>
              isGroup(link) ? (
                // No disclosure on mobile: with one entry, a collapsed group
                // would hide the only thing in it behind an extra tap.
                <div key={link.label} className="mt-2 border-t border-void-700 pt-3 first:mt-0">
                  <p className="px-2 pb-1 text-2xs font-medium uppercase tracking-[0.16em] text-ink-500">
                    {link.label}
                  </p>
                  {link.items.map((item) => (
                    <Link
                      key={item.href}
                      href={item.href}
                      className="block rounded-lg px-2 py-2.5 text-sm text-ink-300 hover:bg-void-800 hover:text-ink-100"
                    >
                      {item.label}
                      <span className="mt-0.5 block text-xs text-ink-500">{item.blurb}</span>
                    </Link>
                  ))}
                </div>
              ) : (
                <Link
                  key={link.href}
                  href={link.href}
                  className="rounded-lg px-2 py-2.5 text-sm text-ink-300 hover:bg-void-800 hover:text-ink-100"
                >
                  {link.label}
                </Link>
              ),
            )}
            <Link href="/portal" className="btn-primary mt-3">
              Open portal
            </Link>
          </div>
        </div>
      ) : null}
    </header>
  );
}

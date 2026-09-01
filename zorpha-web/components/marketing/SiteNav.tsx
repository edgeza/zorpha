'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { useEffect, useState } from 'react';
import { Wordmark } from '@/components/ui/Primitives';

const LINKS = [
  { href: '/protocol', label: 'Protocol' },
  { href: '/token', label: 'Token' },
  { href: '/security', label: 'Security' },
  { href: '/roadmap', label: 'Roadmap' },
  { href: '/faq', label: 'FAQ' },
];

/**
 * Floating glass nav.
 *
 * Links and the primary action share one pill, so the header reads as a single
 * floating object over the hero rather than a bar with a button parked beside
 * it.
 *
 * Two states: transparent while the hero is behind it, and an opaque bar once
 * scrolled. The scrolled state is deliberately NOT translucent — legibility
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
            {LINKS.map((link) => {
              const active = pathname === link.href;
              return (
                <Link
                  key={link.href}
                  href={link.href}
                  aria-current={active ? 'page' : undefined}
                  className={`nav-link ${active ? 'nav-link-active' : ''}`}
                >
                  {link.label}
                </Link>
              );
            })}
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
            {LINKS.map((link) => (
              <Link
                key={link.href}
                href={link.href}
                className="rounded-lg px-2 py-2.5 text-sm text-ink-300 hover:bg-void-800 hover:text-ink-100"
              >
                {link.label}
              </Link>
            ))}
            <Link href="/portal" className="btn-primary mt-3">
              Open portal
            </Link>
          </div>
        </div>
      ) : null}
    </header>
  );
}

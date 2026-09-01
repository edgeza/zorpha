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

export function SiteNav() {
  const pathname = usePathname();
  const [open, setOpen] = useState(false);
  const [scrolled, setScrolled] = useState(false);

  useEffect(() => {
    const onScroll = () => setScrolled(window.scrollY > 8);
    onScroll();
    window.addEventListener('scroll', onScroll, { passive: true });
    return () => window.removeEventListener('scroll', onScroll);
  }, []);

  // Close the mobile sheet whenever the route changes.
  useEffect(() => setOpen(false), [pathname]);

  return (
    <header
      className={`sticky top-0 z-40 transition-colors duration-200 ${
        scrolled
          ? 'border-b border-void-700 bg-void-950 shadow-[0_8px_24px_-16px_rgba(0,0,0,0.9)]'
          : 'border-b border-transparent'
      }`}
    >
      <nav className="shell flex h-16 items-center justify-between gap-6" aria-label="Main">
        <Wordmark />

        <div className="hidden items-center gap-1 md:flex">
          {LINKS.map((link) => {
            const active = pathname === link.href;
            return (
              <Link
                key={link.href}
                href={link.href}
                aria-current={active ? 'page' : undefined}
                className={`rounded-md px-3 py-2 text-sm transition-colors ${
                  active
                    ? 'text-ink-100'
                    : 'text-ink-400 hover:bg-void-800 hover:text-ink-200'
                }`}
              >
                {link.label}
              </Link>
            );
          })}
        </div>

        <div className="flex items-center gap-2">
          <Link href="/portal" className="btn-primary btn-sm hidden sm:inline-flex">
            Open portal
          </Link>
          <button
            type="button"
            onClick={() => setOpen((v) => !v)}
            className="btn btn-sm md:hidden"
            aria-expanded={open}
            aria-controls="mobile-nav"
          >
            <span className="sr-only">Toggle navigation</span>
            <svg viewBox="0 0 20 20" className="h-4 w-4" fill="none" stroke="currentColor">
              {open ? (
                <path d="M5 5l10 10M15 5L5 15" strokeWidth="1.7" strokeLinecap="round" />
              ) : (
                <path d="M3 6h14M3 10h14M3 14h14" strokeWidth="1.7" strokeLinecap="round" />
              )}
            </svg>
          </button>
        </div>
      </nav>

      {open ? (
        <div id="mobile-nav" className="border-t border-void-700 bg-void-950 md:hidden">
          <div className="shell flex flex-col py-3">
            {LINKS.map((link) => (
              <Link
                key={link.href}
                href={link.href}
                className="rounded-md px-2 py-2.5 text-sm text-ink-300 hover:bg-void-800 hover:text-ink-100"
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

import type { ReactNode } from 'react';
import { SiteNav } from '@/components/marketing/SiteNav';
import { SiteFooter } from '@/components/marketing/SiteFooter';

export default function MarketingLayout({ children }: { children: ReactNode }) {
  return (
    <div className="flex min-h-dvh flex-col">
      <SiteNav />
      {/* pt-20 reserves the fixed header's height. The hero cancels it with
          -mt-20 so it can sit underneath the nav full-bleed; every other page
          starts below it. */}
      <main id="main" className="flex-1 pt-20">
        {children}
      </main>
      <SiteFooter />
    </div>
  );
}

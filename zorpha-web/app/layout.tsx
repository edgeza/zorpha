import './globals.css';
import type { Metadata, Viewport } from 'next';
import { Inter, Space_Grotesk, JetBrains_Mono } from 'next/font/google';
import type { ReactNode } from 'react';
import { Providers } from './providers';

const sans = Inter({
  subsets: ['latin'],
  display: 'swap',
  variable: '--font-sans',
});

const display = Space_Grotesk({
  subsets: ['latin'],
  display: 'swap',
  variable: '--font-display',
});

const mono = JetBrains_Mono({
  subsets: ['latin'],
  display: 'swap',
  variable: '--font-mono',
});

const siteUrl = process.env.NEXT_PUBLIC_SITE_URL ?? 'https://zorpha.xyz';

export const metadata: Metadata = {
  metadataBase: new URL(siteUrl),
  title: {
    default: 'Zorpha — verifiable onchain asset management',
    template: '%s · Zorpha',
  },
  description:
    'Zorpha runs curated vaults on Robinhood Chain where every rebalance is signed onchain and published as a public receipt. Fixed-supply $ZOR, fee-funded buyback and burn.',
  keywords: [
    'Zorpha',
    'ZOR',
    'Robinhood Chain',
    'onchain asset management',
    'ERC-4626 vaults',
    'verifiable track record',
    'DeFi',
  ],
  openGraph: {
    type: 'website',
    url: siteUrl,
    siteName: 'Zorpha',
    title: 'Zorpha — verifiable onchain asset management',
    description:
      'Curated vaults where every rebalance is a public, verifiable receipt. Fixed-supply $ZOR with fee-funded buyback and burn.',
  },
  twitter: {
    card: 'summary_large_image',
    title: 'Zorpha — verifiable onchain asset management',
    description:
      'Curated vaults where every rebalance is a public, verifiable receipt. Fixed-supply $ZOR.',
  },
  robots: { index: true, follow: true },
};

export const viewport: Viewport = {
  themeColor: '#06060a',
  colorScheme: 'dark',
};

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html
      lang="en"
      className={`${sans.variable} ${display.variable} ${mono.variable}`}
      suppressHydrationWarning
    >
      <body className="min-h-dvh">
        <a
          href="#main"
          className="sr-only focus:not-sr-only focus:fixed focus:left-4 focus:top-4 focus:z-50 focus:rounded-md focus:bg-zor-600 focus:px-4 focus:py-2 focus:text-sm focus:text-white"
        >
          Skip to content
        </a>
        <Providers>{children}</Providers>
      </body>
    </html>
  );
}

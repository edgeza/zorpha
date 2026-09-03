import './globals.css';
import type { Metadata, Viewport } from 'next';
import { Schibsted_Grotesk, Newsreader, IBM_Plex_Mono } from 'next/font/google';
import type { ReactNode } from 'react';
import { Providers } from './providers';
import { SITE_URL } from '@/lib/site-url';

/**
 * Text face.
 *
 * Schibsted Grotesk was drawn for a news group rather than for a software UI,
 * and it shows: it has a voice, where the neutral grotesques that ship with
 * every product template deliberately have none. Its figures are wide and
 * unambiguous, which is the property that actually matters on a page that is
 * mostly numbers.
 *
 * Only the four weights the site uses are requested. Every extra weight is a
 * separate file on the critical path.
 */
const sans = Schibsted_Grotesk({
  subsets: ['latin'],
  weight: ['400', '500', '600', '700'],
  display: 'swap',
  variable: '--font-sans',
});

/**
 * Display face.
 *
 * Newsreader is an editorial serif designed for reading on screens. It carries
 * real weights, so headings take their hierarchy from the type itself rather
 * than from size alone — which is what a single-weight display serif forces
 * you into, since a synthesised bold smears its thin strokes.
 */
const display = Newsreader({
  subsets: ['latin'],
  weight: ['400', '500', '600'],
  display: 'swap',
  variable: '--font-display',
});

/**
 * Mono.
 *
 * IBM Plex Mono, for its slashed zero and its clearly distinct 1, l and I.
 * That is the entire job on a page full of addresses and transaction hashes,
 * where a misread character is a misread address.
 */
const mono = IBM_Plex_Mono({
  subsets: ['latin'],
  weight: ['400', '500', '600'],
  display: 'swap',
  variable: '--font-mono',
});

const siteUrl = SITE_URL;

export const metadata: Metadata = {
  metadataBase: new URL(siteUrl),
  title: {
    default: 'Zorpha: verifiable onchain asset management',
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
    title: 'Zorpha: verifiable onchain asset management',
    description:
      'Curated vaults where every rebalance is a public, verifiable receipt. Fixed-supply $ZOR with fee-funded buyback and burn.',
  },
  twitter: {
    card: 'summary_large_image',
    title: 'Zorpha: verifiable onchain asset management',
    description:
      'Curated vaults where every rebalance is a public, verifiable receipt. Fixed-supply $ZOR.',
  },
  robots: { index: true, follow: true },
};

export const viewport: Viewport = {
  themeColor: '#06060a',
  colorScheme: 'dark',
};

/**
 * Site-level structured data.
 *
 * `Organization` is what lets a search engine associate the name, the mark and
 * the social accounts with each other instead of guessing, and it is the
 * prerequisite for a knowledge panel. `WebSite` names the site itself. Both are
 * cheap and neither makes a claim that is not already on the page.
 *
 * Injected with `dangerouslySetInnerHTML` because that is how JSON-LD has to be
 * embedded: React would escape the quotes in a plain text child and the block
 * would fail to parse. The content is a serialised literal from this file, not
 * user input, so there is nothing here to inject.
 */
function StructuredData() {
  const graph = {
    '@context': 'https://schema.org',
    '@graph': [
      {
        '@type': 'Organization',
        '@id': `${siteUrl}/#organization`,
        name: 'Zorpha',
        url: siteUrl,
        // Follows the favicon. This is the URL search engines and social
        // platforms fetch for the brand logo, so a stale path here 404s
        // silently -- nothing on the site links to it, so nothing would break
        // visibly. 150x150 clears Google's 112px minimum for an org logo.
        logo: `${siteUrl}/icon.png`,
        description:
          'Zorpha runs curated ERC-4626 vaults on Robinhood Chain where every rebalance is signed onchain and published as a publicly verifiable receipt.',
      },
      {
        '@type': 'WebSite',
        '@id': `${siteUrl}/#website`,
        url: siteUrl,
        name: 'Zorpha',
        publisher: { '@id': `${siteUrl}/#organization` },
        inLanguage: 'en',
      },
    ],
  };

  return (
    <script
      type="application/ld+json"
      dangerouslySetInnerHTML={{ __html: JSON.stringify(graph) }}
    />
  );
}

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
        <StructuredData />
      </body>
    </html>
  );
}

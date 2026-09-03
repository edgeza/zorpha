import type { MetadataRoute } from 'next';
import { SITE_URL } from '@/lib/site-url';

const BASE = SITE_URL;

export default function robots(): MetadataRoute.Robots {
  return {
    rules: [
      {
        userAgent: '*',
        allow: '/',
        // The portal is a wallet-gated app surface; the airdrop endpoint serves
        // per-address lookups and should not be crawled.
        disallow: ['/portal', '/portal/', '/api/'],
      },
    ],
    sitemap: `${BASE}/sitemap.xml`,
    host: BASE,
  };
}

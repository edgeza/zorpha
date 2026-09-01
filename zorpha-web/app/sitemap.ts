import type { MetadataRoute } from 'next';

const BASE = process.env.NEXT_PUBLIC_SITE_URL ?? 'https://zorpha.xyz';

/**
 * Marketing routes only. The portal is `noindex`, being a wallet-gated
 * application surface, not content anyone should reach from a search result.
 */
export default function sitemap(): MetadataRoute.Sitemap {
  const routes: { path: string; priority: number; changeFrequency: 'weekly' | 'monthly' }[] = [
    { path: '', priority: 1, changeFrequency: 'weekly' },
    { path: '/protocol', priority: 0.9, changeFrequency: 'monthly' },
    { path: '/whitepaper', priority: 0.9, changeFrequency: 'monthly' },
    { path: '/token', priority: 0.9, changeFrequency: 'monthly' },
    { path: '/security', priority: 0.8, changeFrequency: 'weekly' },
    { path: '/roadmap', priority: 0.7, changeFrequency: 'monthly' },
    { path: '/faq', priority: 0.7, changeFrequency: 'monthly' },
    { path: '/legal/terms', priority: 0.3, changeFrequency: 'monthly' },
    { path: '/legal/privacy', priority: 0.3, changeFrequency: 'monthly' },
    { path: '/legal/disclaimer', priority: 0.4, changeFrequency: 'monthly' },
  ];

  const lastModified = new Date();

  return routes.map((route) => ({
    url: `${BASE}${route.path}`,
    lastModified,
    changeFrequency: route.changeFrequency,
    priority: route.priority,
  }));
}

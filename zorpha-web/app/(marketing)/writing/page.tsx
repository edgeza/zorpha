import type { Metadata } from 'next';
import Link from 'next/link';

export const metadata: Metadata = {
  alternates: { canonical: '/writing' },
  title: 'Writing',
  description:
    'Engineering notes from building Zorpha on Robinhood Chain. Failures, and what was changed because of them.',
};

/**
 * This index exists so `/writing/<post>` does not imply a parent that 404s.
 *
 * Truncating a URL and landing on nothing is the same small dishonesty as a
 * button labelled "Read the contracts" that leads to a private repository.
 * Two routes, one list, no CMS.
 */
const POSTS: { href: string; date: string; title: string; blurb: string }[] = [
  {
    href: '/writing/silent-failures',
    date: '5 September 2026',
    title: 'Five ways to deploy to the wrong chain, four of them silent',
    blurb:
      'Robinhood Chain’s testnet is 46630 and its mainnet is 4663. Moving a protocol between them, we found five ways to be pointed at the wrong one; and only the first produced an error. The rest returned an empty array and a green health check.',
  },
];

export default function WritingIndexPage() {
  return (
    <>
      <section className="relative overflow-hidden border-b border-void-700">
        <div className="spotlight absolute inset-0 -z-10" aria-hidden="true" />
        <div className="shell py-16 sm:py-20">
          <span className="badge">Writing</span>
          <h1 className="mt-6 max-w-3xl text-3xl font-semibold leading-tight tracking-tight sm:text-5xl">
            What broke, and what changed because of it
          </h1>
          <p className="lede mt-6 max-w-2xl">
            Engineering notes from building on a chain that reached mainnet two months ago. Written
            for the next team to hit the same thing, so the tuition is paid once.
          </p>
        </div>
      </section>

      <section className="shell py-16">
        <ul className="max-w-[46rem] space-y-5">
          {POSTS.map((post) => (
            <li key={post.href}>
              <Link href={post.href} className="card-pad group block transition-colors hover:border-zor-500/40">
                <span className="font-mono text-2xs uppercase tracking-[0.14em] text-ink-500">
                  {post.date}
                </span>
                <h2 className="mt-3 text-xl font-semibold leading-snug text-ink-100 transition-colors group-hover:text-zor-300">
                  {post.title}
                </h2>
                <p className="mt-3 text-sm leading-relaxed text-ink-400">{post.blurb}</p>
              </Link>
            </li>
          ))}
        </ul>
      </section>
    </>
  );
}

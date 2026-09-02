import Link from 'next/link';
import { Logo } from '@/components/ui/Primitives';

export default function NotFound() {
  return (
    <div className="flex min-h-dvh flex-col items-center justify-center px-5 text-center">
      <Logo className="h-10 w-auto" />
      <p className="mt-8 font-mono text-2xs uppercase tracking-[0.2em] text-ink-500">Error 404</p>
      <h1 className="mt-4 text-3xl font-semibold tracking-tight sm:text-4xl">
        Nothing at this address
      </h1>
      <p className="mt-4 max-w-md text-sm leading-relaxed text-ink-400">
        The page you asked for does not exist. If you followed a link from somewhere on this site,
        that is our mistake rather than yours.
      </p>
      <div className="mt-8 flex flex-wrap justify-center gap-3">
        <Link href="/" className="btn-primary">
          Back to home
        </Link>
        <Link href="/portal" className="btn">
          Open the portal
        </Link>
      </div>
    </div>
  );
}

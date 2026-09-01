'use client';

import dynamic from 'next/dynamic';

/**
 * Client boundary for the bridge.
 *
 * `next/dynamic` with `ssr: false` is only legal inside a client component, and
 * the widget genuinely cannot be server-rendered: it builds its own wagmi
 * config and touches `window` on mount. Keeping the boundary in its own file
 * lets the route stay a server component, so the page keeps real metadata
 * instead of trading it away for one dynamic import.
 */
const BridgeWidget = dynamic(() => import('@/components/tools/BridgeWidget'), {
  ssr: false,
  loading: () => (
    <div
      className="card flex h-[600px] w-full max-w-[420px] animate-pulse items-center justify-center"
      role="status"
      aria-label="Loading the bridge"
    >
      <span className="text-sm text-ink-400">Loading routes...</span>
    </div>
  ),
});

export function BridgePanel() {
  return (
    <div className="mx-auto w-full max-w-[420px] lg:mx-0">
      <BridgeWidget />
    </div>
  );
}

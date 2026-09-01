'use client';

import { useEffect, useRef, useState, type ReactNode } from 'react';
import {
  useAccount,
  useConnect,
  useDisconnect,
  useSwitchChain,
  useBalance,
  type Connector,
} from 'wagmi';
import { activeChain } from '@/lib/chains';
import { walletConnectAvailable } from '@/lib/wagmi';
import { formatAddress, formatUnits } from '@/lib/format';
import { explorerAddress } from '@/lib/contracts';

/**
 * Wallet connection.
 *
 * The previous version registered one connector and hardcoded
 * `connectors[0]`, so the only way in was a desktop browser extension, no
 * mobile wallet could connect at all, and neither could the governance Safe
 * that owns the protocol. This presents every registered connector and reports
 * honestly when one is unavailable.
 */

const LABELS: Record<string, string> = {
  injected: 'Browser wallet',
  metaMaskSDK: 'MetaMask',
  metaMask: 'MetaMask',
  coinbaseWalletSDK: 'Coinbase Wallet',
  coinbaseWallet: 'Coinbase Wallet',
  walletConnect: 'WalletConnect',
  safe: 'Safe',
};

const HINTS: Record<string, string> = {
  injected: 'Rabby, Brave, OKX, Frame, or any extension',
  metaMaskSDK: 'Extension or mobile app',
  metaMask: 'Extension or mobile app',
  coinbaseWalletSDK: 'Extension, mobile, or smart wallet',
  coinbaseWallet: 'Extension, mobile, or smart wallet',
  walletConnect: 'Scan with any mobile wallet',
  safe: 'Only inside the Safe app',
};

function labelFor(connector: Connector): string {
  return LABELS[connector.id] ?? connector.name;
}

function WalletIcon({ connector }: { connector: Connector }) {
  // Connectors expose their own icon in EIP-6963 discovery; fall back to an
  // initial rather than shipping a wall of bundled brand assets.
  const icon = (connector as Connector & { icon?: string }).icon;
  if (icon) {
    // eslint-disable-next-line @next/next/no-img-element
    return <img src={icon} alt="" className="h-6 w-6 rounded-md" aria-hidden="true" />;
  }
  return (
    <span
      className="flex h-6 w-6 items-center justify-center rounded-md border border-void-600 bg-void-800 font-mono text-2xs text-ink-300"
      aria-hidden="true"
    >
      {labelFor(connector).charAt(0)}
    </span>
  );
}

function useDismiss(open: boolean, close: () => void) {
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') close();
    };
    const onClick = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) close();
    };
    document.addEventListener('keydown', onKey);
    document.addEventListener('mousedown', onClick);
    return () => {
      document.removeEventListener('keydown', onKey);
      document.removeEventListener('mousedown', onClick);
    };
  }, [open, close]);
  return ref;
}

function ConnectorList({ onDone }: { onDone: () => void }) {
  const { connectors, connect, isPending, variables, error } = useConnect();
  const [safeAvailable, setSafeAvailable] = useState(false);

  useEffect(() => {
    // The Safe connector only works inside the Safe App iframe. Showing it
    // everywhere would offer a button that silently does nothing.
    setSafeAvailable(typeof window !== 'undefined' && window.parent !== window);
  }, []);

  const visible = connectors.filter((c) => (c.id === 'safe' ? safeAvailable : true));

  return (
    <div className="flex flex-col">
      {visible.map((connector) => {
        const busy = isPending && variables?.connector === connector;
        return (
          <button
            key={connector.uid}
            type="button"
            disabled={isPending}
            onClick={() => connect({ connector }, { onSuccess: onDone })}
            className="flex items-center gap-3 border-b border-void-700 px-4 py-3 text-left transition-colors last:border-b-0 hover:bg-void-800 disabled:opacity-50"
          >
            <WalletIcon connector={connector} />
            <span className="min-w-0 flex-1">
              <span className="block text-sm text-ink-100">{labelFor(connector)}</span>
              <span className="block text-2xs text-ink-500">
                {HINTS[connector.id] ?? 'Connect'}
              </span>
            </span>
            {busy ? <span className="font-mono text-2xs text-zor-300">…</span> : null}
          </button>
        );
      })}

      {!walletConnectAvailable ? (
        <p className="border-t border-void-700 px-4 py-3 text-2xs leading-relaxed text-amber-400/90">
          Mobile wallets are unavailable: no WalletConnect project ID is
          configured for this deployment.
        </p>
      ) : null}

      {error ? (
        <p className="border-t border-void-700 px-4 py-3 text-2xs leading-relaxed text-danger-400">
          {error.message.split('\n')[0]}
        </p>
      ) : null}
    </div>
  );
}

export function WalletButton() {
  const { address, isConnected, chainId, connector } = useAccount();
  const { disconnect } = useDisconnect();
  const { switchChain, isPending: switching } = useSwitchChain();
  const [open, setOpen] = useState(false);
  const ref = useDismiss(open, () => setOpen(false));

  const { data: balance } = useBalance({
    address,
    query: { enabled: isConnected },
  });

  const wrongChain = isConnected && chainId !== activeChain.id;

  if (!isConnected) {
    return (
      <div className="relative" ref={ref}>
        <button
          type="button"
          className="btn-primary btn-sm"
          onClick={() => setOpen((v) => !v)}
          aria-expanded={open}
          aria-haspopup="dialog"
        >
          Connect wallet
        </button>
        {open ? (
          <div
            role="dialog"
            aria-label="Choose a wallet"
            className="absolute right-0 z-50 mt-2 w-72 overflow-hidden rounded-lg border border-void-600 bg-void-850 shadow-panel"
          >
            <div className="border-b border-void-700 px-4 py-2.5">
              <span className="stat-label">Choose a wallet</span>
            </div>
            <ConnectorList onDone={() => setOpen(false)} />
          </div>
        ) : null}
      </div>
    );
  }

  if (wrongChain) {
    return (
      <button
        type="button"
        className="btn-sm btn border-amber-600/50 bg-amber-500/10 text-amber-300 hover:bg-amber-500/20"
        disabled={switching}
        onClick={() => switchChain({ chainId: activeChain.id })}
      >
        {switching ? 'Switching…' : `Switch to ${activeChain.name}`}
      </button>
    );
  }

  return (
    <div className="relative" ref={ref}>
      <button
        type="button"
        className="btn btn-sm font-mono"
        onClick={() => setOpen((v) => !v)}
        aria-expanded={open}
      >
        <span className="h-1.5 w-1.5 rounded-full bg-verified-400" />
        {formatAddress(address)}
      </button>

      {open ? (
        <div className="absolute right-0 z-50 mt-2 w-72 overflow-hidden rounded-lg border border-void-600 bg-void-850 shadow-panel">
          <div className="border-b border-void-700 px-4 py-3">
            <div className="stat-label">Connected</div>
            <div className="mt-1 font-mono text-xs text-ink-200">{formatAddress(address, 8, 6)}</div>
            <div className="mt-2 flex items-baseline justify-between text-2xs">
              <span className="text-ink-500">{connector?.name ?? 'Wallet'}</span>
              <span className="font-mono text-ink-300">
                {balance ? `${formatUnits(balance.value, balance.decimals, 4)} ${balance.symbol}` : '—'}
              </span>
            </div>
            <div className="mt-1 text-2xs text-ink-500">{activeChain.name}</div>
          </div>

          <a
            href={address ? explorerAddress(address) : '#'}
            target="_blank"
            rel="noreferrer noopener"
            className="block border-b border-void-700 px-4 py-2.5 text-sm text-ink-300 hover:bg-void-800 hover:text-ink-100"
          >
            View on explorer ↗
          </a>
          <button
            type="button"
            className="w-full px-4 py-2.5 text-left text-sm text-ink-300 hover:bg-void-800 hover:text-ink-100"
            onClick={() => {
              disconnect();
              setOpen(false);
            }}
          >
            Disconnect
          </button>
        </div>
      ) : null}
    </div>
  );
}

/** Wraps wallet-gated content with a consistent connect prompt. */
export function RequireWallet({
  children,
  message = 'Connect a wallet to continue.',
}: {
  children: ReactNode;
  message?: string;
}) {
  const { isConnected, chainId } = useAccount();
  const { switchChain } = useSwitchChain();
  const [open, setOpen] = useState(false);
  const ref = useDismiss(open, () => setOpen(false));

  if (!isConnected) {
    return (
      <div className="card flex flex-col items-center gap-4 px-6 py-14 text-center">
        <p className="max-w-sm text-sm leading-relaxed text-ink-400">{message}</p>
        <div className="relative w-full max-w-xs" ref={ref}>
          <button type="button" className="btn-primary w-full" onClick={() => setOpen((v) => !v)}>
            Connect wallet
          </button>
          {open ? (
            <div className="mt-2 overflow-hidden rounded-lg border border-void-600 bg-void-850 text-left shadow-panel">
              <ConnectorList onDone={() => setOpen(false)} />
            </div>
          ) : null}
        </div>
      </div>
    );
  }

  if (chainId !== activeChain.id) {
    return (
      <div className="card flex flex-col items-center gap-4 px-6 py-14 text-center">
        <p className="max-w-sm text-sm leading-relaxed text-ink-400">
          Your wallet is on a different network. Zorpha is deployed on {activeChain.name}.
        </p>
        <button
          type="button"
          className="btn-primary"
          onClick={() => switchChain({ chainId: activeChain.id })}
        >
          Switch network
        </button>
      </div>
    );
  }

  return <>{children}</>;
}

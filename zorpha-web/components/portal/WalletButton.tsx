'use client';

import { useAccount, useConnect, useDisconnect, useSwitchChain } from 'wagmi';
import { useState } from 'react';
import { activeChain } from '@/lib/chains';
import { formatAddress } from '@/lib/format';

export function WalletButton() {
  const { address, isConnected, chainId } = useAccount();
  const { connectors, connect, isPending } = useConnect();
  const { disconnect } = useDisconnect();
  const { switchChain, isPending: switching } = useSwitchChain();
  const [open, setOpen] = useState(false);

  const injectedConnector = connectors[0];
  const wrongChain = isConnected && chainId !== activeChain.id;

  if (!isConnected) {
    return (
      <button
        type="button"
        className="btn-primary btn-sm"
        disabled={isPending || !injectedConnector}
        onClick={() => injectedConnector && connect({ connector: injectedConnector })}
      >
        {isPending ? 'Connecting…' : 'Connect wallet'}
      </button>
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
    <div className="relative">
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
        <div className="absolute right-0 z-50 mt-2 w-48 overflow-hidden rounded-lg border border-void-600 bg-void-850 shadow-panel">
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
  children: React.ReactNode;
  message?: string;
}) {
  const { isConnected, chainId } = useAccount();
  const { connectors, connect, isPending } = useConnect();
  const { switchChain } = useSwitchChain();

  if (!isConnected) {
    return (
      <div className="card flex flex-col items-center gap-4 px-6 py-14 text-center">
        <p className="max-w-sm text-sm leading-relaxed text-ink-400">{message}</p>
        <button
          type="button"
          className="btn-primary"
          disabled={isPending || !connectors[0]}
          onClick={() => connectors[0] && connect({ connector: connectors[0] })}
        >
          {isPending ? 'Connecting…' : 'Connect wallet'}
        </button>
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

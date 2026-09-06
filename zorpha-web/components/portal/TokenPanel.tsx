'use client';

import { useEffect } from 'react';
import { useAccount, useReadContract, useWriteContract, useWaitForTransactionReceipt } from 'wagmi';
import { contracts, zorAbi, isDeployed, explorerAddress } from '@/lib/contracts';
import { formatUnits, formatCompactUnits, formatAddress } from '@/lib/format';
import { TOKEN } from '@/lib/tokenomics';
import { ZERO_ADDRESS } from '@/lib/contracts';

export function TokenPanel() {
  const { address } = useAccount();
  const deployed = isDeployed('zor');
  const enabled = deployed && Boolean(address);

  const { data: balance } = useReadContract({
    abi: zorAbi,
    address: contracts.zor,
    functionName: 'balanceOf',
    args: address ? [address] : undefined,
    query: { enabled },
  });

  const { data: totalSupply } = useReadContract({
    abi: zorAbi,
    address: contracts.zor,
    functionName: 'totalSupply',
    query: { enabled: deployed },
  });

  const { data: maxSupply } = useReadContract({
    abi: zorAbi,
    address: contracts.zor,
    functionName: 'MAX_SUPPLY',
    query: { enabled: deployed },
  });

  const { data: votes } = useReadContract({
    abi: zorAbi,
    address: contracts.zor,
    functionName: 'getVotes',
    args: address ? [address] : undefined,
    query: { enabled },
  });

  const { data: delegatee, refetch: refetchDelegate } = useReadContract({
    abi: zorAbi,
    address: contracts.zor,
    functionName: 'delegates',
    args: address ? [address] : undefined,
    query: { enabled },
  });

  const { writeContract, data: txHash, isPending, error } = useWriteContract();
  const { isLoading: confirming, isSuccess } = useWaitForTransactionReceipt({ hash: txHash });

  // In an effect, not in the render body.
  //
  // This was `if (isSuccess) void refetchDelegate();` inline, which refetches
  // during render: the refetch resolves, the component re-renders, isSuccess is
  // still true, and it refetches again, forever. The visible symptom was the
  // button sticking on "Activating…" after a delegate transaction had already
  // confirmed on chain, because the component never settled long enough to read
  // the new delegatee back.
  useEffect(() => {
    if (isSuccess) void refetchDelegate();
  }, [isSuccess, refetchDelegate]);

  const hasDelegated = delegatee && delegatee !== ZERO_ADDRESS;
  const burned =
    totalSupply !== undefined && maxSupply !== undefined
      ? (maxSupply as bigint) - (totalSupply as bigint)
      : undefined;

  if (!deployed) {
    return (
      <div className="card-pad">
        <div className="stat-label">{TOKEN.ticker} balance</div>
        <p className="mt-3 text-sm text-ink-400">
          The token address is not configured in this environment.
        </p>
      </div>
    );
  }

  return (
    <div className="card-pad">
      <div className="flex items-start justify-between gap-4">
        <div>
          <div className="stat-label">Your {TOKEN.ticker}</div>
          <div className="stat-value mt-2">
            {address ? formatUnits(balance as bigint | undefined, 18, 2) : ', '}
          </div>
        </div>
        <a
          href={explorerAddress(contracts.zor)}
          target="_blank"
          rel="noreferrer noopener"
          className="badge font-mono hover:border-zor-600/70"
        >
          {formatAddress(contracts.zor)} ↗
        </a>
      </div>

      <dl className="mt-6 grid grid-cols-2 gap-4 border-t border-void-700 pt-5">
        <div>
          <dt className="stat-label">Circulating supply</dt>
          <dd className="mt-1.5 font-mono text-sm text-ink-200">
            {formatCompactUnits(totalSupply as bigint | undefined)}
          </dd>
        </div>
        <div>
          <dt className="stat-label">Burned to date</dt>
          <dd className="mt-1.5 font-mono text-sm text-verified-400">
            {formatCompactUnits(burned)}
          </dd>
        </div>
      </dl>

      {/* Voting weight. ERC20Votes requires an explicit self-delegation, which
          is the single most common reason a holder thinks governance is broken. */}
      <div className="mt-6 border-t border-void-700 pt-5">
        <div className="flex items-baseline justify-between gap-4">
          <div className="stat-label">Voting weight</div>
          <div className="font-mono text-sm text-ink-200">
            {formatUnits(votes as bigint | undefined, 18, 2)}
          </div>
        </div>

        {address && !hasDelegated ? (
          <>
            <p className="mt-3 text-xs leading-relaxed text-ink-400">
              Your balance carries no voting weight until you delegate it. Delegating to yourself
              activates it and costs one transaction.
            </p>
            <button
              type="button"
              className="btn-primary btn-sm mt-3"
              disabled={isPending || confirming}
              onClick={() =>
                writeContract({
                  abi: zorAbi,
                  address: contracts.zor,
                  functionName: 'delegate',
                  args: [address],
                })
              }
            >
              {isPending ? 'Confirm in wallet…' : confirming ? 'Activating…' : 'Activate my votes'}
            </button>
          </>
        ) : null}

        {address && hasDelegated ? (
          <p className="mt-3 text-xs text-ink-500">
            Delegated to{' '}
            <span className="font-mono text-ink-300">
              {delegatee === address ? 'yourself' : formatAddress(delegatee as string)}
            </span>
          </p>
        ) : null}

        {error ? (
          <p className="mt-3 text-xs leading-relaxed text-danger-400">
            {error.message.split('\n')[0]}
          </p>
        ) : null}
      </div>
    </div>
  );
}

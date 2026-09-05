'use client';

import { useEffect, useState } from 'react';
import {
  useAccount,
  useReadContract,
  useWriteContract,
  useWaitForTransactionReceipt,
} from 'wagmi';
import {
  contracts,
  merkleDistributorAbi,
  isDeployed,
  explorerTx,
} from '@/lib/contracts';
import { formatUnits, formatDateTime, formatRelative } from '@/lib/format';
import { TOKEN } from '@/lib/tokenomics';
import { Callout } from '@/components/ui/Primitives';

type Allocation = {
  index: number;
  amount: string;
  proof: `0x${string}`[];
};

type LookupState =
  | { status: 'idle' }
  | { status: 'loading' }
  | { status: 'eligible'; allocation: Allocation }
  | { status: 'not-eligible' }
  | { status: 'error'; message: string };

export function AirdropClaim() {
  const { address } = useAccount();
  const deployed = isDeployed('merkleDistributor');
  const [lookup, setLookup] = useState<LookupState>({ status: 'idle' });

  // Fetch the caller's Merkle proof. Proofs are public data, they only let the
  // committed recipient claim their committed amount, so serving them from a
  // plain endpoint is safe.
  useEffect(() => {
    if (!address) {
      setLookup({ status: 'idle' });
      return;
    }
    let cancelled = false;
    setLookup({ status: 'loading' });

    fetch(`/api/airdrop/${address}`)
      .then(async (res) => {
        if (cancelled) return;
        if (res.status === 404) {
          setLookup({ status: 'not-eligible' });
          return;
        }
        if (!res.ok) {
          setLookup({ status: 'error', message: `Lookup failed (${res.status})` });
          return;
        }
        const json = (await res.json()) as Allocation;
        if (
          typeof json?.index !== 'number' ||
          typeof json?.amount !== 'string' ||
          !Array.isArray(json?.proof)
        ) {
          setLookup({ status: 'error', message: 'Malformed allocation record' });
          return;
        }
        setLookup({ status: 'eligible', allocation: json });
      })
      .catch(() => {
        if (!cancelled) setLookup({ status: 'error', message: 'Could not reach the allocation service' });
      });

    return () => {
      cancelled = true;
    };
  }, [address]);

  const allocation = lookup.status === 'eligible' ? lookup.allocation : undefined;

  const { data: claimed, refetch: refetchClaimed } = useReadContract({
    abi: merkleDistributorAbi,
    address: contracts.merkleDistributor,
    functionName: 'isClaimed',
    args: allocation ? [BigInt(allocation.index)] : undefined,
    query: { enabled: deployed && Boolean(allocation) },
  });

  const { data: deadline } = useReadContract({
    abi: merkleDistributorAbi,
    address: contracts.merkleDistributor,
    functionName: 'claimDeadline',
    query: { enabled: deployed },
  });

  const { writeContract, data: txHash, isPending, error } = useWriteContract();
  const { isLoading: confirming, isSuccess } = useWaitForTransactionReceipt({ hash: txHash });

  useEffect(() => {
    if (isSuccess) void refetchClaimed();
  }, [isSuccess, refetchClaimed]);

  const deadlineMs = deadline !== undefined ? Number(deadline as bigint) * 1000 : undefined;
  const windowClosed = deadlineMs !== undefined && deadlineMs < Date.now();

  if (!deployed) {
    return (
      <Callout tone="warn" title="Airdrop not live yet">
        <p>
          The distributor contract is not deployed in this environment, so there is nothing to
          claim against. The Season 1 snapshot and Merkle root are published before claims open.
        </p>
      </Callout>
    );
  }

  return (
    <div className="flex flex-col gap-5">
      <div className="card-pad">
        <div className="flex flex-wrap items-baseline justify-between gap-3">
          <div>
            <div className="stat-label">Season 1 allocation</div>
            <div className="stat-value mt-2">
              {allocation ? formatUnits(allocation.amount, 18, 2) : '—'}
              {allocation ? (
                <span className="ml-2 font-sans text-sm text-ink-500">{TOKEN.ticker}</span>
              ) : null}
            </div>
          </div>
          {claimed === true ? <span className="badge-verified">Claimed</span> : null}
          {claimed === false ? <span className="badge-zor">Unclaimed</span> : null}
        </div>

        <div className="mt-5 border-t border-void-700 pt-5">
          {lookup.status === 'idle' ? (
            <p className="text-sm text-ink-400">
              Connect your wallet to check whether it is included in the Season 1 snapshot.
            </p>
          ) : null}

          {lookup.status === 'loading' ? (
            <p className="text-sm text-ink-400">Checking the snapshot…</p>
          ) : null}

          {lookup.status === 'not-eligible' ? (
            <p className="text-sm leading-relaxed text-ink-400">
              No wallet has a Season 1 allocation yet. The tranche is funded on-chain and held by
              governance until the snapshot criteria are published and voted; this page will resolve
              real allocations once they are. There is no form to fill in and no way to register.
            </p>
          ) : null}

          {lookup.status === 'error' ? (
            <p className="text-sm text-danger-400">{lookup.message}</p>
          ) : null}

          {allocation ? (
            <div className="flex flex-col gap-4">
              <dl className="grid grid-cols-2 gap-4">
                <div>
                  <dt className="stat-label">Claim index</dt>
                  <dd className="mt-1.5 font-mono text-sm text-ink-200">{allocation.index}</dd>
                </div>
                <div>
                  <dt className="stat-label">Claim window closes</dt>
                  <dd className="mt-1.5 font-mono text-sm text-ink-200">
                    {deadlineMs ? formatRelative(deadlineMs) : '—'}
                  </dd>
                </div>
              </dl>

              <button
                type="button"
                className="btn-primary self-start"
                disabled={
                  isPending || confirming || claimed === true || windowClosed || !address
                }
                onClick={() =>
                  writeContract({
                    abi: merkleDistributorAbi,
                    address: contracts.merkleDistributor,
                    functionName: 'claim',
                    args: [
                      BigInt(allocation.index),
                      address as `0x${string}`,
                      BigInt(allocation.amount),
                      allocation.proof,
                    ],
                  })
                }
              >
                {claimed === true
                  ? 'Already claimed'
                  : windowClosed
                    ? 'Claim window closed'
                    : isPending
                      ? 'Confirm in wallet…'
                      : confirming
                        ? 'Claiming…'
                        : `Claim ${formatUnits(allocation.amount, 18, 2)} ${TOKEN.ticker}`}
              </button>

              {error ? (
                <p className="text-xs leading-relaxed text-danger-400">
                  {error.message.split('\n')[0]}
                </p>
              ) : null}

              {txHash ? (
                <a
                  href={explorerTx(txHash)}
                  target="_blank"
                  rel="noreferrer noopener"
                  className="link-quiet text-xs"
                >
                  View transaction ↗
                </a>
              ) : null}
            </div>
          ) : null}
        </div>
      </div>

      <div className="card-pad">
        <h3 className="text-sm font-semibold text-ink-100">How the claim works</h3>
        <ul className="mt-3 space-y-2.5 text-xs leading-relaxed text-ink-400">
          <li>
            Your wallet, your index and your amount are committed together into one Merkle leaf.
            Changing any of the three invalidates the proof, so nobody can claim a different
            amount than the snapshot recorded.
          </li>
          <li>
            Anyone can submit your proof, but the tokens always go to the committed address. There
            is nothing for a front-runner to steal.
          </li>
          <li>
            Unclaimed tokens can only be swept after{' '}
            {deadlineMs ? formatDateTime(deadlineMs) : 'the published deadline'}, and only by the
            governance Timelock.
          </li>
        </ul>
      </div>
    </div>
  );
}

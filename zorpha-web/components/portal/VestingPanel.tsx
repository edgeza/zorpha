'use client';

import { useEffect } from 'react';
import {
  useAccount,
  useReadContract,
  useWriteContract,
  useWaitForTransactionReceipt,
} from 'wagmi';
import { contracts, vestingAbi, isDeployed, explorerTx } from '@/lib/contracts';
import { formatUnits, formatDate, formatRelative } from '@/lib/format';
import { TOKEN } from '@/lib/tokenomics';
import { Callout, EmptyState } from '@/components/ui/Primitives';

type Schedule = {
  totalAmount: bigint;
  claimed: bigint;
  startTime: bigint;
  cliffDuration: bigint;
  vestDuration: bigint;
  revocable: boolean;
  revoked: boolean;
};

export function VestingPanel() {
  const { address } = useAccount();
  const deployed = isDeployed('vesting');
  const enabled = deployed && Boolean(address);

  const { data: schedule } = useReadContract({
    abi: vestingAbi,
    address: contracts.vesting,
    functionName: 'scheduleOf',
    args: address ? [address] : undefined,
    query: { enabled },
  });

  const { data: claimable, refetch: refetchClaimable } = useReadContract({
    abi: vestingAbi,
    address: contracts.vesting,
    functionName: 'claimable',
    args: address ? [address] : undefined,
    query: { enabled },
  });

  const { data: vestedTotal, refetch: refetchVested } = useReadContract({
    abi: vestingAbi,
    address: contracts.vesting,
    functionName: 'vestedTotal',
    args: address ? [address] : undefined,
    query: { enabled },
  });

  const { writeContract, data: txHash, isPending, error } = useWriteContract();
  const { isLoading: confirming, isSuccess } = useWaitForTransactionReceipt({ hash: txHash });

  useEffect(() => {
    if (isSuccess) {
      void refetchClaimable();
      void refetchVested();
    }
  }, [isSuccess, refetchClaimable, refetchVested]);

  if (!deployed) {
    return (
      <Callout tone="warn" title="Vesting not live yet">
        <p>
          The vesting contract address is not configured in this environment. Contributor and
          backer schedules are created by the governance Safe after deployment, not by the deploy
          script, beneficiary addresses do not belong in a committed config file.
        </p>
      </Callout>
    );
  }

  const s = schedule as Schedule | undefined;
  const hasSchedule = s !== undefined && s.totalAmount > 0n;

  if (address && s !== undefined && !hasSchedule) {
    return (
      <EmptyState
        title="No vesting schedule for this wallet"
        body="This address has no contributor or backer allocation. If you expected one, check that you are connected with the address you gave to the team."
      />
    );
  }

  const startMs = s ? Number(s.startTime) * 1000 : undefined;
  const cliffMs = s ? (Number(s.startTime) + Number(s.cliffDuration)) * 1000 : undefined;
  const endMs = s ? (Number(s.startTime) + Number(s.vestDuration)) * 1000 : undefined;

  const total = s?.totalAmount ?? 0n;
  const vested = (vestedTotal as bigint | undefined) ?? 0n;
  const pctVested = total > 0n ? Number((vested * 10_000n) / total) / 100 : 0;
  const preCliff = cliffMs !== undefined && Date.now() < cliffMs;

  return (
    <div className="flex flex-col gap-5">
      <div className="card-pad">
        <div className="flex flex-wrap items-start justify-between gap-4">
          <div>
            <div className="stat-label">Claimable now</div>
            <div className="stat-value mt-2 text-verified-400">
              {formatUnits(claimable as bigint | undefined, 18, 2)}
              <span className="ml-2 font-sans text-sm text-ink-500">{TOKEN.ticker}</span>
            </div>
          </div>
          {s?.revoked ? <span className="badge-danger">Revoked</span> : null}
          {preCliff ? <span className="badge-warn">Pre-cliff</span> : null}
        </div>

        {/* Vesting progress */}
        <div className="mt-6">
          <div className="flex items-baseline justify-between text-2xs text-ink-500">
            <span>{pctVested.toFixed(1)}% vested</span>
            <span>
              {formatUnits(vested, 18, 0)} / {formatUnits(total, 18, 0)}
            </span>
          </div>
          <div className="mt-2 h-1.5 overflow-hidden rounded-full bg-void-700">
            <div
              className="h-full rounded-full bg-zor-sheen transition-[width] duration-500"
              style={{ width: `${Math.min(100, Math.max(0, pctVested))}%` }}
            />
          </div>
        </div>

        <button
          type="button"
          className="btn-primary mt-6"
          disabled={
            isPending ||
            confirming ||
            !address ||
            claimable === undefined ||
            (claimable as bigint) === 0n
          }
          onClick={() =>
            writeContract({
              abi: vestingAbi,
              address: contracts.vesting,
              functionName: 'claim',
            })
          }
        >
          {isPending
            ? 'Confirm in wallet…'
            : confirming
              ? 'Claiming…'
              : claimable !== undefined && (claimable as bigint) > 0n
                ? `Claim ${formatUnits(claimable as bigint, 18, 2)} ${TOKEN.ticker}`
                : 'Nothing claimable yet'}
        </button>

        {error ? (
          <p className="mt-3 text-xs leading-relaxed text-danger-400">
            {error.message.split('\n')[0]}
          </p>
        ) : null}

        {txHash ? (
          <a
            href={explorerTx(txHash)}
            target="_blank"
            rel="noreferrer noopener"
            className="link-quiet mt-3 inline-block text-xs"
          >
            View transaction ↗
          </a>
        ) : null}
      </div>

      {hasSchedule ? (
        <div className="card-pad">
          <h3 className="text-sm font-semibold text-ink-100">Your schedule</h3>
          <dl className="mt-4 grid grid-cols-2 gap-5 sm:grid-cols-4">
            <div>
              <dt className="stat-label">Total granted</dt>
              <dd className="mt-1.5 font-mono text-sm text-ink-200">
                {formatUnits(total, 18, 0)}
              </dd>
            </div>
            <div>
              <dt className="stat-label">Already claimed</dt>
              <dd className="mt-1.5 font-mono text-sm text-ink-200">
                {formatUnits(s!.claimed, 18, 0)}
              </dd>
            </div>
            <div>
              <dt className="stat-label">Cliff</dt>
              <dd className="mt-1.5 font-mono text-sm text-ink-200">
                {cliffMs ? formatDate(cliffMs) : '—'}
              </dd>
            </div>
            <div>
              <dt className="stat-label">Fully vested</dt>
              <dd className="mt-1.5 font-mono text-sm text-ink-200">
                {endMs ? formatDate(endMs) : '—'}
              </dd>
            </div>
          </dl>

          <p className="mt-5 border-t border-void-700 pt-4 text-xs leading-relaxed text-ink-500">
            Vesting runs linearly from {startMs ? formatDate(startMs) : 'the start date'} over the
            full term, the cliff gates the first release rather than extending the end date. At
            the cliff, everything accrued up to that point unlocks at once
            {cliffMs && !preCliff ? '' : `, ${cliffMs ? formatRelative(cliffMs) : 'soon'}`}.
          </p>
          <p className="mt-2 text-xs leading-relaxed text-ink-500">
            Unvested tokens sit in the vesting contract and carry no voting weight. You gain
            governance weight as you claim.
          </p>
        </div>
      ) : null}
    </div>
  );
}

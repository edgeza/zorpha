'use client';

import { useEffect, useState } from 'react';
import { formatUnits, isAddress } from 'viem';
import type { Address } from 'viem';
import { useReadContracts, useWriteContract, useWaitForTransactionReceipt } from 'wagmi';
import { activeChain } from '@/lib/chains';
import { contracts, explorerTx } from '@/lib/contracts';
import { launcherManagerAbi } from '@/lib/manager-abi';
import { Callout, Mono } from '@/components/ui/Primitives';

const ZERO = '0x0000000000000000000000000000000000000000' as const;

/**
 * The two things a leader may do to a vault they launched.
 *
 * This panel is the answer to the question the roles panel raises. Told that
 * launching a vault grants no role on it, the obvious next question is "then
 * what CAN I do", and until this existed the honest answer was "run Foundry".
 *
 * `reallocate` is NOT timelocked for a leader, unlike `setAdapter` on the
 * factory vaults. The launcher keeps ADAPTER_SETTER_ROLE on every vault it
 * creates and calls through on the leader's instruction, so a venue change
 * lands in one transaction. The protections are different in kind: the target
 * must already be on governance's allowlist, and its asset must match the
 * vault's, so the leader chooses only among venues governance has vetted.
 */
export function LeaderActions({
  launchId,
  vaultTotalSupply,
  currentTarget,
}: {
  launchId: bigint;
  vaultTotalSupply: bigint | undefined;
  currentTarget: Address | undefined;
}) {
  const launcher = contracts.vaultLauncher as Address;
  const [target, setTarget] = useState('');

  const trimmed = target.trim();
  const targetValid = isAddress(trimmed);

  // Two hooks rather than one array with a conditional entry: a spread that is
  // empty on some renders collapses wagmi's inferred element type to `never`,
  // and every entry then fails to typecheck.
  const { data, refetch } = useReadContracts({
    allowFailure: true,
    contracts: [
      {
        address: launcher,
        abi: launcherManagerAbi,
        functionName: 'launches' as const,
        args: [launchId - 1n], // the array is 0-indexed; launch ids are 1-indexed
        chainId: activeChain.id,
      },
    ],
    query: { refetchInterval: 20_000 },
  });

  const { data: approval } = useReadContracts({
    allowFailure: true,
    contracts: [
      {
        address: launcher,
        abi: launcherManagerAbi,
        functionName: 'approvedTarget' as const,
        args: [(targetValid ? trimmed : ZERO) as Address],
        chainId: activeChain.id,
      },
    ],
    query: { enabled: targetValid },
  });

  const launch = data?.[0]?.status === 'success' ? (data[0].result as readonly unknown[]) : undefined;
  const bond = launch ? (launch[5] as bigint) : undefined;
  const bondReleased = launch ? (launch[7] as boolean) : undefined;
  const bondSlashed = launch ? (launch[8] as boolean) : undefined;
  const approved =
    targetValid && approval?.[0]?.status === 'success' ? (approval[0].result as boolean) : undefined;

  const { writeContract, data: hash, isPending, error, reset } = useWriteContract();
  const { isLoading: confirming, isSuccess } = useWaitForTransactionReceipt({ hash });
  useEffect(() => {
    if (isSuccess) void refetch();
  }, [isSuccess, refetch]);
  const busy = isPending || confirming;

  const bondResolved = bondReleased === true || bondSlashed === true;
  const vaultEmpty = vaultTotalSupply !== undefined && vaultTotalSupply === 0n;
  const sameTarget =
    targetValid && currentTarget ? trimmed.toLowerCase() === currentTarget.toLowerCase() : false;

  return (
    <section className="card p-5">
      <h2 className="mb-1 font-semibold tracking-tight">Your powers as this vault&rsquo;s leader</h2>
      <p className="mb-4 max-w-prose text-sm leading-relaxed text-ink-400">
        Two functions, both gated on your address being the recorded leader. Neither can move a
        depositor&rsquo;s money anywhere governance has not already approved.
      </p>

      {error && (
        <Callout tone="danger" title="The transaction was rejected">
          <p className="break-words">{error.message.split('\n')[0]}</p>
        </Callout>
      )}
      {isSuccess && hash && (
        <Callout tone="verified" title="Done">
          <p>
            <a href={explorerTx(hash)} target="_blank" rel="noreferrer">
              View the transaction
            </a>
            .
          </p>
        </Callout>
      )}

      {/* Reallocate */}
      <div className="mt-4 flex flex-col gap-3 border-t border-void-800 pt-4">
        <div>
          <h3 className="text-sm font-semibold">Move to another venue</h3>
          <p className="mt-1 max-w-prose text-sm leading-relaxed text-ink-400">
            Deploys a fresh adapter and repoints the vault. The venue must be on
            governance&rsquo;s allowlist and hold the same asset as your vault, or the call
            reverts with <Mono>TargetNotApproved</Mono> or <Mono>AssetMismatch</Mono>.
          </p>
        </div>

        <div className="flex flex-wrap items-center gap-3">
          <input
            type="text"
            value={target}
            onChange={(e) => setTarget(e.target.value)}
            placeholder="0x… ERC-4626 venue address"
            spellCheck={false}
            className="input min-w-0 flex-1 font-mono text-sm"
            aria-label="New venue address"
          />
          <button
            type="button"
            className="btn-primary shrink-0"
            disabled={!targetValid || approved !== true || sameTarget || busy}
            onClick={() => {
              reset();
              writeContract({
                abi: launcherManagerAbi,
                address: launcher,
                functionName: 'reallocate',
                args: [launchId, trimmed as Address],
              });
            }}
          >
            {busy ? 'Confirming…' : 'Reallocate'}
          </button>
        </div>

        {trimmed.length > 0 && !targetValid && (
          <p className="text-sm text-ink-400">That is not a valid address.</p>
        )}
        {targetValid && approved === false && (
          <p className="text-sm text-ink-400">
            Not on the allowlist. Governance approves venues with{' '}
            <Mono>setTargetApproved</Mono>; this call would revert.
          </p>
        )}
        {targetValid && approved === true && !sameTarget && (
          <p className="text-sm text-ink-400">Approved. This venue is available to you.</p>
        )}
        {sameTarget && (
          <p className="text-sm text-ink-400">
            That is the venue the vault already uses.
          </p>
        )}
      </div>

      {/* Reclaim bond */}
      <div className="mt-5 flex flex-col gap-3 border-t border-void-800 pt-4">
        <div>
          <h3 className="text-sm font-semibold">Reclaim your bond</h3>
          <p className="mt-1 max-w-prose text-sm leading-relaxed text-ink-400">
            Only once the vault holds no depositor shares at all. While anyone is still in, the
            bond stays posted — that is what it is for.
          </p>
        </div>

        <dl className="grid grid-cols-2 gap-x-6 gap-y-2 text-sm sm:grid-cols-3">
          <div>
            <dt className="stat-label">Bond</dt>
            <dd className="mt-0.5 font-mono tabular-nums">
              {bond === undefined
                ? '—'
                : `${Number(formatUnits(bond, 18)).toLocaleString('en-US')} ZOR`}
            </dd>
          </div>
          <div>
            <dt className="stat-label">Shares outstanding</dt>
            <dd className="mt-0.5 font-mono tabular-nums">
              {vaultTotalSupply === undefined
                ? '—'
                : Number(formatUnits(vaultTotalSupply, 18)).toLocaleString('en-US', {
                    maximumFractionDigits: 4,
                  })}
            </dd>
          </div>
          <div>
            <dt className="stat-label">Status</dt>
            <dd className="mt-0.5 font-mono tabular-nums">
              {bondSlashed ? 'Slashed' : bondReleased ? 'Returned' : 'Posted'}
            </dd>
          </div>
        </dl>

        {bondSlashed && (
          <Callout tone="warn" title="This bond was slashed">
            <p>Governance forfeited it to the treasury. There is nothing to reclaim.</p>
          </Callout>
        )}

        <button
          type="button"
          className="btn btn-quiet self-start"
          disabled={bondResolved || !vaultEmpty || busy}
          title={
            bondResolved
              ? 'Already resolved'
              : vaultEmpty
                ? undefined
                : 'The vault still has depositors'
          }
          onClick={() => {
            reset();
            writeContract({
              abi: launcherManagerAbi,
              address: launcher,
              functionName: 'reclaimBond',
              args: [launchId],
            });
          }}
        >
          {busy ? 'Confirming…' : 'Reclaim bond'}
        </button>
      </div>
    </section>
  );
}

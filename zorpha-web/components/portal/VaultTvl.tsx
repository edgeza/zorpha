'use client';

import { useReadContracts } from 'wagmi';
import { erc20Abi, vaultAbi } from '@/lib/contracts';
import { formatUnits } from '@/lib/format';

/**
 * How much is actually in a vault, read from the vault.
 *
 * This page quoted a yield, a fee, a mandate and a manager, and never said how
 * large the vault was -- which is the first thing anyone deciding whether to
 * deposit wants to know, and the one number that cannot be inferred from the
 * others. A rate with no size behind it is not enough information to act on.
 *
 * `totalAssets` is read rather than derived from the indexer on purpose. The
 * indexer follows Rebalanced events, and a vault that has taken deposits but
 * never been rebalanced has no rows at all -- which is exactly this vault's
 * state today. Reading the contract is the only source that is right in both
 * cases.
 *
 * Zero is rendered as a sentence rather than as "0.000000", because a bare
 * zero next to a live yield reads as a failed load. Saying nothing has been
 * deposited is both true and unambiguous.
 */
export function VaultTvl({
  vaultAddress,
  assetAddress,
}: {
  vaultAddress: `0x${string}`;
  assetAddress: `0x${string}`;
}) {
  const reads = useReadContracts({
    contracts: [
      { abi: vaultAbi, address: vaultAddress, functionName: 'totalAssets' },
      { abi: erc20Abi, address: assetAddress, functionName: 'decimals' },
      { abi: erc20Abi, address: assetAddress, functionName: 'symbol' },
    ],
    // The venue accrues continuously, so this figure drifts upward between
    // deposits. Matching VaultApy's cadence keeps the two numbers on the card
    // from disagreeing about which block they were read at.
    query: { refetchInterval: 15_000 },
  });

  const [assetsRead, decimalsRead, symbolRead] = reads.data ?? [];
  const ready =
    assetsRead?.status === 'success' &&
    decimalsRead?.status === 'success' &&
    symbolRead?.status === 'success';

  return (
    <div className="card-pad">
      <div className="stat-label">Total deposited</div>

      {reads.isLoading ? (
        <div
          className="mt-2 h-8 w-32 animate-pulse rounded bg-void-700"
          role="status"
          aria-label="Reading vault balance"
        />
      ) : null}

      {!reads.isLoading && !ready ? (
        <>
          <div className="stat-value mt-2 text-ink-500">&mdash;</div>
          <p className="mt-2 text-xs leading-relaxed text-ink-400">
            The vault did not answer this read. Nothing is being withheld; the figure is
            unavailable rather than zero, and those are different things.
          </p>
        </>
      ) : null}

      {ready ? (
        (assetsRead.result as bigint) === 0n ? (
          <>
            <div className="stat-value mt-2 text-ink-500">&mdash;</div>
            <p className="mt-2 text-xs leading-relaxed text-ink-400">
              Nothing has been deposited yet. This is the vault&rsquo;s true state, read from the
              contract, not a figure that failed to load.
            </p>
          </>
        ) : (
          <>
            <div className="stat-value mt-2">
              {formatUnits(assetsRead.result as bigint, decimalsRead.result as number, 6)}{' '}
              <span className="text-base font-normal text-ink-400">
                {symbolRead.result as string}
              </span>
            </div>
            <p className="mt-2 text-xs leading-relaxed text-ink-400">
              Read from the vault&rsquo;s own <code className="font-mono">totalAssets</code>,
              which includes interest accrued at the venue since the last deposit.
            </p>
          </>
        )
      ) : null}
    </div>
  );
}

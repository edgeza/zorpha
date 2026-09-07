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
 * never been rebalanced has no rows at all, which is exactly this vault's
 * state today. Reading the contract is the only source that is right in both
 * cases.
 *
 * WHY THE ASSET IS READ FROM THE CHAIN AND NOT PASSED IN
 *
 * It used to take an `assetAddress` prop, which the vault page filled from the
 * database as `vault.base_asset ?? vault.cash ?? vault.asset`. For the NVDA
 * spot vault that resolves to USDG, and USDG is not what `totalAssets` is
 * denominated in.
 *
 * ERC-4626 reports `totalAssets` in `asset()` units, always. That vault's
 * asset is tokenised NVDA at 18 decimals, so formatting it with USDG's 6
 * turned 0.055410 NVDA, about thirteen dollars, into "55,410,159,670 USDG" on
 * a live page: the wrong unit and a factor of 10^12, overstating the vault by
 * four billion times. It read as an obvious fabrication, which is worse than
 * useless on a page whose only job is to be checkable against the chain.
 *
 * components/portal/terminal/VaultBook.tsx had already written down the rule
 * that every vault kind reports in `asset()` units. The fix is not to pass a
 * better address, it is to stop passing one: the vault knows what it holds,
 * and any argument the caller supplies is a second source that can disagree
 * with the first.
 *
 * Zero is rendered as a sentence rather than as "0.000000", because a bare
 * zero next to a live yield reads as a failed load. Saying nothing has been
 * deposited is both true and unambiguous.
 */
export function VaultTvl({ vaultAddress }: { vaultAddress: `0x${string}` }) {
  // The venue accrues continuously where a vault has a venue, so this figure
  // drifts between deposits. Matching VaultApy's cadence keeps the two numbers
  // on the card from disagreeing about which block they were read at.
  const query = { refetchInterval: 15_000 } as const;

  const vault = useReadContracts({
    contracts: [
      { abi: vaultAbi, address: vaultAddress, functionName: 'totalAssets' },
      { abi: vaultAbi, address: vaultAddress, functionName: 'asset' },
    ],
    query,
  });

  const [assetsRead, assetAddressRead] = vault.data ?? [];
  const assetAddress =
    assetAddressRead?.status === 'success' ? (assetAddressRead.result as `0x${string}`) : undefined;

  // Second round, because the address to ask comes from the first. `asset()`
  // is immutable on every vault here, so this settles once and then only the
  // balance above keeps refetching.
  const token = useReadContracts({
    contracts: [
      { abi: erc20Abi, address: assetAddress, functionName: 'decimals' },
      { abi: erc20Abi, address: assetAddress, functionName: 'symbol' },
    ],
    query: { ...query, enabled: Boolean(assetAddress) },
  });

  const [decimalsRead, symbolRead] = token.data ?? [];

  const loading = vault.isLoading || (Boolean(assetAddress) && token.isLoading);
  const ready =
    assetsRead?.status === 'success' &&
    decimalsRead?.status === 'success' &&
    symbolRead?.status === 'success';

  return (
    <div className="card-pad">
      <div className="stat-label">Total deposited</div>

      {loading ? (
        <div
          className="mt-2 h-8 w-32 animate-pulse rounded bg-void-700"
          role="status"
          aria-label="Reading vault balance"
        />
      ) : null}

      {!loading && !ready ? (
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
            {/*
              Says which unit and why, rather than the old line about interest
              accruing at the venue. That was written for a yield vault and is
              simply false on a spot vault, which holds a stock and earns
              nothing while it sits.
            */}
            <p className="mt-2 text-xs leading-relaxed text-ink-400">
              Read from the vault&rsquo;s own <code className="font-mono">totalAssets</code>, and
              denominated in the asset the vault itself reports holding rather than in dollars.
            </p>
          </>
        )
      ) : null}
    </div>
  );
}

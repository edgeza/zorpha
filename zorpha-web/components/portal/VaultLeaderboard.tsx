'use client';

import Link from 'next/link';
import { useReadContract, useReadContracts } from 'wagmi';
import { contracts, erc20Abi, vaultAbi, vaultLauncherAbi, ZERO_ADDRESS } from '@/lib/contracts';
import { activeChain } from '@/lib/chains';
import { formatAddress } from '@/lib/format';

/**
 * The way in.
 *
 * The Leaders page described a permissionless system and offered no way to
 * join it -- launchYieldVault was reachable only from a shell script. A claim
 * about openness that a reader cannot act on is not much of a claim.
 */
export function LaunchLink({ className = '' }: { className?: string }) {
  return (
    <Link href="/portal/leaders/launch" className={`btn-primary btn-sm inline-block ${className}`}>
      Launch a vault
    </Link>
  );
}

type Row = {
  id: number;
  vault: `0x${string}`;
  leader: `0x${string}`;
  totalAssets: bigint;
  escrowBalance: bigint;
  coverageBps: bigint;
  covered: boolean;
  /** Decimals and symbol of this vault's own asset(), not an assumed USDG. */
  assetDecimals?: number;
  assetSymbol?: string;
};

/**
 * First-loss escrow, which really is USDG. Shown whole, because cents on a
 * $400k vault are noise.
 */
function usdg(value: bigint): string {
  return (Number(value) / 1e6).toLocaleString('en-US', { maximumFractionDigits: 0 });
}

/**
 * A vault's deposits, in the vault's own asset.
 *
 * This column used to run `totalAssets` through `usdg` above, which hardcodes
 * six decimals and the USDG label. ERC-4626 reports `totalAssets` in `asset()`
 * units, and a leader may launch against any venue: the one vault launched so
 * far happens to hold USDG, so the column was right by luck rather than by
 * construction. The first leader to launch an equity-style vault, whose asset
 * is an 18-decimal token, would have seen their size overstated by 10^12 and
 * labelled in a currency they never touched. That already happened once on the
 * NVDA vault page, where thirteen dollars rendered as 55 billion.
 *
 * Undefined decimals render as a dash rather than a guess, because a wrong
 * number here is worse than an absent one.
 */
function assetAmount(value: bigint, decimals?: number, symbol?: string): string {
  if (decimals === undefined) return '—';
  const scaled = Number(value) / 10 ** decimals;
  // Precision scaled to size. The old helper rounded everything to whole
  // units, which is right for the $400k vault it was written for and turns
  // 4.50 into "5" on the vaults that actually exist today. Sub-unit holdings
  // get four places because a spot vault denominated in an equity token holds
  // fractions of one.
  const digits = scaled === 0 ? 0 : scaled < 1 ? 4 : scaled < 1000 ? 2 : 0;
  const n = scaled.toLocaleString('en-US', { maximumFractionDigits: digits });
  return symbol ? `${n} ${symbol}` : n;
}

/**
 * What `coverageRatioBps()` returns for a vault with nothing in it.
 *
 * FirstLossEscrow does `if (raw == 0) return type(uint256).max;`; a sentinel
 * meaning "nothing at risk", not a ratio. Passed through Number() it becomes
 * 1.15e77 and rendered as a percentage it reads `1.157920892373162e+75%`,
 * which is what an empty vault showed here before this guard.
 */
const NOTHING_AT_RISK = (1n << 256n) - 1n;

function CoverageBar({ bps, min }: { bps: bigint; min: number }) {
  // An empty vault has no coverage ratio, and saying so beats implying either
  // infinite safety or none. The leader's capital is still shown in its own
  // column, so nothing is hidden by this.
  if (bps === NOTHING_AT_RISK) {
    return (
      <div className="flex items-center justify-end">
        <span
          className="w-14 text-right font-mono text-xs text-ink-500"
          title="No deposits yet, so there is nothing for the buffer to cover."
        >
          , 
        </span>
      </div>
    );
  }

  // The scale tops out at 4x the minimum. A leader at 40% coverage is not
  // four times safer than one at 10% in any way a depositor acts on, and a
  // linear 0-100% scale would render every honest vault as a sliver.
  const ceiling = Math.max(min * 4, 1);
  const raw = Number(bps);
  const pct = Math.min(100, (raw / ceiling) * 100);
  const ok = raw >= min;

  return (
    <div className="flex items-center justify-end gap-2.5">
      <div
        className="h-1.5 w-20 overflow-hidden rounded-full bg-void-700"
        role="img"
        aria-label={`${(raw / 100).toFixed(2)} percent covered, minimum ${min / 100} percent`}
      >
        <div
          className={`h-full rounded-full ${ok ? 'bg-verified-500' : 'bg-amber-500'}`}
          style={{ width: `${Math.max(pct, 3)}%` }}
        />
      </div>
      <span
        className={`w-14 text-right font-mono text-xs tabular-nums ${
          ok ? 'text-verified-400' : 'text-amber-400'
        }`}
      >
        {(raw / 100).toFixed(2)}%
      </span>
    </div>
  );
}

/**
 * Vaults launched through the permissionless launcher.
 *
 * The coverage column is the point of this table. Every other vault dashboard
 * in DeFi can show TVL and a return; none of them can show how much of the
 * leader's own capital is standing in front of the depositors', because in
 * every other design there is none.
 */
export function VaultLeaderboard() {
  const launcher = contracts.vaultLauncher;
  const enabled = launcher !== ZERO_ADDRESS;

  const {
    data: count,
    isLoading: countLoading,
    isError: countError,
  } = useReadContract({
    address: launcher,
    abi: vaultLauncherAbi,
    functionName: 'launchCount',
    chainId: activeChain.id,
    query: { enabled },
  });

  const { data: minBps } = useReadContract({
    address: launcher,
    abi: vaultLauncherAbi,
    functionName: 'minCoverageBps',
    chainId: activeChain.id,
    query: { enabled },
  });

  const total = count ? Number(count) : 0;

  const { data: summaries, isLoading } = useReadContracts({
    contracts: Array.from({ length: total }, (_, i) => ({
      address: launcher,
      abi: vaultLauncherAbi,
      functionName: 'vaultSummary' as const,
      args: [BigInt(i + 1)] as const, // launch ids are 1-indexed
      chainId: activeChain.id,
    })),
    query: { enabled: enabled && total > 0 },
  });

  /**
   * Each vault's own asset, and that asset's decimals and symbol.
   *
   * Two extra rounds because the address to ask comes from the summary, and
   * the token to ask comes from the vault. Both settle once: `asset()` is
   * immutable and an ERC20's decimals do not move, so this costs one burst on
   * first paint and nothing afterwards.
   */
  const vaultAddresses = (summaries ?? [])
    .map((r) => (r.status === 'success' ? ((r.result as readonly unknown[])[0] as `0x${string}`) : null))
    .filter((a): a is `0x${string}` => a !== null);

  const { data: assetAddresses } = useReadContracts({
    contracts: vaultAddresses.map((address) => ({
      address,
      abi: vaultAbi,
      functionName: 'asset' as const,
      chainId: activeChain.id,
    })),
    query: { enabled: vaultAddresses.length > 0 },
  });

  const assets = (assetAddresses ?? []).map((r) =>
    r.status === 'success' ? (r.result as `0x${string}`) : null,
  );

  const { data: assetMeta } = useReadContracts({
    contracts: assets.flatMap((address) =>
      address
        ? [
            { address, abi: erc20Abi, functionName: 'decimals' as const, chainId: activeChain.id },
            { address, abi: erc20Abi, functionName: 'symbol' as const, chainId: activeChain.id },
          ]
        : [],
    ),
    query: { enabled: assets.some(Boolean) },
  });

  if (!enabled) {
    return (
      <div className="card-pad">
        <p className="text-sm text-ink-400">
          The vault launcher is not configured in this environment, so there is nothing to list.
        </p>
      </div>
    );
  }

  // "Still reading", "could not read" and "genuinely none" are three different
  // states and were all rendering as "no vaults have been launched yet". That
  // sentence is a claim about the chain; making it while the RPC call is in
  // flight or has failed states something untrue, and on a page whose whole
  // job is showing that leaders exist, it says the opposite of the truth.
  if (countLoading) {
    return (
      <div className="card-pad">
        <p className="text-sm text-ink-400">Reading the launcher…</p>
      </div>
    );
  }

  if (countError || count === undefined) {
    return (
      <div className="card-pad">
        <p className="text-sm text-ink-400">
          Could not reach the launcher contract at{' '}
          <span className="font-mono text-ink-300">{launcher}</span> on {activeChain.name}. This is
          an RPC problem, not a statement about how many vaults exist.
        </p>
      </div>
    );
  }

  if (total === 0) {
    return (
      <div className="card-pad">
        <p className="text-sm text-ink-400">
          No vaults have been launched yet. The first one will appear here as soon as somebody
          posts a bond and seeds their first-loss capital.
        </p>
        <LaunchLink className="mt-4" />
      </div>
    );
  }

  // Metadata arrives as a flat [decimals, symbol, decimals, symbol, ...] over
  // the vaults whose asset() resolved, so it is indexed by that filtered
  // position rather than by row.
  let metaCursor = 0;
  const metaByVault = new Map<string, { decimals?: number; symbol?: string }>();
  assets.forEach((address, i) => {
    if (!address) return;
    const dec = assetMeta?.[metaCursor * 2];
    const sym = assetMeta?.[metaCursor * 2 + 1];
    metaCursor += 1;
    metaByVault.set(vaultAddresses[i].toLowerCase(), {
      decimals: dec?.status === 'success' ? (dec.result as number) : undefined,
      symbol: sym?.status === 'success' ? (sym.result as string) : undefined,
    });
  });

  const rows: Row[] = (summaries ?? [])
    .map((r, i): Row | null => {
      if (r.status !== 'success') return null;
      const [vault, leader, totalAssets, escrowBalance, coverageBps, covered] =
        r.result as unknown as [`0x${string}`, `0x${string}`, bigint, bigint, bigint, boolean];
      const meta = metaByVault.get(vault.toLowerCase());
      return {
        id: i + 1,
        vault,
        leader,
        totalAssets,
        escrowBalance,
        coverageBps,
        covered,
        assetDecimals: meta?.decimals,
        assetSymbol: meta?.symbol,
      };
    })
    .filter((r): r is Row => r !== null)
    /*
      Largest first, on the decimal-scaled amount rather than the raw integer.
      Comparing raw `totalAssets` across vaults ranked by decimals rather than
      by size: any 18-decimal vault outranked every 6-decimal one by a factor
      of a trillion regardless of what either held.
      This is still not a dollar ranking, because pricing one vault's NVDA
      against another's USDG needs a rate this table does not read. It orders
      by size within a unit and is honest about nothing more.
    */
    .sort((a, b) => {
      const scale = (r: Row) => Number(r.totalAssets) / 10 ** (r.assetDecimals ?? 6);
      return scale(b) - scale(a);
    });

  const min = minBps ? Number(minBps) : 500;

  return (
    <div className="card scroll-x overflow-hidden">
      <table className="w-full min-w-[46rem] text-sm">
        <caption className="sr-only">
          Vaults launched permissionlessly, with the share of each backed by its leader&rsquo;s
          own subordinated capital
        </caption>
        <thead>
          <tr className="border-b border-void-700 bg-void-850 text-left">
            {['#', 'Vault', 'Leader', 'Deposits', 'Leader capital', 'Covered'].map((h, i) => (
              <th
                key={h}
                scope="col"
                className={`px-4 py-3 text-2xs font-medium uppercase tracking-[0.12em] text-ink-500 ${
                  i >= 3 ? 'text-right' : ''
                }`}
              >
                {h}
              </th>
            ))}
          </tr>
        </thead>
        <tbody className="divide-y divide-void-700">
          {rows.map((row, i) => (
            <tr key={row.vault} className="transition-colors hover:bg-void-850/60">
              <td className="px-4 py-3.5 font-mono text-xs text-ink-500">{i + 1}</td>
              <td className="px-4 py-3.5 font-mono text-xs text-ink-300">
                {formatAddress(row.vault)}
              </td>
              <td className="px-4 py-3.5 font-mono text-xs text-zor-300">
                {formatAddress(row.leader)}
              </td>
              <td className="px-4 py-3.5 text-right font-mono text-xs tabular-nums text-ink-100">
                {assetAmount(row.totalAssets, row.assetDecimals, row.assetSymbol)}
              </td>
              <td className="px-4 py-3.5 text-right font-mono text-xs tabular-nums text-ink-100">
                {usdg(row.escrowBalance)}
              </td>
              <td className="px-4 py-3.5">
                <CoverageBar bps={row.coverageBps} min={min} />
              </td>
            </tr>
          ))}
          {isLoading && rows.length === 0 ? (
            <tr>
              <td colSpan={6} className="px-4 py-6 text-center text-sm text-ink-500">
                Reading vaults from chain...
              </td>
            </tr>
          ) : null}
        </tbody>
      </table>
    </div>
  );
}

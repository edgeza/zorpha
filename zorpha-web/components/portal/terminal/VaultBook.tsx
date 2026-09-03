'use client';

import { useMemo } from 'react';
import { erc20Abi, formatUnits } from 'viem';
import type { Address } from 'viem';
import { useReadContracts } from 'wagmi';
import { activeChain } from '@/lib/chains';
import { ROLE, type TerminalVault, type VaultKind } from '@/lib/vault-terminal';

/**
 * The book: every vault this address can reach, read at once.
 *
 * WHAT WAS WRONG BEFORE
 *
 * The terminal listed vaults as a row of pills carrying nothing but a name,
 * and read state for the SELECTED one only. So the answer to "what do I
 * control, and does any of it need me?" was: click each pill in turn and
 * remember what you saw. With one vault that is invisible. With a leader's
 * launches on top of the three factory vaults it is the whole problem --
 * a manager cannot see their book, which is the thing they came here for.
 *
 * Every vault is now read in one multicall and rendered as a card that
 * answers three questions without a click: what is in it, what may I do to
 * it, and does it want attention.
 *
 * WHY THERE IS NO TOTAL
 *
 * The obvious header here is a single portfolio value, and it would be a
 * lie. The spot vault denominates in tAAPL, the yield vault in tUSDG; the
 * rotation vault in its own base. Adding those numbers produces a figure in
 * no unit at all, which is worse than showing nothing because it looks
 * authoritative. The count of vaults is summable. The money is not, until
 * there is a common denominator to convert through -- and the oracle prices
 * assets against USD, not vault shares, so that conversion is real work
 * rather than an arithmetic oversight.
 */

/** Present on all three vault kinds -- verified against the deployed
 *  bytecode of the spot, rotation and yield vaults, all of which answer
 *  every one of these. A per-kind ABI here would mean a separate multicall
 *  per kind and a union type at every call site, for no extra information. */
const bookAbi = [
  { type: 'function', name: 'asset', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
  { type: 'function', name: 'symbol', stateMutability: 'view', inputs: [], outputs: [{ type: 'string' }] },
  { type: 'function', name: 'totalAssets', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'isCircuitBreakerActive', stateMutability: 'view', inputs: [], outputs: [{ type: 'bool' }] },
  { type: 'function', name: 'performanceFeeAccrued', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
  {
    type: 'function',
    name: 'hasRole',
    stateMutability: 'view',
    inputs: [{ type: 'bytes32' }, { type: 'address' }],
    outputs: [{ type: 'bool' }],
  },
] as const;

const READS_PER_VAULT = 6;

/**
 * Deliberately NOT read here: getNavPerShare.
 *
 * It is denominated differently per vault kind -- RWRotationVault returns it
 * in BASE units (tUSDG, 6dp) while its own totalAssets() returns asset() units
 * (tAAPL, 18dp), because asset() is tokens[0] and grossValue() is priced in
 * baseAsset. Rendering both from one decimals lookup would be wrong by twelve
 * orders of magnitude on exactly one of them, silently. The same confusion
 * once paid a depositor 2 HOOD on 10 HOOD in; see RWRotationVault.totalAssets.
 *
 * The per-vault panel reads it with the right decimals for its kind. The book
 * shows only totalAssets, which every kind reports in asset() units.
 */
const ZERO = '0x0000000000000000000000000000000000000000' as const;

const KIND_LABEL: Record<VaultKind, string> = {
  spot: 'Spot',
  rotation: 'Rotation',
  yield: 'Yield',
};

export interface BookRow {
  vault: TerminalVault;
  assetAddr?: Address;
  shareSymbol?: string;
  totalAssets?: bigint;
  halted: boolean;
  feeAccrued?: bigint;
  isKeeper: boolean;
  isLeader: boolean;
  assetSymbol?: string;
  assetDecimals?: number;
}

function compact(value: bigint, decimals: number): string {
  const n = Number(formatUnits(value, decimals));
  if (!Number.isFinite(n)) return '—';
  if (n === 0) return '0';
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(2)}M`;
  if (n >= 1_000) return `${(n / 1_000).toFixed(2)}k`;
  if (n < 0.01) return '<0.01';
  return n.toLocaleString(undefined, { maximumFractionDigits: 2 });
}

export function VaultBook({
  vaults,
  address,
  leaderKeys,
  selectedKey,
  onSelect,
}: {
  vaults: TerminalVault[];
  address?: Address;
  /** Keys of vaults this address launched. A leader holds no ROLE on their
   *  own vault by design, so role reads alone would report "view only" on
   *  the one vault they are most responsible for. */
  leaderKeys: Set<string>;
  selectedKey?: string;
  onSelect: (key: string) => void;
}) {
  const { data, isLoading } = useReadContracts({
    allowFailure: true,
    contracts: vaults.flatMap((v) => {
      const base = { address: v.address, abi: bookAbi, chainId: activeChain.id } as const;
      return [
        { ...base, functionName: 'asset' },
        { ...base, functionName: 'symbol' },
        { ...base, functionName: 'totalAssets' },
        { ...base, functionName: 'isCircuitBreakerActive' },
        { ...base, functionName: 'performanceFeeAccrued' },
        { ...base, functionName: 'hasRole', args: [ROLE.keeper, address ?? ZERO] },
      ];
    }),
    query: { enabled: vaults.length > 0, refetchInterval: 20_000 },
  });

  const rows: BookRow[] = useMemo(() => {
    return vaults.map((vault, i) => {
      const at = (k: number) => {
        const r = data?.[i * READS_PER_VAULT + k];
        return r?.status === 'success' ? r.result : undefined;
      };
      const big = (k: number) => {
        const v = at(k);
        return typeof v === 'bigint' ? v : undefined;
      };
      return {
        vault,
        assetAddr: at(0) as Address | undefined,
        shareSymbol: at(1) as string | undefined,
        totalAssets: big(2),
        halted: at(3) === true,
        feeAccrued: big(4),
        isKeeper: at(5) === true,
        isLeader: leaderKeys.has(vault.key),
      };
    });
  }, [vaults, data, leaderKeys]);

  // Asset metadata in its own pass: the addresses are only known once the
  // reads above land, and several vaults can share one asset, so this is
  // deduped rather than one lookup per row.
  const assetAddrs = useMemo(() => {
    const seen = new Set<string>();
    const out: Address[] = [];
    for (const r of rows) {
      if (r.assetAddr && !seen.has(r.assetAddr.toLowerCase())) {
        seen.add(r.assetAddr.toLowerCase());
        out.push(r.assetAddr);
      }
    }
    return out;
  }, [rows]);

  const { data: assetMeta } = useReadContracts({
    allowFailure: true,
    contracts: assetAddrs.flatMap((a) => [
      { address: a, abi: erc20Abi, functionName: 'symbol' as const, chainId: activeChain.id },
      { address: a, abi: erc20Abi, functionName: 'decimals' as const, chainId: activeChain.id },
    ]),
    query: { enabled: assetAddrs.length > 0 },
  });

  const metaByAsset = useMemo(() => {
    const m = new Map<string, { symbol?: string; decimals?: number }>();
    assetAddrs.forEach((a, i) => {
      const s = assetMeta?.[i * 2];
      const d = assetMeta?.[i * 2 + 1];
      m.set(a.toLowerCase(), {
        symbol: s?.status === 'success' ? (s.result as string) : undefined,
        decimals: d?.status === 'success' ? Number(d.result) : undefined,
      });
    });
    return m;
  }, [assetAddrs, assetMeta]);

  const enriched = rows.map((r) => {
    const m = r.assetAddr ? metaByAsset.get(r.assetAddr.toLowerCase()) : undefined;
    return { ...r, assetSymbol: m?.symbol, assetDecimals: m?.decimals };
  });

  // Vaults you can act on first. Someone with one live mandate among five
  // listed vaults should not have to hunt for it.
  const ordered = [...enriched].sort((a, b) => {
    const rank = (r: BookRow) => (r.isKeeper ? 0 : r.isLeader ? 1 : 2);
    return rank(a) - rank(b);
  });

  const actionable = enriched.filter((r) => r.isKeeper || r.isLeader).length;

  if (vaults.length === 0) return null;

  return (
    <section className="flex flex-col gap-3">
      <div className="flex flex-wrap items-baseline justify-between gap-2">
        <h2 className="text-sm font-medium text-ink-200">Your book</h2>
        <p className="text-xs text-ink-500">
          {vaults.length} vault{vaults.length === 1 ? '' : 's'} ·{' '}
          {address ? (
            <>
              {actionable} you can act on
              {actionable === 0 && ' — the rest are visible but not yours to move'}
            </>
          ) : (
            'connect a wallet to see which are yours'
          )}
        </p>
      </div>

      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
        {ordered.map((r) => {
          const active = r.vault.key === selectedKey;
          const dec = r.assetDecimals;
          const tvl =
            r.totalAssets !== undefined && dec !== undefined
              ? compact(r.totalAssets, dec)
              : undefined;

          const standing = r.isKeeper
            ? { text: 'Keeper', tone: 'text-emerald-300' }
            : r.isLeader
              ? { text: 'Leader', tone: 'text-amber-300' }
              : { text: 'View only', tone: 'text-ink-500' };

          // At most one attention line, and only for something the operator
          // would act on. "Empty" is a fact, not an alarm, so it stays in the
          // value column rather than becoming a warning.
          const attention = r.halted
            ? { text: 'Halted — circuit breaker on', tone: 'text-rose-300' }
            : r.feeAccrued && r.feeAccrued > 0n
              ? { text: 'Performance fee accrued', tone: 'text-amber-300' }
              : null;

          return (
            <button
              key={r.vault.key}
              type="button"
              aria-current={active ? 'true' : undefined}
              onClick={() => onSelect(r.vault.key)}
              className={`card card-pad flex flex-col gap-2 text-left transition-colors ${
                active
                  ? 'border-ink-500 bg-void-800/80'
                  : 'hover:border-void-500 hover:bg-void-800/50'
              }`}
            >
              <div className="flex items-start justify-between gap-2">
                <div className="min-w-0">
                  <p className="truncate text-sm font-medium text-ink-100">{r.vault.name}</p>
                  <p className="mt-0.5 font-mono text-2xs text-ink-500">
                    {KIND_LABEL[r.vault.kind]}
                    {r.shareSymbol ? ` · ${r.shareSymbol}` : ''}
                  </p>
                </div>
                <span className={`shrink-0 font-mono text-2xs ${standing.tone}`}>
                  {standing.text}
                </span>
              </div>

              <div className="flex items-baseline gap-1.5">
                <span className="font-mono text-lg tabular-nums text-ink-100">
                  {isLoading && tvl === undefined ? '···' : (tvl ?? '—')}
                </span>
                <span className="font-mono text-2xs text-ink-500">
                  {r.assetSymbol ?? ''}
                  {tvl === '0' ? ' · no deposits yet' : ''}
                </span>
              </div>

              {attention ? (
                <p className={`font-mono text-2xs ${attention.tone}`}>{attention.text}</p>
              ) : (
                <p className="font-mono text-2xs text-ink-600">&nbsp;</p>
              )}
            </button>
          );
        })}
      </div>
    </section>
  );
}

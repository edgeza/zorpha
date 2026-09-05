'use client';

import { useEffect, useMemo, useState } from 'react';
import Link from 'next/link';
import {
  useAccount,
  useReadContracts,
  useWaitForTransactionReceipt,
  useWriteContract,
} from 'wagmi';
import { activeChain } from '@/lib/chains';
import { contracts, erc20Abi, erc4626Abi, vaultLauncherAbi } from '@/lib/contracts';

const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000' as const;

/**
 * Launch a vault.
 *
 * Until this existed, `launchYieldVault` was reachable only from a shell
 * script. The Leaders page described a permissionless system and then gave a
 * visitor no way to enter it, which made the claim technically true and
 * practically false.
 *
 * The flow is three transactions and this component does not hide that: a
 * leader is committing real capital, and a single "Launch" button that fires
 * three wallet prompts in sequence is how people approve things they have not
 * read. Each step states its own cost and settles before the next unlocks.
 */

type Step = 'bond' | 'seed' | 'launch';

function shorten(a?: string) {
  return a ? `${a.slice(0, 6)}…${a.slice(-4)}` : '';
}

/** 6dp assets shown whole; the seed is thousands of dollars, not cents. */
function units(v: bigint | undefined, decimals: number, dp = 2) {
  if (v === undefined) return '—';
  const s = (Number(v) / 10 ** decimals).toLocaleString('en-US', { maximumFractionDigits: dp });
  return s;
}

function parseUnits(input: string, decimals: number): bigint | null {
  if (!/^\d*\.?\d*$/.test(input.trim()) || input.trim() === '' || input.trim() === '.') return null;
  const [whole, frac = ''] = input.trim().split('.');
  if (frac.length > decimals) return null;
  return BigInt(whole || '0') * 10n ** BigInt(decimals) + BigInt(frac.padEnd(decimals, '0') || '0');
}

export function LaunchVaultForm() {
  const { address, isConnected, chainId } = useAccount();
  const launcher = contracts.vaultLauncher;
  const configured = launcher !== ZERO_ADDRESS;
  const wrongChain = isConnected && chainId !== activeChain.id;

  const [target, setTarget] = useState('');
  const [name, setName] = useState('');
  const [symbol, setSymbol] = useState('');
  const [seedInput, setSeedInput] = useState('');
  const [step, setStep] = useState<Step>('bond');
  const [launched, setLaunched] = useState<`0x${string}` | null>(null);

  // A salt fixed for the life of this form. Regenerating it per render would
  // change the CREATE2 address between the estimate and the send.
  const salt = useMemo(() => {
    const b = new Uint8Array(32);
    if (typeof crypto !== 'undefined') crypto.getRandomValues(b);
    return `0x${Array.from(b, (x) => x.toString(16).padStart(2, '0')).join('')}` as `0x${string}`;
  }, []);

  const { data: params } = useReadContracts({
    contracts: [
      { address: launcher, abi: vaultLauncherAbi, functionName: 'bondAmount', chainId: activeChain.id },
      { address: launcher, abi: vaultLauncherAbi, functionName: 'minSeedEscrow', chainId: activeChain.id },
      { address: launcher, abi: vaultLauncherAbi, functionName: 'zor', chainId: activeChain.id },
    ],
    query: { enabled: configured },
  });

  const bond = params?.[0]?.status === 'success' ? (params[0].result as bigint) : undefined;
  const minSeed = params?.[1]?.status === 'success' ? (params[1].result as bigint) : undefined;
  const zor = params?.[2]?.status === 'success' ? (params[2].result as `0x${string}`) : contracts.zor;

  // The allowlist, rendered rather than guessed at.
  //
  // `approvedTarget` is a mapping: it can confirm a guess and cannot produce
  // the list, so this form used to ask a leader to paste a raw address and
  // only then told them whether governance allowed it. That is a menu you
  // cannot read. `allApprovedTargets` exists now, so the menu is the input.
  const { data: allTargets } = useReadContracts({
    contracts: [
      {
        address: launcher,
        abi: vaultLauncherAbi,
        functionName: 'allApprovedTargets',
        chainId: activeChain.id,
      },
    ],
    query: { enabled: configured },
  });

  const approvedList = useMemo(() => {
    const r = allTargets?.[0];
    return r?.status === 'success' && Array.isArray(r.result)
      ? (r.result as `0x${string}`[])
      : [];
  }, [allTargets]);

  const { data: venueMeta } = useReadContracts({
    contracts: approvedList.flatMap((t) => [
      { address: t, abi: erc20Abi, functionName: 'symbol' as const, chainId: activeChain.id },
      { address: t, abi: erc4626Abi, functionName: 'asset' as const, chainId: activeChain.id },
    ]),
    query: { enabled: approvedList.length > 0 },
  });

  const venues = useMemo(
    () =>
      approvedList.map((addr, i) => {
        const sym = venueMeta?.[i * 2];
        const ass = venueMeta?.[i * 2 + 1];
        return {
          addr,
          symbol: sym?.status === 'success' ? (sym.result as string) : undefined,
          asset: ass?.status === 'success' ? (ass.result as `0x${string}`) : undefined,
        };
      }),
    [approvedList, venueMeta],
  );

  const targetValid = /^0x[0-9a-fA-F]{40}$/.test(target.trim());
  const targetAddr = targetValid ? (target.trim() as `0x${string}`) : undefined;

  // The venue must be approved by governance, and it dictates the seed asset.
  // Both are read from chain: a leader who picks an unapproved venue should
  // find out here, not from a reverted transaction that cost them gas.
  const { data: venue } = useReadContracts({
    contracts: [
      { address: launcher, abi: vaultLauncherAbi, functionName: 'approvedTarget', args: [targetAddr!], chainId: activeChain.id },
      { address: targetAddr!, abi: erc4626Abi, functionName: 'asset', chainId: activeChain.id },
    ],
    query: { enabled: configured && !!targetAddr },
  });

  const approvedVenue = venue?.[0]?.status === 'success' ? (venue[0].result as boolean) : undefined;
  const asset = venue?.[1]?.status === 'success' ? (venue[1].result as `0x${string}`) : undefined;

  const { data: assetMeta } = useReadContracts({
    contracts: [
      { address: asset!, abi: erc20Abi, functionName: 'decimals', chainId: activeChain.id },
      { address: asset!, abi: erc20Abi, functionName: 'symbol', chainId: activeChain.id },
    ],
    query: { enabled: !!asset },
  });
  const assetDecimals = assetMeta?.[0]?.status === 'success' ? Number(assetMeta[0].result) : 6;
  // Undefined until a venue is chosen, because the venue decides the asset.
  // Reading it back as a literal "the asset" produced "at least 1,000 the
  // asset" in the cost panel before anything was typed.
  const assetSymbol =
    assetMeta?.[1]?.status === 'success' ? String(assetMeta[1].result) : undefined;
  const assetLabel = assetSymbol ?? 'of the venue’s asset';

  const { data: balances, refetch: refetchBalances } = useReadContracts({
    contracts: [
      { address: zor, abi: erc20Abi, functionName: 'balanceOf', args: [address!], chainId: activeChain.id },
      { address: zor, abi: erc20Abi, functionName: 'allowance', args: [address!, launcher], chainId: activeChain.id },
      { address: asset!, abi: erc20Abi, functionName: 'balanceOf', args: [address!], chainId: activeChain.id },
      { address: asset!, abi: erc20Abi, functionName: 'allowance', args: [address!, launcher], chainId: activeChain.id },
    ],
    query: { enabled: !!address && !!asset && configured },
  });

  const zorBalance = balances?.[0]?.status === 'success' ? (balances[0].result as bigint) : undefined;
  const zorAllowance = balances?.[1]?.status === 'success' ? (balances[1].result as bigint) : undefined;
  const assetBalance = balances?.[2]?.status === 'success' ? (balances[2].result as bigint) : undefined;
  const assetAllowance = balances?.[3]?.status === 'success' ? (balances[3].result as bigint) : undefined;

  const seed = parseUnits(seedInput, assetDecimals);
  const seedOk = seed !== null && minSeed !== undefined && seed >= minSeed;

  const { writeContract, data: txHash, isPending, error, reset } = useWriteContract();
  const { isLoading: confirming, isSuccess, data: receipt } = useWaitForTransactionReceipt({
    hash: txHash,
  });

  // Advance only once the chain has confirmed. Same lesson as the delegate
  // button: refetching or advancing state during render loops forever.
  useEffect(() => {
    if (!isSuccess) return;
    void refetchBalances();
    if (step === 'bond') setStep('seed');
    else if (step === 'seed') setStep('launch');
    else if (step === 'launch' && receipt) setLaunched(receipt.transactionHash);
    reset();
  }, [isSuccess, step, receipt, refetchBalances, reset]);

  // The step the leader is actually on, derived from allowances rather than
  // from clicks, so a reload or an approval made elsewhere is not re-requested.
  const bondDone = bond !== undefined && zorAllowance !== undefined && zorAllowance >= bond;
  const seedDone = seed !== null && assetAllowance !== undefined && assetAllowance >= seed;
  const current: Step = !bondDone ? 'bond' : !seedDone ? 'seed' : 'launch';

  if (!configured) {
    return (
      <div className="card-pad">
        <p className="text-sm text-ink-400">
          The vault launcher is not configured in this environment.
        </p>
      </div>
    );
  }

  if (launched) {
    return (
      <div className="card-pad">
        <h3 className="text-base font-semibold text-verified-400">Vault launched</h3>
        <p className="mt-2 text-sm leading-relaxed text-ink-300">
          Your first-loss capital is posted and subordinated. It absorbs losses before any
          depositor&rsquo;s, and the coverage ratio is now readable from the escrow by anyone.
        </p>
        <p className="mt-3 font-mono text-xs text-ink-500">{launched}</p>
        <Link href="/portal/leaders" className="btn-primary btn-sm mt-4 inline-block">
          See it on the leaderboard
        </Link>
      </div>
    );
  }

  const canLaunch =
    isConnected && !wrongChain && targetValid && approvedVenue === true && seedOk && !!name && !!symbol;

  return (
    <div className="space-y-5">
      {/* --- What it costs ------------------------------------------------ */}
      <div className="card-pad">
        <h2 className="text-sm font-semibold text-ink-100">What it costs</h2>
        <dl className="mt-4 grid gap-4 sm:grid-cols-2">
          <div>
            <dt className="stat-label">Bond</dt>
            <dd className="mt-1 font-mono text-sm text-ink-200">
              {units(bond, 18, 0)} $ZOR
            </dd>
            <p className="mt-1 text-xs leading-relaxed text-ink-500">
              Refundable once the vault is empty. Slashable by governance for misconduct, not for
              losing money — a drawdown is not misconduct.
            </p>
          </div>
          <div>
            <dt className="stat-label">First-loss capital</dt>
            <dd className="mt-1 font-mono text-sm text-ink-200">
              at least {units(minSeed, assetDecimals, 0)} {assetLabel}
            </dd>
            <p className="mt-1 text-xs leading-relaxed text-ink-500">
              Genuinely at risk. This is the money that absorbs losses before your depositors&rsquo;
              does, and you cannot withdraw it below the coverage floor.
            </p>
          </div>
        </dl>
        <p className="mt-4 text-xs leading-relaxed text-ink-400">
          You keep 80% of performance fees. While your coverage is below the floor, your share is
          retained into the escrow instead of paid out — you rebuild the buffer before you earn
          again.
        </p>
      </div>

      {/* --- The form ----------------------------------------------------- */}
      <div className="card-pad space-y-4">
        <h2 className="text-sm font-semibold text-ink-100">Your vault</h2>

        {venues.length > 0 ? (
          <div>
            <span className="stat-label">Approved venues</span>
            <div className="mt-1.5 grid gap-2 sm:grid-cols-2">
              {venues.map((v) => {
                const active = v.addr.toLowerCase() === target.trim().toLowerCase();
                return (
                  <button
                    key={v.addr}
                    type="button"
                    aria-current={active ? 'true' : undefined}
                    onClick={() => setTarget(v.addr)}
                    className={`rounded-md border px-3 py-2 text-left transition-colors ${
                      active
                        ? 'border-zor-500 bg-void-800'
                        : 'border-void-600 hover:border-void-500 hover:bg-void-800/60'
                    }`}
                  >
                    <span className="block text-sm text-ink-100">
                      {v.symbol ?? 'Venue'}
                    </span>
                    <span className="mt-0.5 block font-mono text-2xs text-ink-500">
                      {shorten(v.addr)}
                    </span>
                  </button>
                );
              })}
            </div>
            <p className="mt-1.5 text-xs text-ink-500">
              Governance approves these. A venue not on this list cannot be launched
              against &mdash; the transaction reverts.
            </p>
          </div>
        ) : null}

        <label className="block">
          <span className="stat-label">
            {venues.length > 0 ? 'Venue address' : 'Venue (an approved ERC-4626 address)'}
          </span>
          <input
            value={target}
            onChange={(e) => setTarget(e.target.value)}
            placeholder="0x…"
            spellCheck={false}
            className="mt-1.5 w-full rounded-md border border-void-600 bg-void-900 px-3 py-2 font-mono text-sm text-ink-100 placeholder:text-ink-600 focus:border-zor-500 focus:outline-none"
          />
          {target && !targetValid ? (
            <span className="mt-1 block text-xs text-amber-400">Not a valid address.</span>
          ) : null}
          {targetValid && approvedVenue === false ? (
            <span className="mt-1 block text-xs text-amber-400">
              Governance has not approved this venue. Launching against it would revert.
            </span>
          ) : null}
          {targetValid && approvedVenue === true ? (
            <span className="mt-1 block text-xs text-verified-400">
              Approved. Settles in {assetSymbol ?? 'its own asset'} ({shorten(asset)}).
            </span>
          ) : null}
        </label>

        <div className="grid gap-4 sm:grid-cols-2">
          <label className="block">
            <span className="stat-label">Vault name</span>
            <input
              value={name}
              onChange={(e) => setName(e.target.value)}
              placeholder="Zorpha Steady Yield"
              className="mt-1.5 w-full rounded-md border border-void-600 bg-void-900 px-3 py-2 text-sm text-ink-100 placeholder:text-ink-600 focus:border-zor-500 focus:outline-none"
            />
          </label>
          <label className="block">
            <span className="stat-label">Share symbol</span>
            <input
              value={symbol}
              onChange={(e) => setSymbol(e.target.value.toUpperCase())}
              placeholder="ZQSTDY"
              className="mt-1.5 w-full rounded-md border border-void-600 bg-void-900 px-3 py-2 font-mono text-sm text-ink-100 placeholder:text-ink-600 focus:border-zor-500 focus:outline-none"
            />
          </label>
        </div>

        <label className="block">
          <span className="stat-label">
            First-loss capital to post{assetSymbol ? ` (${assetSymbol})` : ''}
          </span>
          <input
            value={seedInput}
            onChange={(e) => setSeedInput(e.target.value)}
            inputMode="decimal"
            placeholder={minSeed !== undefined ? units(minSeed, assetDecimals, 0) : '1000'}
            className="mt-1.5 w-full rounded-md border border-void-600 bg-void-900 px-3 py-2 font-mono text-sm text-ink-100 placeholder:text-ink-600 focus:border-zor-500 focus:outline-none"
          />
          {seedInput && seed === null ? (
            <span className="mt-1 block text-xs text-amber-400">Not a valid amount.</span>
          ) : null}
          {seed !== null && minSeed !== undefined && seed < minSeed ? (
            <span className="mt-1 block text-xs text-amber-400">
              Below the {units(minSeed, assetDecimals, 0)} {assetLabel} minimum.
            </span>
          ) : null}
          {address ? (
            <span className="mt-1 block text-xs text-ink-500">
              You hold {units(assetBalance, assetDecimals)} {assetLabel} and{' '}
              {units(zorBalance, 18, 0)} $ZOR.
            </span>
          ) : null}
        </label>
      </div>

      {/* --- The three transactions --------------------------------------- */}
      <div className="card-pad">
        <h2 className="text-sm font-semibold text-ink-100">Three transactions</h2>
        <p className="mt-2 text-xs leading-relaxed text-ink-400">
          Approve the bond, approve the capital, then launch. Each settles before the next unlocks,
          so you can stop after any of them; an approval on its own moves nothing.
        </p>

        <ol className="mt-4 space-y-3">
          {(
            [
              {
                key: 'bond' as const,
                label: `Approve ${units(bond, 18, 0)} $ZOR bond`,
                done: bondDone,
                onClick: () =>
                  writeContract({
                    abi: erc20Abi,
                    address: zor,
                    functionName: 'approve',
                    args: [launcher, bond!],
                  }),
                ready: bond !== undefined,
              },
              {
                key: 'seed' as const,
                label: `Approve ${seedInput || '—'} ${assetSymbol ?? 'asset'} capital`,
                done: seedDone,
                onClick: () =>
                  writeContract({
                    abi: erc20Abi,
                    address: asset!,
                    functionName: 'approve',
                    args: [launcher, seed!],
                  }),
                ready: !!asset && seedOk,
              },
              {
                key: 'launch' as const,
                label: 'Launch the vault',
                done: false,
                onClick: () =>
                  writeContract({
                    abi: vaultLauncherAbi,
                    address: launcher,
                    functionName: 'launchYieldVault',
                    args: [targetAddr!, seed!, name, symbol, salt],
                  }),
                ready: canLaunch,
              },
            ] satisfies Array<{
              key: Step;
              label: string;
              done: boolean;
              onClick: () => void;
              ready: boolean;
            }>
          ).map((s, i) => {
            const isCurrent = current === s.key;
            const busy = isCurrent && (isPending || confirming);
            return (
              <li key={s.key} className="flex items-center gap-3">
                <span
                  className={`flex h-6 w-6 shrink-0 items-center justify-center rounded-full text-xs font-mono ${
                    s.done
                      ? 'bg-verified-500/15 text-verified-400'
                      : isCurrent
                        ? 'bg-zor-500/15 text-zor-400'
                        : 'bg-void-800 text-ink-600'
                  }`}
                >
                  {s.done ? '✓' : i + 1}
                </span>
                <span className={`flex-1 text-sm ${s.done ? 'text-ink-500' : 'text-ink-200'}`}>
                  {s.label}
                </span>
                <button
                  type="button"
                  disabled={!isCurrent || !s.ready || busy || !isConnected || wrongChain}
                  onClick={s.onClick}
                  className="btn-primary btn-sm shrink-0 disabled:opacity-40"
                >
                  {s.done
                    ? 'Done'
                    : busy
                      ? isPending
                        ? 'Confirm in wallet…'
                        : 'Confirming…'
                      : s.key === 'launch'
                        ? 'Launch'
                        : 'Approve'}
                </button>
              </li>
            );
          })}
        </ol>

        {!isConnected ? (
          <p className="mt-4 text-xs text-ink-500">Connect a wallet to begin.</p>
        ) : wrongChain ? (
          <p className="mt-4 text-xs text-amber-400">
            Your wallet is on chain {chainId}. Switch to {activeChain.name} ({activeChain.id}).
          </p>
        ) : null}

        {error ? (
          <p className="mt-4 text-xs leading-relaxed text-danger-400">
            {error.message.split('\n')[0]}
          </p>
        ) : null}
      </div>
    </div>
  );
}

'use client';

import { useEffect, useMemo, useState } from 'react';
import { formatUnits } from 'viem';
import type { Address } from 'viem';
import { useWriteContract, useWaitForTransactionReceipt } from 'wagmi';
import { spotVaultAbi, rotationVaultAbi, yieldVaultAbi } from '@/lib/manager-abi';
import {
  previewSpot,
  weightsProblem,
  type VaultKind,
  type OracleState,
} from '@/lib/vault-terminal';
import { Callout, Mono } from '@/components/ui/Primitives';
import { explorerTx } from '@/lib/contracts';

/**
 * The one action a manager takes, in the three shapes it comes in.
 *
 * Everything here is built around showing what a signature will DO before it
 * is signed, because the alternative — sign, wait, read an event log — is what
 * the shell scripts already did and is the reason nobody but us has ever
 * operated a vault.
 */

interface Common {
  vault: Address;
  canKeep: boolean;
  reasonCannot: string | null;
  halted: boolean;
  oracle: OracleState;
  assetSymbol: string;
  assetDecimals: number;
  onDone: () => void;
}

function fmt(v: bigint, decimals: number, dp = 2) {
  const n = Number(formatUnits(v, decimals));
  return n.toLocaleString('en-US', { maximumFractionDigits: dp });
}

/**
 * The blockers, in the order the contract checks them.
 *
 * Order matters and is not cosmetic: `rebalanceTo` reverts on the circuit
 * breaker before it ever reads the oracle, so a halted vault with a stale
 * price must report the halt. Reporting staleness there would send a manager
 * to wait for a price update that would not have helped.
 */
function Blockers({
  canKeep,
  reasonCannot,
  halted,
  oracle,
}: Pick<Common, 'canKeep' | 'reasonCannot' | 'halted' | 'oracle'>) {
  if (!canKeep) {
    return (
      <Callout tone="info" title="You cannot rebalance this vault">
        <p>{reasonCannot}</p>
      </Callout>
    );
  }
  if (halted) {
    return (
      <Callout tone="danger" title="The circuit breaker is on">
        <p>
          Deposits are stopped and <Mono>rebalanceTo</Mono> reverts with{' '}
          <Mono>CircuitBreakerActive</Mono> before it reads anything else. Lift the breaker first.
        </p>
      </Callout>
    );
  }
  if (oracle.status === 'stale') {
    return (
      <Callout tone="danger" title="The oracle is stale">
        <p>
          The last price is older than the vault&rsquo;s staleness window, so any rebalance reverts
          with <Mono>StaleOracle</Mono>. Wait for the next report — signing now only spends gas.
        </p>
      </Callout>
    );
  }
  return null;
}

// --- Spot -------------------------------------------------------------------

export function SpotRebalance(
  props: Common & {
    grossValue: bigint;
    currentAsset: bigint;
    targetWeightBps: number;
    thresholdBps: number;
    slippageBps: number;
  },
) {
  const {
    vault, grossValue, currentAsset, targetWeightBps, thresholdBps, slippageBps,
    assetSymbol, assetDecimals, canKeep, halted, oracle, onDone,
  } = props;

  const [target, setTarget] = useState<number>(targetWeightBps);
  useEffect(() => setTarget(targetWeightBps), [targetWeightBps]);

  const { writeContract, data: hash, isPending, error, reset } = useWriteContract();
  const { isLoading: confirming, isSuccess } = useWaitForTransactionReceipt({ hash });

  useEffect(() => {
    if (isSuccess) onDone();
  }, [isSuccess, onDone]);

  const preview = useMemo(
    () => previewSpot({ targetBps: target, grossValue, currentAsset, thresholdBps, slippageBps }),
    [target, grossValue, currentAsset, thresholdBps, slippageBps],
  );

  const blocked = !canKeep || halted || oracle.status === 'stale';
  const busy = isPending || confirming;

  return (
    <div className="flex flex-col gap-4">
      <Blockers {...props} />

      <div className="flex flex-col gap-3">
        <div className="flex items-baseline justify-between gap-4">
          <label htmlFor="target" className="stat-label">
            Target exposure
          </label>
          <span className="font-mono text-2xl tabular-nums">{(target / 100).toFixed(2)}%</span>
        </div>

        <input
          id="target"
          type="range"
          min={0}
          max={10000}
          step={25}
          value={target}
          disabled={blocked || busy}
          onChange={(e) => setTarget(Number(e.target.value))}
          className="w-full accent-current disabled:opacity-40"
        />

        <div className="flex items-center gap-3">
          <input
            type="number"
            min={0}
            max={100}
            step={0.25}
            value={(target / 100).toString()}
            disabled={blocked || busy}
            onChange={(e) => setTarget(Math.round(Number(e.target.value) * 100))}
            className="input w-28 font-mono tabular-nums"
            aria-label="Target exposure, percent"
          />
          <span className="text-sm text-ink-400">% in {assetSymbol}, the rest in cash</span>
          <div className="ml-auto flex gap-1">
            {[0, 2500, 5000, 7500, 10000].map((bps) => (
              <button
                key={bps}
                type="button"
                disabled={blocked || busy}
                onClick={() => setTarget(bps)}
                className="btn btn-quiet btn-sm tnum"
              >
                {bps / 100}%
              </button>
            ))}
          </div>
        </div>
      </div>

      {/* The preview. Its whole job is the belowThreshold case. */}
      <dl className="grid grid-cols-2 gap-x-6 gap-y-2 border-y border-void-800 py-3 text-sm sm:grid-cols-4">
        <div>
          <dt className="stat-label">Now</dt>
          <dd className="mt-0.5 font-mono tabular-nums">{(preview.currentBps / 100).toFixed(2)}%</dd>
        </div>
        <div>
          <dt className="stat-label">After</dt>
          <dd className="mt-0.5 font-mono tabular-nums">{(target / 100).toFixed(2)}%</dd>
        </div>
        <div>
          <dt className="stat-label">Move</dt>
          <dd className="mt-0.5 font-mono tabular-nums">
            {preview.direction === 'none' ? '—' : (
              <>
                {preview.direction === 'buy' ? '+' : '−'}
                {fmt(preview.delta, assetDecimals)} {assetSymbol}
              </>
            )}
          </dd>
        </div>
        <div>
          <dt className="stat-label">Min out</dt>
          <dd className="mt-0.5 font-mono tabular-nums">
            {preview.direction === 'none' ? '—' : fmt(preview.minOut, assetDecimals)}
          </dd>
        </div>
      </dl>

      {preview.belowThreshold && grossValue > 0n && (
        <Callout tone="warn" title="This would not trade">
          <p>
            The move is smaller than the vault&rsquo;s {(thresholdBps / 100).toFixed(2)}% rebalance
            threshold. The contract writes the new target and returns — no swap, no receipt, no{' '}
            <Mono>rebalanceCount</Mono> bump. The transaction succeeds and costs gas. Widen the
            move if you meant to trade.
          </p>
        </Callout>
      )}

      {grossValue === 0n && (
        <Callout tone="info" title="The vault is empty">
          <p>
            With no assets there is nothing to swap. Setting a target still records it, and it
            takes effect on the first rebalance after a deposit.
          </p>
        </Callout>
      )}

      {error && (
        <Callout tone="danger" title="The transaction was rejected">
          <p className="break-words">{error.message.split('\n')[0]}</p>
        </Callout>
      )}

      {isSuccess && hash && (
        <Callout tone="verified" title="Rebalanced">
          <p>
            <a href={explorerTx(hash)} target="_blank" rel="noreferrer">
              View the transaction
            </a>
            . The receipt appears on the vault page once the indexer picks it up.
          </p>
        </Callout>
      )}

      <div className="flex items-center gap-3">
        <button
          type="button"
          className="btn-primary self-start"
          disabled={blocked || busy || target === preview.currentBps}
          onClick={() => {
            reset();
            writeContract({
              abi: spotVaultAbi,
              address: vault,
              functionName: 'rebalanceTo',
              args: [target],
            });
          }}
        >
          {busy ? 'Confirming…' : preview.belowThreshold ? 'Set target' : 'Rebalance'}
        </button>
        {slippageBps > 0 && !blocked && (
          <span className="text-xs text-ink-500">
            Bounded at {(slippageBps / 100).toFixed(2)}% slippage by the contract.
          </span>
        )}
      </div>
    </div>
  );
}

// --- Rotation ---------------------------------------------------------------

export function RotationRebalance(
  props: Common & { weights: number[]; symbols: string[] },
) {
  const { vault, weights, symbols, canKeep, halted, oracle, onDone } = props;

  const [draft, setDraft] = useState<number[]>(weights);
  useEffect(() => setDraft(weights), [weights]);

  const { writeContract, data: hash, isPending, error, reset } = useWriteContract();
  const { isLoading: confirming, isSuccess } = useWaitForTransactionReceipt({ hash });
  useEffect(() => {
    if (isSuccess) onDone();
  }, [isSuccess, onDone]);

  const problem = weightsProblem(draft);
  const blocked = !canKeep || halted || oracle.status === 'stale';
  const busy = isPending || confirming;
  const unchanged = draft.length === weights.length && draft.every((w, i) => w === weights[i]);
  const total = draft.reduce((a, b) => a + b, 0);

  return (
    <div className="flex flex-col gap-4">
      <Blockers {...props} />

      <div className="flex flex-col gap-3">
        {draft.map((w, i) => (
          <div key={i} className="flex items-center gap-3">
            <span className="w-24 shrink-0 font-mono text-sm">{symbols[i] ?? `Leg ${i + 1}`}</span>
            <input
              type="range"
              min={0}
              max={10000}
              step={25}
              value={w}
              disabled={blocked || busy}
              onChange={(e) => {
                const next = [...draft];
                next[i] = Number(e.target.value);
                setDraft(next);
              }}
              className="flex-1 disabled:opacity-40"
            />
            <input
              type="number"
              min={0}
              max={100}
              step={0.25}
              value={(w / 100).toString()}
              disabled={blocked || busy}
              onChange={(e) => {
                const next = [...draft];
                next[i] = Math.round(Number(e.target.value) * 100);
                setDraft(next);
              }}
              className="input w-24 font-mono tabular-nums"
              aria-label={`Weight for ${symbols[i] ?? `leg ${i + 1}`}, percent`}
            />
          </div>
        ))}
      </div>

      <div className="flex items-baseline justify-between border-y border-void-800 py-3">
        <span className="stat-label">Total</span>
        <span
          className={`font-mono text-lg tabular-nums ${total === 10000 ? '' : 'text-ink-400'}`}
        >
          {(total / 100).toFixed(2)}%
        </span>
      </div>

      {problem && (
        <Callout tone="warn" title="Weights are not valid yet">
          <p>
            {problem} The contract rejects anything else with <Mono>BadWeights</Mono>.
          </p>
        </Callout>
      )}

      {error && (
        <Callout tone="danger" title="The transaction was rejected">
          <p className="break-words">{error.message.split('\n')[0]}</p>
        </Callout>
      )}

      {isSuccess && hash && (
        <Callout tone="verified" title="Rebalanced">
          <p>
            <a href={explorerTx(hash)} target="_blank" rel="noreferrer">
              View the transaction
            </a>
            .
          </p>
        </Callout>
      )}

      <button
        type="button"
        className="btn-primary self-start"
        disabled={blocked || busy || !!problem || unchanged}
        onClick={() => {
          reset();
          writeContract({
            abi: rotationVaultAbi,
            address: vault,
            functionName: 'rebalanceTo',
            args: [draft],
          });
        }}
      >
        {busy ? 'Confirming…' : 'Rebalance'}
      </button>
    </div>
  );
}

// --- Yield ------------------------------------------------------------------

/**
 * Yield. `rebalanceTo()` takes no argument AND MOVES NO FUNDS.
 *
 * Worth being exact about, because the name says otherwise and the first
 * version of this panel said otherwise too. The whole function body is:
 *
 *     rebalanceCount += 1;
 *     nav = getNavPerShare();
 *     adapterBal = asset.balanceOf(address(adapter));
 *     emit Rebalanced(nav, totalAssets(), adapterBal, rebalanceCount, commit);
 *
 * No transfer, no `adapter.deposit`. Assets reach the venue on the way IN --
 * `_deposit` calls `_pushToAdapter(assets)` -- and are recalled on the way out.
 * So there is never idle cash for a keeper to sweep, and a button offering to
 * "deploy idle cash" would describe something the contract does not do.
 *
 * What the call is actually for: stamping a checkpoint. It writes a receipt of
 * where the vault stands, with a commitment hash, into the permanent record.
 */
export function YieldRebalance(
  props: Common & { atVenue: bigint; navPerShare: bigint | undefined; rebalanceCount: bigint | undefined },
) {
  const {
    vault, atVenue, navPerShare, rebalanceCount,
    assetSymbol, assetDecimals, canKeep, halted, oracle, onDone,
  } = props;

  const { writeContract, data: hash, isPending, error, reset } = useWriteContract();
  const { isLoading: confirming, isSuccess } = useWaitForTransactionReceipt({ hash });
  useEffect(() => {
    if (isSuccess) onDone();
  }, [isSuccess, onDone]);

  const blocked = !canKeep || halted || oracle.status === 'stale';
  const busy = isPending || confirming;

  return (
    <div className="flex flex-col gap-4">
      <Blockers {...props} />

      <p className="max-w-prose text-sm leading-relaxed text-ink-400">
        This one moves no money. Deposits go straight to the venue on the way in, so there is
        never idle cash to sweep. What <Mono>rebalanceTo</Mono> does here is stamp a checkpoint:
        it writes a receipt of the vault&rsquo;s NAV and balances, with a commitment hash, into
        the permanent record.
      </p>
      <p className="max-w-prose text-sm leading-relaxed text-ink-400">
        Changing which venue the vault uses is a different call — <Mono>reallocate</Mono> on the
        launcher — and it belongs to the leader, not the keeper.
      </p>

      <dl className="grid grid-cols-2 gap-x-6 gap-y-2 border-y border-void-800 py-3 text-sm sm:grid-cols-3">
        <div>
          <dt className="stat-label">At the venue</dt>
          <dd className="mt-0.5 font-mono tabular-nums">
            {fmt(atVenue, assetDecimals)} {assetSymbol}
          </dd>
        </div>
        <div>
          <dt className="stat-label">NAV / share</dt>
          <dd className="mt-0.5 font-mono tabular-nums">
            {/* Asset units, not 18. A yield vault on 6-decimal USDG rendered a
                NAV of 1.000000 as 0.000000 under a hardcoded 18. */}
            {navPerShare === undefined ? '—' : Number(formatUnits(navPerShare, assetDecimals)).toFixed(6)}
          </dd>
        </div>
        <div>
          <dt className="stat-label">Checkpoints</dt>
          <dd className="mt-0.5 font-mono tabular-nums">{rebalanceCount?.toString() ?? '—'}</dd>
        </div>
      </dl>

      {error && (
        <Callout tone="danger" title="The transaction was rejected">
          <p className="break-words">{error.message.split('\n')[0]}</p>
        </Callout>
      )}

      {isSuccess && hash && (
        <Callout tone="verified" title="Checkpoint recorded">
          <p>
            <a href={explorerTx(hash)} target="_blank" rel="noreferrer">
              View the transaction
            </a>
            .
          </p>
        </Callout>
      )}

      <button
        type="button"
        className="btn-primary self-start"
        disabled={blocked || busy}
        onClick={() => {
          reset();
          writeContract({ abi: yieldVaultAbi, address: vault, functionName: 'rebalanceTo' });
        }}
      >
        {busy ? 'Confirming…' : 'Record a checkpoint'}
      </button>
    </div>
  );
}

export type { VaultKind };

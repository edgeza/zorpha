'use client';

import { useCallback, useEffect, useState } from 'react';
import {
  createPublicClient,
  http,
  encodeFunctionData,
  decodeErrorResult,
  type Address,
} from 'viem';
import { robinhoodTestnet } from '@/lib/chains';
import { contracts, isDeployed, explorerAddress } from '@/lib/contracts';

/**
 * The refusals, run against the live executor while you watch.
 *
 * WHY SIMULATE INSTEAD OF LINKING TO TRANSACTIONS
 *
 * The obvious version of this panel links to four failed transactions from the
 * drills. It cannot be built: `testnet-spot-drill.sh` submits with `cast send`,
 * which estimates gas first, so a call that reverts never reaches a block.
 * Those refusals have no transaction hash to link to. They happened, and they
 * left no receipt -- which is exactly right, and exactly useless as evidence.
 *
 * An `eth_call` is better than a link anyway. It runs the deployed bytecode,
 * against current state, at the moment the reader clicks, and returns the
 * contract's own revert. It costs nothing, needs no wallet, and cannot be
 * staged: anyone can repeat it with curl.
 *
 * WHY THIS WORKS AT ALL: THE SIGNATURE IS CHECKED LAST
 *
 * `StrategyExecutor.executeRebalance` runs its guards in this order --
 *
 *     ZeroVault -> InvalidWeight -> SignalExpired / ExpiryTooFar /
 *     NonceAlreadyUsed -> trading window -> DailyLimitExceeded -> signature
 *
 * so every guard except the last can be reached with a signature made of
 * nonsense. The contract rejects the instruction before it ever looks at who
 * signed it. That ordering is what makes an honest demo possible without a key,
 * and if it ever changes these probes start returning InvalidSignature for
 * everything -- which the panel will show rather than hide.
 *
 * `from` must be the keeper. `executeRebalance` is `onlyRole(KEEPER_ROLE)`, so
 * simulating as anybody else fails on access control and proves nothing about
 * the guard under test. eth_call does not verify signatures, so naming the
 * keeper here grants no authority and needs no key.
 *
 * WHAT IS DELIBERATELY NOT HERE
 *
 * DailyLimitExceeded needs the vault's rolling window already full, which we
 * cannot arrange from a read. The panel reports the live count against the
 * limit instead of faking the refusal.
 *
 * MarketClosed is in the contract source but not in the deployed bytecode on
 * testnet yet, so it is not advertised. When that deploy lands it will start
 * appearing on its own -- these probes read whatever is deployed, which is the
 * point.
 */

const EXECUTOR_ABI = [
  {
    type: 'function',
    name: 'executeRebalance',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'vault', type: 'address' },
      { name: 'targetWeightBps', type: 'uint16' },
      { name: 'nonce', type: 'uint256' },
      { name: 'expiry', type: 'uint256' },
      { name: 'signature', type: 'bytes' },
    ],
    outputs: [{ type: 'bool' }],
  },
  { type: 'function', name: 'getNonce', stateMutability: 'view', inputs: [{ type: 'address' }], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'dailyLimit', stateMutability: 'view', inputs: [{ type: 'address' }], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'getRecentRebalanceCount', stateMutability: 'view', inputs: [{ type: 'address' }], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'authorizedSigner', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
  { type: 'error', name: 'InvalidSignature', inputs: [] },
  { type: 'error', name: 'SignalExpired', inputs: [{ type: 'uint256' }, { type: 'uint256' }] },
  { type: 'error', name: 'NonceAlreadyUsed', inputs: [{ type: 'address' }, { type: 'uint256' }] },
  { type: 'error', name: 'InvalidWeight', inputs: [{ type: 'uint16' }] },
  { type: 'error', name: 'ExpiryTooFar', inputs: [{ type: 'uint256' }, { type: 'uint256' }] },
  { type: 'error', name: 'DailyLimitExceeded', inputs: [{ type: 'uint256' }, { type: 'uint256' }] },
  { type: 'error', name: 'MarketClosed', inputs: [{ type: 'address' }, { type: 'uint256' }, { type: 'uint256' }] },
  { type: 'error', name: 'MarketHalted', inputs: [{ type: 'address' }, { type: 'uint64' }] },
] as const;

/** Sixty-five bytes of nothing. Never a valid signature, and never needs to be. */
const JUNK_SIGNATURE = `0x${'11'.repeat(65)}` as const;

/** The keeper may submit and may not decide. eth_call as it, sign nothing. */
const KEEPER: Address = '0x613ab528E46fCeD27350465E338354776B2a790a';

type Probe = {
  id: string;
  label: string;
  expect: string;
  note: string;
  args: (next: bigint, last: bigint, now: bigint, vault: Address) => readonly unknown[];
};

const PROBES: Probe[] = [
  {
    id: 'weight',
    label: 'Ask for 100.01% exposure',
    expect: 'InvalidWeight',
    note: 'A weight above 10000 bps is refused before anything else is read.',
    args: (next, _l, now, v) => [v, 10001, next, now + 600n, JUNK_SIGNATURE],
  },
  {
    id: 'expired',
    label: 'Send an instruction after its deadline',
    expect: 'SignalExpired',
    note: 'A signature with no expiry is a standing authorisation. These expire.',
    args: (next, _l, now, v) => [v, 5000, next, now - 60n, JUNK_SIGNATURE],
  },
  {
    id: 'cap',
    label: 'Sign one that lasts 90 days',
    expect: 'ExpiryTooFar',
    note: 'The manager does not get to choose an unbounded deadline either.',
    args: (next, _l, now, v) => [v, 5000, next, now + 90n * 86_400n, JUNK_SIGNATURE],
  },
  {
    id: 'replay',
    label: 'Replay one that already ran',
    expect: 'NonceAlreadyUsed',
    note: 'Nonces are consumed. The same instruction cannot be submitted twice.',
    args: (_n, last, now, v) => [v, 5000, last, now + 600n, JUNK_SIGNATURE],
  },
  {
    id: 'signer',
    label: 'Submit one nobody signed',
    expect: 'InvalidSignature',
    note: 'The keeper can submit and cannot decide. Only the authorised key decides.',
    args: (next, _l, now, v) => [v, 5000, next, now + 600n, JUNK_SIGNATURE],
  },
];

type Result = { status: 'idle' | 'running' | 'refused' | 'passed' | 'error'; detail?: string };

export function GuardRails() {
  const executor = contracts.strategyExecutor as Address | undefined;
  const vault = contracts.spotVault as Address | undefined;
  const ready = isDeployed('strategyExecutor') && isDeployed('spotVault');

  const [results, setResults] = useState<Record<string, Result>>({});
  const [state, setState] = useState<{ last: bigint; limit: bigint; used: bigint } | null>(null);
  const [chainError, setChainError] = useState<string | null>(null);

  const run = useCallback(async () => {
    if (!ready || !executor || !vault) return;
    setChainError(null);
    setResults(Object.fromEntries(PROBES.map((p) => [p.id, { status: 'running' as const }])));

    const client = createPublicClient({ chain: robinhoodTestnet, transport: http() });

    try {
      const [last, limit, used] = await Promise.all([
        client.readContract({ address: executor, abi: EXECUTOR_ABI, functionName: 'getNonce', args: [vault] }),
        client.readContract({ address: executor, abi: EXECUTOR_ABI, functionName: 'dailyLimit', args: [vault] }),
        client.readContract({ address: executor, abi: EXECUTOR_ABI, functionName: 'getRecentRebalanceCount', args: [vault] }),
      ]);
      setState({ last, limit, used });

      // getNonce reports the last nonce consumed, so the next valid one is +1.
      // Using the returned value as "next" makes every probe collide with the
      // replay case and report NonceAlreadyUsed, which looks like four passes
      // and is four of the same test.
      const next = last + 1n;
      const now = BigInt(Math.floor(Date.now() / 1000));

      await Promise.all(
        PROBES.map(async (probe) => {
          const data = encodeFunctionData({
            abi: EXECUTOR_ABI,
            functionName: 'executeRebalance',
            args: probe.args(next, last, now, vault) as never,
          });
          try {
            await client.call({ account: KEEPER, to: executor, data });
            // Reaching here means a guard we expected did not fire.
            setResults((r) => ({ ...r, [probe.id]: { status: 'passed' } }));
          } catch (err: unknown) {
            const raw = extractRevertData(err);
            let name: string | null = null;
            if (raw) {
              try {
                name = decodeErrorResult({ abi: EXECUTOR_ABI, data: raw }).errorName;
              } catch {
                name = null;
              }
            }
            setResults((r) => ({
              ...r,
              [probe.id]: name
                ? { status: 'refused', detail: name }
                : { status: 'error', detail: shortMessage(err) },
            }));
          }
        }),
      );
    } catch (err: unknown) {
      // One honest failure beats five misleading rows. The portal holds the same
      // standard: show nothing rather than placeholder data.
      setChainError(shortMessage(err));
      setResults({});
    }
  }, [ready, executor, vault]);

  useEffect(() => {
    void run();
  }, [run]);

  if (!ready) {
    return (
      <div className="card card-pad">
        <p className="text-sm text-ink-400">
          The executor address is not configured for this deployment, so there is nothing to
          simulate against.
        </p>
      </div>
    );
  }

  return (
    <div className="card overflow-hidden">
      <div className="flex flex-wrap items-center justify-between gap-x-4 gap-y-2 border-b border-void-700 bg-void-850 px-5 py-3.5">
        <span className="font-mono text-xs text-ink-300">executeRebalance</span>
        {executor && (
          <a
            href={explorerAddress(executor)}
            target="_blank"
            rel="noreferrer"
            className="font-mono text-2xs text-ink-500 underline-offset-2 hover:text-ink-300 hover:underline"
          >
            {executor.slice(0, 10)}…{executor.slice(-6)} ↗
          </a>
        )}
      </div>

      {chainError ? (
        <div className="px-5 py-6">
          <p className="text-sm text-ink-300">Could not reach the chain to run these.</p>
          <p className="mt-1.5 font-mono text-xs text-ink-500">{chainError}</p>
          <button type="button" onClick={() => void run()} className="btn btn-quiet btn-sm mt-4">
            Try again
          </button>
        </div>
      ) : (
        <>
          <ul className="divide-hair px-5">
            {PROBES.map((probe) => {
              const r = results[probe.id] ?? { status: 'idle' as const };
              return (
                <li key={probe.id} className="py-3.5">
                  <div className="flex flex-wrap items-baseline justify-between gap-x-5 gap-y-1">
                    <span className="text-sm text-ink-200">{probe.label}</span>
                    <span className="font-mono text-xs">
                      {r.status === 'refused' && (
                        <span className={r.detail === probe.expect ? 'text-verified-400' : 'text-amber-300'}>
                          reverted {r.detail}
                        </span>
                      )}
                      {r.status === 'running' && <span className="text-ink-500">running…</span>}
                      {r.status === 'idle' && <span className="text-ink-500">, </span>}
                      {r.status === 'passed' && <span className="text-danger-400">not refused</span>}
                      {r.status === 'error' && <span className="text-amber-300">{r.detail}</span>}
                    </span>
                  </div>
                  <p className="mt-1 text-xs leading-relaxed text-ink-500">{probe.note}</p>
                </li>
              );
            })}
          </ul>

          <div className="border-t border-void-700 bg-void-850 px-5 py-4">
            <p className="text-xs leading-relaxed text-ink-400">
              Each line is a live <span className="font-mono">eth_call</span> against the deployed
              executor, run when this page loaded; not a recording. No wallet, no gas, and the
              signature is sixty-five bytes of nonsense: the contract refuses the instruction before
              it ever looks at who signed it.
            </p>
            {state && (
              <p className="mt-2 font-mono text-2xs text-ink-500">
                last nonce {state.last.toString()} · rate limit {state.used.toString()}/
                {state.limit.toString()} in the rolling 24h
              </p>
            )}
            <button type="button" onClick={() => void run()} className="btn btn-quiet btn-sm mt-3">
              Run them again
            </button>
          </div>
        </>
      )}
    </div>
  );
}

/** viem nests the revert payload differently depending on the transport error. */
function extractRevertData(err: unknown): `0x${string}` | null {
  const e = err as { walk?: (fn: (x: unknown) => boolean) => unknown; cause?: unknown; data?: unknown };
  const fromWalk = e?.walk?.((x) => Boolean((x as { data?: unknown })?.data)) as { data?: unknown } | undefined;
  const candidate =
    (fromWalk?.data as string | undefined) ??
    ((e?.cause as { data?: unknown })?.data as string | undefined) ??
    (e?.data as string | undefined);
  return typeof candidate === 'string' && candidate.startsWith('0x') ? (candidate as `0x${string}`) : null;
}

function shortMessage(err: unknown): string {
  const e = err as { shortMessage?: string; message?: string };
  return (e?.shortMessage ?? e?.message ?? 'unknown error').split('\n')[0].slice(0, 120);
}

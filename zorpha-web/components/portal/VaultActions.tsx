'use client';

import { useState } from 'react';
import {
  useAccount,
  useReadContract,
  useWriteContract,
  useWaitForTransactionReceipt,
} from 'wagmi';
import { erc20Abi, vaultAbi, VAULT_DEPOSITS_ENABLED, explorerTx } from '@/lib/contracts';
import { formatUnits, parseUnits } from '@/lib/format';
import { Callout } from '@/components/ui/Primitives';

/**
 * Deposit / withdraw controls for one vault.
 *
 * Gated behind VAULT_DEPOSITS_ENABLED, which now defaults to on: audit finding
 * V-01 (the yield vault redeeming for zero) is fixed and the contract suite is
 * green. The gate stays in the code as an incident kill switch, see
 * lib/contracts.ts.
 */
export function VaultActions({
  vaultAddress,
  assetAddress,
  assetDecimals = 6,
  assetSymbol = 'USDC',
}: {
  vaultAddress: `0x${string}`;
  assetAddress: `0x${string}`;
  assetDecimals?: number;
  assetSymbol?: string;
}) {
  const { address } = useAccount();
  const [amount, setAmount] = useState('');
  const [mode, setMode] = useState<'deposit' | 'withdraw'>('deposit');

  const { data: assetBalance } = useReadContract({
    abi: erc20Abi,
    address: assetAddress,
    functionName: 'balanceOf',
    args: address ? [address] : undefined,
    query: { enabled: VAULT_DEPOSITS_ENABLED && Boolean(address) },
  });

  const { data: shareBalance } = useReadContract({
    abi: vaultAbi,
    address: vaultAddress,
    functionName: 'balanceOf',
    args: address ? [address] : undefined,
    query: { enabled: VAULT_DEPOSITS_ENABLED && Boolean(address) },
  });

  const { data: allowance } = useReadContract({
    abi: erc20Abi,
    address: assetAddress,
    functionName: 'allowance',
    args: address ? [address, vaultAddress] : undefined,
    query: { enabled: VAULT_DEPOSITS_ENABLED && Boolean(address) },
  });

  const { writeContract, data: txHash, isPending, error } = useWriteContract();
  const { isLoading: confirming } = useWaitForTransactionReceipt({ hash: txHash });

  if (!VAULT_DEPOSITS_ENABLED) {
    return (
      <Callout tone="warn" title="Deposits are paused">
        <p>
          Deposits have been switched off for this deployment. This is a manual kill switch, not a
          known defect, the contract suite is green and the vault layer findings are closed.
        </p>
        <p className="text-xs text-ink-500">
          Everything else on this page is live and read straight from the contract.
        </p>
      </Callout>
    );
  }

  const parsed = parseUnits(amount, mode === 'deposit' ? assetDecimals : 18);
  const needsApproval =
    mode === 'deposit' &&
    parsed !== null &&
    allowance !== undefined &&
    (allowance as bigint) < parsed;

  const busy = isPending || confirming;

  return (
    <div className="card-pad">
      <div className="flex gap-1 rounded-lg border border-void-600 bg-void-950 p-1">
        {(['deposit', 'withdraw'] as const).map((m) => (
          <button
            key={m}
            type="button"
            onClick={() => {
              setMode(m);
              setAmount('');
            }}
            className={`flex-1 rounded-md px-3 py-2 text-sm capitalize transition-colors ${
              mode === m ? 'bg-void-800 text-ink-100' : 'text-ink-400 hover:text-ink-200'
            }`}
          >
            {m}
          </button>
        ))}
      </div>

      <div className="mt-4">
        <div className="flex items-baseline justify-between">
          <label htmlFor="vault-amount" className="stat-label">
            Amount
          </label>
          <span className="font-mono text-2xs text-ink-500">
            balance{' '}
            {mode === 'deposit'
              ? formatUnits(assetBalance as bigint | undefined, assetDecimals, 2)
              : formatUnits(shareBalance as bigint | undefined, 18, 4)}
          </span>
        </div>
        <div className="mt-2 flex gap-2">
          <input
            id="vault-amount"
            className="input"
            inputMode="decimal"
            placeholder="0.00"
            value={amount}
            onChange={(e) => setAmount(e.target.value)}
          />
          <button
            type="button"
            className="btn btn-sm shrink-0"
            onClick={() => {
              const max = mode === 'deposit' ? assetBalance : shareBalance;
              if (max !== undefined) {
                setAmount(formatUnits(max as bigint, mode === 'deposit' ? assetDecimals : 18, 6));
              }
            }}
          >
            Max
          </button>
        </div>
      </div>

      <button
        type="button"
        className="btn-primary mt-4 w-full"
        disabled={busy || parsed === null || parsed === 0n || !address}
        onClick={() => {
          if (parsed === null || !address) return;
          if (needsApproval) {
            writeContract({
              abi: erc20Abi,
              address: assetAddress,
              functionName: 'approve',
              args: [vaultAddress, parsed],
            });
            return;
          }
          writeContract({
            abi: vaultAbi,
            address: vaultAddress,
            functionName: mode === 'deposit' ? 'deposit' : 'redeem',
            args:
              mode === 'deposit' ? [parsed, address] : [parsed, address, address],
          });
        }}
      >
        {busy
          ? 'Confirming…'
          : needsApproval
            ? `Approve ${assetSymbol}`
            : mode === 'deposit'
              ? 'Deposit'
              : 'Withdraw'}
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
  );
}

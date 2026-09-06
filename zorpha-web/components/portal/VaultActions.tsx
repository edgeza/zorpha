'use client';

import { useEffect, useState } from 'react';
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
  assetDecimals: assetDecimalsProp,
  assetSymbol: assetSymbolProp,
}: {
  vaultAddress: `0x${string}`;
  assetAddress: `0x${string}`;
  /** Optional override. Normally read from the token itself. */
  assetDecimals?: number;
  /** Optional override. Normally read from the token itself. */
  assetSymbol?: string;
}) {
  const { address } = useAccount();
  const [amount, setAmount] = useState('');
  const [mode, setMode] = useState<'deposit' | 'withdraw'>('deposit');

  // Read the asset's own decimals and symbol rather than assuming them.
  //
  // These used to default to 6 and 'USDC', and the only call site passed
  // neither. Both equity vaults hold an 18-decimal asset, so on those pages
  // every number was wrong by 10^12 in whichever direction hurt: a balance of
  // one token rendered as 1,000,000,000,000, and typing "1" into the deposit
  // field produced parseUnits("1", 6) = 1e6 against an 18-decimal token --
  // a trillionth of the intended deposit. "Max" filled in a nonsense figure
  // from the same mistake.
  //
  // Reading them is also the only thing that can be right for a
  // leader-launched vault, whose asset is whatever venue the leader chose.
  const { data: readDecimals } = useReadContract({
    abi: erc20Abi,
    address: assetAddress,
    functionName: 'decimals',
  });
  const { data: readSymbol } = useReadContract({
    abi: erc20Abi,
    address: assetAddress,
    functionName: 'symbol',
  });

  // Share decimals are the vault's own, NOT a hardcoded 18: ERC-4626 with a
  // decimal offset reports asset decimals plus the offset, so the spot vault
  // reports 24. Withdrawals are denominated in shares.
  // erc20Abi, not vaultAbi: the vault's shares ARE an ERC-20 and vaultAbi does
  // not declare decimals().
  const { data: readShareDecimals } = useReadContract({
    abi: erc20Abi,
    address: vaultAddress,
    functionName: 'decimals',
  });

  const assetDecimals = assetDecimalsProp ?? (readDecimals as number | undefined);
  const assetSymbol = assetSymbolProp ?? (readSymbol as string | undefined);
  const shareDecimals = readShareDecimals as number | undefined;

  // Until the reads land there is no honest way to parse or format an amount,
  // so the form waits rather than guessing a scale.
  const scalesKnown = assetDecimals !== undefined && shareDecimals !== undefined;

  const { data: assetBalance, refetch: refetchAssetBalance } = useReadContract({
    abi: erc20Abi,
    address: assetAddress,
    functionName: 'balanceOf',
    args: address ? [address] : undefined,
    query: { enabled: VAULT_DEPOSITS_ENABLED && Boolean(address) },
  });

  const { data: shareBalance, refetch: refetchShareBalance } = useReadContract({
    abi: vaultAbi,
    address: vaultAddress,
    functionName: 'balanceOf',
    args: address ? [address] : undefined,
    query: { enabled: VAULT_DEPOSITS_ENABLED && Boolean(address) },
  });

  const { data: allowance, refetch: refetchAllowance } = useReadContract({
    abi: erc20Abi,
    address: assetAddress,
    functionName: 'allowance',
    args: address ? [address, vaultAddress] : undefined,
    query: { enabled: VAULT_DEPOSITS_ENABLED && Boolean(address) },
  });

  const { writeContract, data: txHash, isPending, error, reset } = useWriteContract();
  const { isLoading: confirming, isSuccess: confirmed } = useWaitForTransactionReceipt({
    hash: txHash,
  });

  /**
   * What the transaction in flight actually IS.
   *
   * Depositing takes two transactions and the button used to be the only clue,
   * so an approval that had landed looked exactly like a completed deposit: the
   * same "View transaction" link appeared, and the button still read "Approve"
   * because nothing refetched the allowance. The first deposit anyone attempted
   * on this protocol stopped here -- the approve confirmed on chain, the
   * deposit was never sent, and the page gave no reason to think a second
   * signature was owed.
   */
  const [lastAction, setLastAction] = useState<'approve' | 'deposit' | 'withdraw' | null>(null);

  // The allowance read is the one that MUST refresh: `needsApproval` derives
  // from it, so a stale value pins the form on step one forever.
  useEffect(() => {
    if (!confirmed) return;
    void refetchAllowance();
    void refetchAssetBalance();
    void refetchShareBalance();
  }, [confirmed, refetchAllowance, refetchAssetBalance, refetchShareBalance]);

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

  const parsed = scalesKnown
    ? parseUnits(amount, mode === 'deposit' ? (assetDecimals as number) : (shareDecimals as number))
    : null;
  const needsApproval =
    mode === 'deposit' &&
    parsed !== null &&
    allowance !== undefined &&
    (allowance as bigint) < parsed;

  /**
   * More than the wallet holds.
   *
   * Nothing checked this. `parseUnits` rejects garbage, so a nonsense amount
   * already disabled the button -- but a perfectly well-formed number larger
   * than the balance did not. The deposit was submitted, the token's transfer
   * reverted, and the depositor paid gas to receive a wallet error naming a
   * contract they have never heard of. On the approval path they paid it
   * twice, since the approve itself succeeds and only the deposit behind it
   * fails.
   *
   * The balance is displayed directly above this field and Max fills it in, so
   * the information was always there -- it just was not enforced.
   */
  const spendable = mode === 'deposit' ? assetBalance : shareBalance;
  const exceedsBalance =
    parsed !== null && spendable !== undefined && parsed > (spendable as bigint);

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
              ? formatUnits(assetBalance as bigint | undefined, assetDecimals ?? 18, 2)
              : formatUnits(shareBalance as bigint | undefined, shareDecimals ?? 18, 4)}
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
                setAmount(
                  formatUnits(
                    max as bigint,
                    mode === 'deposit' ? (assetDecimals ?? 18) : (shareDecimals ?? 18),
                    6,
                  ),
                );
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
        disabled={busy || parsed === null || parsed === 0n || !address || exceedsBalance}
        onClick={() => {
          if (parsed === null || !address) return;
          if (needsApproval) {
            reset();
            setLastAction('approve');
            writeContract({
              abi: erc20Abi,
              address: assetAddress,
              functionName: 'approve',
              args: [vaultAddress, parsed],
            });
            return;
          }
          reset();
          setLastAction(mode);
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
            ? `Approve ${assetSymbol ?? 'asset'}, step 1 of 2`
            : mode === 'deposit'
              ? 'Deposit'
              : 'Withdraw'}
      </button>

      {/* Said before the first click, not discovered after it. */}
      {needsApproval && !busy && (
        <p className="mt-2 text-xs leading-relaxed text-ink-500">
          Depositing takes two transactions: one to let the vault move your{' '}
          {assetSymbol ?? 'asset'}, then the deposit itself. Approving on its own moves nothing.
        </p>
      )}

      {exceedsBalance && !busy ? (
        <p className="mt-2 text-xs leading-relaxed text-danger-400">
          That is more than this wallet holds. Use Max for the full{' '}
          {mode === 'deposit' ? (assetSymbol ?? 'asset') : 'share'} balance.
        </p>
      ) : null}

      {error ? (
        <p className="mt-3 text-xs leading-relaxed text-danger-400">
          {error.message.split('\n')[0]}
        </p>
      ) : null}

      {txHash ? (
        <div className="mt-3 flex flex-col gap-1">
          <p className="text-xs leading-relaxed text-ink-400">
            {confirming
              ? lastAction === 'approve'
                ? 'Approving…'
                : lastAction === 'withdraw'
                  ? 'Withdrawing…'
                  : 'Depositing…'
              : confirmed
                ? lastAction === 'approve'
                  ? 'Approved. Nothing has moved yet, press Deposit to send the second transaction.'
                  : lastAction === 'withdraw'
                    ? 'Withdrawn.'
                    : 'Deposited.'
                : null}
          </p>
          <a
            href={explorerTx(txHash)}
            target="_blank"
            rel="noreferrer noopener"
            className="link-quiet inline-block text-xs"
          >
            View {lastAction === 'approve' ? 'approval' : lastAction ?? 'transaction'} ↗
          </a>
        </div>
      ) : null}
    </div>
  );
}

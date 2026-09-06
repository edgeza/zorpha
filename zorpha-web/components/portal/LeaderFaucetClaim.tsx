'use client';

import { useAccount, useReadContracts, useWriteContract, useWaitForTransactionReceipt } from 'wagmi';
import { erc20Abi, formatUnits } from 'viem';
import { contracts, leaderFaucetAbi, isDeployed, explorerUrl } from '@/lib/contracts';
import { isMainnet } from '@/lib/chains';
import { Callout, Mono } from '@/components/ui/Primitives';

/**
 * The entry point to the leader programme for somebody who is not us.
 *
 * WHY THIS COMPONENT EXISTS
 *
 * Launching a vault costs a 10,000 $ZOR bond, and $ZOR has no mint function --
 * the entire supply is minted in the constructor and distributed atomically.
 * There is no testnet mint. So a prospective leader could read the whole
 * recruitment page, agree with every word of it, and then have no way to
 * obtain a bond except messaging the team.
 *
 * That is why the leader programme has had exactly one participant since
 * launch: the person who deployed it.
 *
 * WHAT IT DELIBERATELY DOES NOT DO
 *
 * It does not hide the states it cannot satisfy. If the faucet is undeployed,
 * unfunded, exhausted, or already claimed by this address, it says which --
 * because the alternative is a button that fails with a decoded revert reason
 * the visitor has no way to interpret. The portal already holds this standard
 * elsewhere ("If the indexer is not running, this stays empty rather than
 * showing placeholder data") and this follows it.
 *
 * It also does not hand out ETH for gas. That comes from the chain's own
 * faucet, and saying so is more useful than a claim that half-works.
 */
export function LeaderFaucetClaim() {
  const { address, isConnected } = useAccount();
  const faucet = contracts.leaderFaucet;
  const deployed = isDeployed('leaderFaucet');

  const { data, refetch, isLoading } = useReadContracts({
    // `allowFailure` so one reverting read does not blank the whole panel --
    // `hasClaimed` needs an address and there may not be one yet.
    allowFailure: true,
    contracts: [
      { abi: leaderFaucetAbi, address: faucet, functionName: 'ticket' },
      { abi: leaderFaucetAbi, address: faucet, functionName: 'claimsRemaining' },
      {
        abi: leaderFaucetAbi,
        address: faucet,
        functionName: 'hasClaimed',
        args: [address ?? '0x0000000000000000000000000000000000000000'],
      },
      { abi: erc20Abi, address: contracts.zor, functionName: 'balanceOf', args: [address ?? '0x0000000000000000000000000000000000000000'] },
      { abi: erc20Abi, address: contracts.zor, functionName: 'decimals' },
      { abi: erc20Abi, address: contracts.zor, functionName: 'symbol' },
      // Which deployment this faucet belongs to.
      { abi: leaderFaucetAbi, address: faucet, functionName: 'zor' },
      { abi: leaderFaucetAbi, address: faucet, functionName: 'launcher' },
    ],
    query: { enabled: deployed },
  });

  const { writeContract, data: txHash, isPending, error } = useWriteContract();
  const { isLoading: confirming, isSuccess } = useWaitForTransactionReceipt({ hash: txHash });

  // Nothing at all on mainnet.
  //
  // A faucet handing out 10,000 $ZOR bonds on mainnet would be absurd, so its
  // absence there is the design rather than a gap. Falling through to the
  // "not deployed yet" notice below would tell a mainnet visitor that a
  // feature is missing when it is deliberately not there -- the page would
  // read as unfinished on the one network where it matters most.
  //
  // Returning null rather than a "testnet only" note is deliberate too: a
  // mainnet visitor has no use for the information that a testnet convenience
  // exists elsewhere.
  if (isMainnet) return null;

  if (!deployed) {
    return (
      <Callout tone="warn" title="The bond faucet is not deployed yet">
        <p>
          Launching a vault needs a 10,000 $ZOR bond, and $ZOR has no mint function; the whole
          supply is minted at deploy. Until the faucet is live on this network, a bond has to come
          from governance directly.
        </p>
      </Callout>
    );
  }

  const ticket = data?.[0]?.status === 'success' ? data[0].result : undefined;
  const remaining = data?.[1]?.status === 'success' ? data[1].result : undefined;
  const claimed = data?.[2]?.status === 'success' ? data[2].result : undefined;
  const zorBalance = data?.[3]?.status === 'success' ? data[3].result : undefined;
  const zorDecimals = data?.[4]?.status === 'success' ? data[4].result : 18;
  const zorSymbol = data?.[5]?.status === 'success' ? data[5].result : 'ZOR';

  const bond = ticket?.[0];
  const fmt = (v?: bigint) =>
    v === undefined ? ', ' : Number(formatUnits(v, zorDecimals)).toLocaleString('en-US');

  const faucetZor = data?.[6]?.status === 'success' ? data[6].result : undefined;
  const faucetLauncher = data?.[7]?.status === 'success' ? data[7].result : undefined;

  // A faucet left over from an earlier deployment answers every other call on
  // this panel happily. It reports a bond, a seed and claims remaining, and the
  // claim itself succeeds -- while paying out a $ZOR the current launcher will
  // not accept. The balance above never moves, because it is read from the
  // CURRENT token, and the launch the bond was for reverts.
  //
  // That is the exact shape this component was written to refuse. It already
  // names undeployed, unfunded, exhausted and already-claimed; a faucet wired
  // to a superseded deployment belongs on that list, and it survived a real
  // testnet relaunch precisely because it was not.
  const sameAddr = (a?: string, b?: string) =>
    !!a && !!b && a.toLowerCase() === b.toLowerCase();
  const wrong: string[] = [];
  if (faucetZor !== undefined && !sameAddr(faucetZor, contracts.zor)) wrong.push('$ZOR token');
  if (faucetLauncher !== undefined && !sameAddr(faucetLauncher, contracts.vaultLauncher))
    wrong.push('vault launcher');

  if (wrong.length > 0) {
    return (
      <Callout tone="warn" title="The bond faucet belongs to an older deployment">
        <p>
          It is holding the {wrong.join(' and the ')} from a previous release, so a claim here
          would pay a bond this network&rsquo;s launcher will not accept: the claim succeeds, your
          balance does not move, and the launch reverts. Nothing on this page can fix that, so it
          is refusing rather than half-working.
        </p>
        <p>
          Governance needs to redeploy the faucet against the current contracts, or issue a bond
          directly. Faucet <Mono>{faucet}</Mono>.
        </p>
      </Callout>
    );
  }

  const alreadyHasBond = bond !== undefined && zorBalance !== undefined && zorBalance >= bond;
  const exhausted = remaining !== undefined && remaining === 0n;

  return (
    <div className="card flex flex-col gap-4 p-5">
      <div>
        <h3 className="font-semibold tracking-tight">Get a testnet bond</h3>
        <p className="mt-2 max-w-prose text-sm leading-relaxed text-ink-400">
          One bond and one seed per address, once. The bond is refundable through{' '}
          <Mono>reclaimBond</Mono> when your vault is empty, and forfeitable by governance for
          misconduct; a market drawdown is not misconduct.
        </p>
      </div>

      <dl className="grid grid-cols-2 gap-x-6 gap-y-3 border-y border-void-800 py-3 text-sm sm:grid-cols-3">
        <div>
          <dt className="stat-label">Bond</dt>
          <dd className="mt-0.5 font-mono tabular-nums">
            {fmt(bond)} {zorSymbol}
          </dd>
        </div>
        <div>
          <dt className="stat-label">Seed</dt>
          <dd className="mt-0.5 font-mono tabular-nums">
            {ticket?.[1] === undefined ? ', ' : Number(formatUnits(ticket[1], 6)).toLocaleString('en-US')} tUSDG
          </dd>
        </div>
        <div>
          <dt className="stat-label">Claims left</dt>
          <dd className="mt-0.5 font-mono tabular-nums">
            {remaining === undefined ? ', ' : remaining.toString()}
          </dd>
        </div>
      </dl>

      {/* Every state the button cannot satisfy, named. */}
      {!isConnected ? (
        <p className="text-sm text-ink-400">Connect a wallet to claim.</p>
      ) : isSuccess ? (
        <Callout tone="verified" title="Bond received">
          <p>
            You hold a bond and a seed. Next: <a href="/portal/leaders/launch">launch a vault</a>.
            {txHash && (
              <>
                {' '}
                <a href={`${explorerUrl}/tx/${txHash}`} target="_blank" rel="noreferrer">
                  View the transaction
                </a>
                .
              </>
            )}
          </p>
        </Callout>
      ) : claimed ? (
        <Callout tone="info" title="This address has already claimed">
          <p>
            One per address, enforced on chain. You currently hold{' '}
            <Mono>
              {fmt(zorBalance)} {zorSymbol}
            </Mono>
            . If you have already spent the bond on a vault, reclaim it with{' '}
            <Mono>reclaimBond</Mono> once that vault is empty.
          </p>
        </Callout>
      ) : exhausted ? (
        <Callout tone="warn" title="The faucet is out">
          <p>
            Either every claim has been taken or the float needs topping up. Both are governance
            actions; the number above is read from the contract, bounded by its actual balance
            rather than its cap, so it is not stale.
          </p>
        </Callout>
      ) : alreadyHasBond ? (
        <Callout tone="info" title="You already hold enough for a bond">
          <p>
            Your balance of{' '}
            <Mono>
              {fmt(zorBalance)} {zorSymbol}
            </Mono>{' '}
            already covers the bond, so claiming would only take a ticket somebody else needs.{' '}
            <a href="/portal/leaders/launch">Launch a vault</a> instead.
          </p>
        </Callout>
      ) : (
        <div className="flex flex-col gap-2">
          <button
            type="button"
            className="btn-primary self-start"
            disabled={isPending || confirming || isLoading}
            onClick={() =>
              writeContract({
                abi: leaderFaucetAbi,
                address: faucet,
                functionName: 'claim',
              })
            }
          >
            {isPending ? 'Confirm in wallet…' : confirming ? 'Claiming…' : 'Claim a bond'}
          </button>
          <p className="text-xs text-ink-500">
            You will also need a little testnet ETH for gas. This faucet does not provide it , 
            that comes from Robinhood Chain&rsquo;s own faucet.
          </p>
        </div>
      )}

      {error && (
        <Callout tone="warn" title="The claim did not go through">
          <p className="break-words font-mono text-xs">{error.message.slice(0, 300)}</p>
          <p>
            <button type="button" className="underline" onClick={() => refetch()}>
              Re-read the faucet
            </button>{' '}
            and try again.
          </p>
        </Callout>
      )}
    </div>
  );
}

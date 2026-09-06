'use client';

import { useCallback, useEffect, useMemo, useState } from 'react';
import { erc20Abi, formatUnits } from 'viem';
import type { Address } from 'viem';
import {
  useAccount,
  useReadContracts,
  useWriteContract,
  useWaitForTransactionReceipt,
} from 'wagmi';
import { activeChain } from '@/lib/chains';
import { contracts, explorerAddress, explorerTx } from '@/lib/contracts';
import {
  spotVaultAbi,
  rotationVaultAbi,
  yieldVaultAbi,
  vaultCommonAbi,
  oracleAbi,
  launcherManagerAbi,
} from '@/lib/manager-abi';
import {
  ROLE,
  ROLE_LABEL,
  ROLE_POWER,
  factoryVaults,
  hasLauncher,
  humanDuration,
  oracleState,
  type RoleKey,
  type TerminalVault,
  type VaultKind,
} from '@/lib/vault-terminal';
import { Callout, Mono } from '@/components/ui/Primitives';
import { WalletButton } from '@/components/portal/WalletButton';
import { SpotRebalance, RotationRebalance, YieldRebalance } from './RebalancePanel';
import { LeaderActions } from './LeaderActions';
import { VaultBook } from './VaultBook';

/**
 * The manager terminal.
 *
 * Everything a vault operator is permitted to do, in one place, with the state
 * needed to choose between those things; and an honest account of the things
 * they are not permitted to do, because on this protocol that list is longer
 * than people expect and silence about it reads as a bug.
 *
 * WHAT THIS IS NOT
 *
 * It is not a trading screen. A manager cannot buy, sell, pick an asset or
 * pick a venue. The whole of their discretion is one call to `rebalanceTo`
 * inside a slippage bound, and that narrowness is the product: a track record
 * only means something because the mandate is enforced rather than promised.
 * A free-form terminal here would be a manager who could rug, which would make
 * every receipt this protocol produces worthless.
 */

const ZERO = '0x0000000000000000000000000000000000000000' as const;
const ABI_FOR: Record<VaultKind, typeof spotVaultAbi | typeof rotationVaultAbi | typeof yieldVaultAbi> = {
  spot: spotVaultAbi,
  rotation: rotationVaultAbi,
  yield: yieldVaultAbi,
};

function num(v: unknown): bigint | undefined {
  return typeof v === 'bigint' ? v : undefined;
}

function Stat({ label, value, hint }: { label: string; value: React.ReactNode; hint?: string }) {
  return (
    <div>
      <dt className="stat-label">{label}</dt>
      <dd className="mt-0.5 font-mono text-sm tabular-nums">{value}</dd>
      {hint && <p className="mt-0.5 text-xs leading-snug text-ink-500">{hint}</p>}
    </div>
  );
}

export function ManagerTerminal() {
  const { address, isConnected, chainId } = useAccount();
  const wrongChain = isConnected && chainId !== activeChain.id;

  const factory = useMemo(() => factoryVaults(), []);
  const [selectedKey, setSelectedKey] = useState<string>(factory[0]?.key ?? '');

  // Vaults this address launched. A leader holds no ROLE on their vault, but
  // they do hold `reallocate` and `reclaimBond`, so their vaults belong here.
  const { data: launchedIds } = useReadContracts({
    allowFailure: true,
    contracts: [
      {
        address: contracts.vaultLauncher as Address,
        abi: launcherManagerAbi,
        functionName: 'launchesOfLeader',
        args: [address ?? ZERO],
        chainId: activeChain.id,
      },
    ],
    query: { enabled: Boolean(address) && hasLauncher() },
  });

  const leaderLaunchIds = useMemo(() => {
    const r = launchedIds?.[0];
    return r?.status === 'success' && Array.isArray(r.result) ? (r.result as bigint[]) : [];
  }, [launchedIds]);

  const { data: launchedSummaries } = useReadContracts({
    allowFailure: true,
    contracts: leaderLaunchIds.map((id) => ({
      address: contracts.vaultLauncher as Address,
      abi: launcherManagerAbi,
      functionName: 'vaultSummary' as const,
      args: [id],
      chainId: activeChain.id,
    })),
    query: { enabled: leaderLaunchIds.length > 0 },
  });

  const launchedVaults: (TerminalVault & { launchId: bigint })[] = useMemo(() => {
    if (!launchedSummaries) return [];
    return launchedSummaries.flatMap((r, i) => {
      if (r.status !== 'success' || !Array.isArray(r.result)) return [];
      const vaultAddr = r.result[0] as Address;
      const id = leaderLaunchIds[i];
      return [
        {
          key: `launch-${id}`,
          kind: 'yield' as const,
          address: vaultAddr,
          name: `Your vault #${id}`,
          decision: 'Which approved venue the vault points at.',
          launchId: id,
        },
      ];
    });
  }, [launchedSummaries, leaderLaunchIds]);

  const allVaults: TerminalVault[] = useMemo(
    () => [...factory, ...launchedVaults],
    [factory, launchedVaults],
  );

  // A leader holds no ROLE on the vault they launched -- the launcher hands
  // every role to governance at launch, which is precisely why a leader
  // cannot move depositor funds. Reading roles alone would therefore label
  // their own vault "view only", so leadership is carried separately.
  const leaderKeys = useMemo(
    () => new Set(launchedVaults.map((v) => v.key)),
    [launchedVaults],
  );

  const selected = allVaults.find((v) => v.key === selectedKey) ?? allVaults[0];

  // --- reads for the selected vault ---------------------------------------

  const abi = selected ? ABI_FOR[selected.kind] : vaultCommonAbi;
  const base = selected
    ? { address: selected.address, abi, chainId: activeChain.id }
    : undefined;

  const {
    data: common,
    refetch: refetchCommon,
    isLoading,
  } = useReadContracts({
    allowFailure: true,
    contracts: base
      ? [
          { ...base, functionName: 'asset' },
          { ...base, functionName: 'symbol' },
          { ...base, functionName: 'totalAssets' },
          { ...base, functionName: 'totalSupply' },
          { ...base, functionName: 'getNavPerShare' },
          { ...base, functionName: 'rebalanceCount' },
          { ...base, functionName: 'performanceFee' },
          { ...base, functionName: 'performanceFeeAccrued' },
          { ...base, functionName: 'highWaterMark' },
          { ...base, functionName: 'feeRecipient' },
          { ...base, functionName: 'isCircuitBreakerActive' },
          { ...base, functionName: 'hasRole', args: [ROLE.admin, address ?? ZERO] },
          { ...base, functionName: 'hasRole', args: [ROLE.keeper, address ?? ZERO] },
          { ...base, functionName: 'hasRole', args: [ROLE.riskCouncil, address ?? ZERO] },
          { ...base, functionName: 'hasRole', args: [ROLE.adapterSetter, address ?? ZERO] },
          // SHARE decimals, which are not 18 and not the asset's. ERC4626 adds a
          // decimals offset, so the live vaults report 24, 24 and 12.
          { ...base, functionName: 'decimals' },
        ]
      : [],
    query: { enabled: Boolean(base), refetchInterval: 15_000 },
  });

  const g = (i: number) => (common?.[i]?.status === 'success' ? common[i].result : undefined);

  const assetAddr = g(0) as Address | undefined;
  const vaultSymbol = g(1) as string | undefined;
  const totalAssets = num(g(2));
  const totalSupply = num(g(3));
  const navPerShare = num(g(4));
  const rebalanceCount = num(g(5));
  const performanceFee = num(g(6));
  const feeAccrued = num(g(7));
  const highWaterMark = num(g(8));
  const feeRecipient = g(9) as Address | undefined;
  const halted = g(10) === true;

  const roles: Record<RoleKey, boolean> = {
    admin: g(11) === true,
    keeper: g(12) === true,
    riskCouncil: g(13) === true,
    adapterSetter: g(14) === true,
  };

  // Asset metadata. Kept in its own hook rather than appended to the vault
  // reads: `useReadContracts` infers one ABI across the whole array, so mixing
  // erc20Abi with a vault ABI in a single call makes the union unresolvable
  // and every entry fails to typecheck.
  const { data: meta, refetch: refetchMeta } = useReadContracts({
    allowFailure: true,
    contracts:
      selected && assetAddr
        ? [
            { address: assetAddr, abi: erc20Abi, functionName: 'decimals' as const, chainId: activeChain.id },
            { address: assetAddr, abi: erc20Abi, functionName: 'symbol' as const, chainId: activeChain.id },
            { address: assetAddr, abi: erc20Abi, functionName: 'balanceOf' as const, args: [selected.address], chainId: activeChain.id },
          ]
        : [],
    query: { enabled: Boolean(selected && assetAddr), refetchInterval: 15_000 },
  });

  const m = (i: number) => (meta?.[i]?.status === 'success' ? meta[i].result : undefined);
  const rawDecimals = m(0);
  const assetDecimals = typeof rawDecimals === 'number' ? rawDecimals : 18;
  const assetSymbol = typeof m(1) === 'string' ? (m(1) as string) : '';
  const vaultAssetBalance = num(m(2)) ?? 0n;

  // ─── Units ──────────────────────────────────────────────────────────────
  //
  // Three different scales are in play and only one of them is the asset's.
  // Every field below used to be formatted with a hardcoded 18.
  //
  //   SHARE decimals: ERC-4626 applies a decimals offset, so the live vaults
  //   report 24, 24 and 12 -- never 18. Formatting totalSupply at 18 overstated
  //   the spot and rotation share count by 10^6 and understated the yield
  //   vault's by the same factor.
  //
  //   NAV decimals: navPerShare and highWaterMark are denominated in the
  //   vault's ACCOUNTING unit, which is asset() on spot and yield but
  //   baseAsset() on a rotation basket -- asset() there is tokens[0], the
  //   equity. On the live rotation vault the accounting unit is 6 decimals, so
  //   an 18 rendered a NAV of 1.000000 as 0.000000 and a manager reading the
  //   terminal saw a vault that had lost everything.
  //
  // Fallbacks are the previous behaviour rather than a guess, so a failed read
  // degrades to what shipped instead of to a confidently wrong number.
  const rawShareDecimals = g(15);
  const shareDecimals = typeof rawShareDecimals === 'number' ? rawShareDecimals : 18;


  // The kind-specific reads, all against the same vault ABI.
  const kindFns: readonly string[] =
    selected?.kind === 'spot'
      ? ['targetWeightBps', 'rebalanceThresholdBps', 'maxSlippageBps', 'grossValue', 'maxOracleStaleness', 'oracle']
      : selected?.kind === 'rotation'
        ? ['basketLength', 'maxOracleStaleness', 'grossValue', 'oracles', 'baseDecimals']
        : selected?.kind === 'yield'
          ? ['rawAssets', 'heldAssets', 'adapter', 'firstLossEscrow']
          : [];

  const { data: extra, refetch: refetchExtra } = useReadContracts({
    allowFailure: true,
    contracts: base
      ? kindFns.map((fn) => ({
          ...base,
          functionName: fn,
          // `oracles` is an array accessor and needs an index; the rest take
          // no argument. Passing args to a zero-arg function is a revert.
          ...(fn === 'oracles' ? { args: [0n] } : {}),
        }))
      : [],
    query: { enabled: Boolean(base) && kindFns.length > 0, refetchInterval: 15_000 },
  });

  const e = (i: number) => (extra?.[i]?.status === 'success' ? extra[i].result : undefined);

  // Placed here, not with shareDecimals: it reads the rotation vault's
  // baseDecimals out of the kind-specific results, which are declared above.
  const rotBaseDecimals = selected?.kind === 'rotation' ? e(4) : undefined;
  const navDecimals = typeof rotBaseDecimals === 'number' ? rotBaseDecimals : assetDecimals;

  const spotTarget = selected?.kind === 'spot' ? Number(e(0) ?? 0) : 0;
  const spotThreshold = selected?.kind === 'spot' ? Number(e(1) ?? 0) : 0;
  const spotSlippage = selected?.kind === 'spot' ? Number(e(2) ?? 0) : 0;
  const spotGross = selected?.kind === 'spot' ? (num(e(3)) ?? 0n) : 0n;
  const spotStaleness = selected?.kind === 'spot' ? num(e(4)) : undefined;
  const spotOracleAddr = selected?.kind === 'spot' ? (e(5) as Address | undefined) : undefined;

  const rotLength = selected?.kind === 'rotation' ? Number(e(0) ?? 0) : 0;
  const rotStaleness = selected?.kind === 'rotation' ? num(e(1)) : undefined;
  const rotOracleAddr = selected?.kind === 'rotation' ? (e(3) as Address | undefined) : undefined;

  const yieldHeld = selected?.kind === 'yield' ? (num(e(1)) ?? 0n) : 0n;
  const yieldAdapter = selected?.kind === 'yield' ? (e(2) as Address | undefined) : undefined;

  // Rotation basket legs.
  const { data: basket } = useReadContracts({
    allowFailure: true,
    contracts:
      selected?.kind === 'rotation' && rotLength > 0
        ? Array.from({ length: rotLength }).flatMap((_, i) => [
            { ...base!, functionName: 'tokens' as const, args: [BigInt(i)] },
            { ...base!, functionName: 'targetWeightsBps' as const, args: [BigInt(i)] },
          ])
        : [],
    query: { enabled: selected?.kind === 'rotation' && rotLength > 0 },
  });

  const legTokens = useMemo(() => {
    if (!basket) return [];
    return Array.from({ length: rotLength }).map((_, i) => {
      const t = basket[i * 2];
      return t?.status === 'success' ? (t.result as Address) : undefined;
    });
  }, [basket, rotLength]);

  const legWeights = useMemo(() => {
    if (!basket) return [];
    return Array.from({ length: rotLength }).map((_, i) => {
      const w = basket[i * 2 + 1];
      return w?.status === 'success' ? Number(w.result) : 0;
    });
  }, [basket, rotLength]);

  const { data: legSymbols } = useReadContracts({
    allowFailure: true,
    contracts: legTokens
      .filter((t): t is Address => Boolean(t))
      .map((t) => ({ address: t, abi: erc20Abi, functionName: 'symbol' as const, chainId: activeChain.id })),
    query: { enabled: legTokens.length > 0 },
  });

  const legSymbolList = useMemo(
    () =>
      (legSymbols ?? []).map((r, i) =>
        r.status === 'success' ? (r.result as string) : `Leg ${i + 1}`,
      ),
    [legSymbols],
  );

  // Oracle freshness. Spot and rotation both revert on a stale price; yield
  // never reads a price at all, so it is deliberately left undefined there.
  //
  // Read from the VAULT rather than from a global address in the environment:
  // each vault holds its own immutable oracle reference, and a rotation vault
  // holds one per basket leg. Trusting an env var here would report freshness
  // for a feed the vault does not actually consume.
  const oracleAddress = spotOracleAddr ?? rotOracleAddr;

  const { data: oracleData } = useReadContracts({
    allowFailure: true,
    contracts:
      oracleAddress && oracleAddress !== ZERO
        ? [{ address: oracleAddress, abi: oracleAbi, functionName: 'latestRoundData' as const, chainId: activeChain.id }]
        : [],
    query: { enabled: Boolean(oracleAddress && oracleAddress !== ZERO), refetchInterval: 15_000 },
  });

  const [now, setNow] = useState(() => Math.floor(Date.now() / 1000));
  useEffect(() => {
    const t = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 1000);
    return () => clearInterval(t);
  }, []);

  const updatedAt = useMemo(() => {
    const r = oracleData?.[0];
    if (r?.status !== 'success' || !Array.isArray(r.result)) return undefined;
    return r.result[3] as bigint;
  }, [oracleData]);

  const oracle = oracleState(
    updatedAt,
    selected?.kind === 'yield' ? undefined : (spotStaleness ?? rotStaleness),
    now,
  );

  const refetchAll = useCallback(() => {
    void refetchCommon();
    void refetchExtra();
    void refetchMeta();
  }, [refetchCommon, refetchExtra, refetchMeta]);

  // --- fee and breaker actions --------------------------------------------

  const { writeContract, data: actionHash, isPending: actionPending, error: actionError, reset } =
    useWriteContract();
  const { isLoading: actionConfirming, isSuccess: actionDone } = useWaitForTransactionReceipt({
    hash: actionHash,
  });
  useEffect(() => {
    if (actionDone) refetchAll();
  }, [actionDone, refetchAll]);
  const actionBusy = actionPending || actionConfirming;

  // --- render --------------------------------------------------------------

  if (!factory.length && !hasLauncher()) {
    return (
      <Callout tone="warn" title="No vaults are configured in this environment">
        <p>
          The terminal reads vault addresses from the build&rsquo;s environment. None are set, so
          there is nothing to operate here.
        </p>
      </Callout>
    );
  }

  // Disconnected still shows the book. The page used to render nothing but a
  // connect prompt, so the honest answer to "what can I operate here?" was
  // unavailable until you had already committed a wallet to finding out. The
  // vaults and their balances are public; only the question of which are YOURS
  // needs an address, and the book says so in place of the role column.
  if (!isConnected) {
    return (
      <div className="flex flex-col gap-6">
        <VaultBook
          vaults={allVaults}
          leaderKeys={leaderKeys}
          selectedKey={selected?.key}
          onSelect={setSelectedKey}
        />
        <div className="card flex flex-col items-start gap-4 p-6">
          <div>
            <h2 className="font-semibold tracking-tight">Connect to operate</h2>
            <p className="mt-2 max-w-prose text-sm leading-relaxed text-ink-400">
              The terminal reads your roles from the chain and shows you exactly the actions your
              address can take. Nothing is enabled on a hunch.
            </p>
          </div>
          <WalletButton />
        </div>
      </div>
    );
  }

  if (wrongChain) {
    return (
      <Callout tone="warn" title={`Switch to ${activeChain.name}`}>
        <p>
          Your wallet is on chain {chainId}. The vaults live on {activeChain.name} (
          {activeChain.id}).
        </p>
      </Callout>
    );
  }

  const heldRoles = (Object.keys(roles) as RoleKey[]).filter((r) => roles[r]);
  const selectedLaunch = launchedVaults.find((v) => v.key === selected?.key);
  const isLeaderVault = Boolean(selectedLaunch);

  const reasonCannotKeep = roles.keeper
    ? null
    : isLeaderVault
      ? 'Launching a vault does not grant a role on it. The launcher gives DEFAULT_ADMIN, KEEPER_ROLE and RISK_COUNCIL_ROLE to governance at launch; which is why a leader cannot move depositor funds. Your powers over this vault are reallocate and reclaimBond.'
      : 'This address does not hold KEEPER_ROLE on this vault.';

  return (
    <div className="flex flex-col gap-6">
      {/* The book. Replaces a row of name-only pills that required clicking
          each one to learn anything about it. */}
      <VaultBook
        vaults={allVaults}
        address={address}
        leaderKeys={leaderKeys}
        selectedKey={selected?.key}
        onSelect={setSelectedKey}
      />

      {!selected ? (
        <Callout tone="warn" title="No vault is configured in this build">
          <p>
            The terminal lists vaults from the addresses baked into the build, and this one has
            none. That is a deployment setting rather than anything about your wallet; the
            banner at the top of the portal names exactly which addresses are missing.
          </p>
        </Callout>
      ) : (
        <>
          {/* Position */}
          <section className="card p-5">
            <div className="mb-4 flex flex-wrap items-baseline justify-between gap-2">
              <h2 className="font-semibold tracking-tight">
                {vaultSymbol ?? selected.name}{' '}
                <span className="ml-1 text-sm font-normal text-ink-500">position</span>
              </h2>
              <a
                href={explorerAddress(selected.address)}
                target="_blank"
                rel="noreferrer"
                className="link-quiet text-xs"
              >
                {selected.address.slice(0, 10)}…{selected.address.slice(-8)}
              </a>
            </div>

            <dl className="grid grid-cols-2 gap-x-6 gap-y-4 sm:grid-cols-3 lg:grid-cols-4">
              <Stat
                label="NAV / share"
                value={navPerShare === undefined ? ', ' : Number(formatUnits(navPerShare, navDecimals)).toFixed(6)}
              />
              <Stat
                label="Total assets"
                value={
                  totalAssets === undefined
                    ? ', '
                    : `${Number(formatUnits(totalAssets, assetDecimals)).toLocaleString('en-US', { maximumFractionDigits: 2 })} ${assetSymbol}`
                }
              />
              <Stat
                label="Shares"
                value={totalSupply === undefined ? ', ' : Number(formatUnits(totalSupply, shareDecimals)).toLocaleString('en-US', { maximumFractionDigits: 2 })}
              />
              <Stat label="Rebalances" value={rebalanceCount?.toString() ?? ', '} />
              <Stat
                label="Performance fee"
                value={performanceFee === undefined ? ', ' : `${Number(performanceFee) / 100}%`}
                hint="Charged only above the high-water mark."
              />
              <Stat
                label="Fee accrued"
                value={
                  feeAccrued === undefined
                    ? ', '
                    : `${Number(formatUnits(feeAccrued, assetDecimals)).toLocaleString('en-US', { maximumFractionDigits: 4 })} ${assetSymbol}`
                }
              />
              <Stat
                label="High-water mark"
                value={highWaterMark === undefined ? ', ' : Number(formatUnits(highWaterMark, navDecimals)).toFixed(6)}
              />
              <Stat
                label="Deposits"
                value={halted ? 'Halted' : 'Open'}
                hint={halted ? 'The circuit breaker is on.' : undefined}
              />
            </dl>
          </section>

          {/* Guard rails */}
          <section className="card p-5">
            <h2 className="mb-1 font-semibold tracking-tight">Guard rails</h2>
            <p className="mb-4 max-w-prose text-sm leading-relaxed text-ink-400">
              Set at deploy and enforced by the contract on every rebalance. A manager cannot
              widen any of them.
            </p>
            <dl className="grid grid-cols-2 gap-x-6 gap-y-4 sm:grid-cols-4">
              {selected.kind === 'spot' && (
                <>
                  <Stat
                    label="Rebalance threshold"
                    value={`${(spotThreshold / 100).toFixed(2)}%`}
                    hint="Smaller moves write the target and do not trade."
                  />
                  <Stat
                    label="Max slippage"
                    value={`${(spotSlippage / 100).toFixed(2)}%`}
                    hint="The swap must clear this floor or it reverts."
                  />
                </>
              )}
              <Stat
                label="Oracle"
                value={
                  oracle.status === 'unknown'
                    ? ', '
                    : oracle.status === 'stale'
                      ? 'Stale'
                      : `Fresh, ${humanDuration(oracle.expiresInSeconds)} left`
                }
                hint={
                  oracle.status === 'stale'
                    ? 'Every rebalance reverts until the next report.'
                    : oracle.status === 'expiring'
                      ? 'Close to expiry, start now or wait for the next report.'
                      : undefined
                }
              />
              <Stat
                label="Fee recipient"
                value={
                  feeRecipient && feeRecipient !== ZERO ? (
                    <a href={explorerAddress(feeRecipient)} target="_blank" rel="noreferrer" className="link-quiet">
                      {feeRecipient.slice(0, 6)}…{feeRecipient.slice(-4)}
                    </a>
                  ) : (
                    ', '
                  )
                }
              />
              {selected.kind === 'yield' && yieldAdapter && (
                <Stat
                  label="Venue"
                  value={
                    <a href={explorerAddress(yieldAdapter)} target="_blank" rel="noreferrer" className="link-quiet">
                      {yieldAdapter.slice(0, 6)}…{yieldAdapter.slice(-4)}
                    </a>
                  }
                  hint="Changing this is timelocked."
                />
              )}
            </dl>
          </section>

          {/* Rebalance */}
          <section className="card p-5">
            <h2 className="mb-1 font-semibold tracking-tight">Rebalance</h2>
            <p className="mb-4 max-w-prose text-sm leading-relaxed text-ink-400">
              {selected.decision}
            </p>

            {isLoading ? (
              <p className="text-sm text-ink-500">Reading the vault…</p>
            ) : selected.kind === 'spot' ? (
              <SpotRebalance
                vault={selected.address}
                canKeep={roles.keeper}
                reasonCannot={reasonCannotKeep}
                halted={halted}
                oracle={oracle}
                assetSymbol={assetSymbol}
                assetDecimals={assetDecimals}
                grossValue={spotGross}
                currentAsset={vaultAssetBalance}
                targetWeightBps={spotTarget}
                thresholdBps={spotThreshold}
                slippageBps={spotSlippage}
                onDone={refetchAll}
              />
            ) : selected.kind === 'rotation' ? (
              <RotationRebalance
                vault={selected.address}
                canKeep={roles.keeper}
                reasonCannot={reasonCannotKeep}
                halted={halted}
                oracle={oracle}
                assetSymbol={assetSymbol}
                assetDecimals={assetDecimals}
                weights={legWeights}
                symbols={legSymbolList}
                onDone={refetchAll}
              />
            ) : (
              <YieldRebalance
                vault={selected.address}
                canKeep={roles.keeper}
                reasonCannot={reasonCannotKeep}
                halted={halted}
                oracle={oracle}
                assetSymbol={assetSymbol}
                assetDecimals={assetDecimals}
                atVenue={yieldHeld}
                navPerShare={navPerShare}
                rebalanceCount={rebalanceCount}
                onDone={refetchAll}
              />
            )}
          </section>

          {/* Other permitted actions */}
          <section className="card p-5">
            <h2 className="mb-1 font-semibold tracking-tight">Other actions</h2>
            <p className="mb-4 max-w-prose text-sm leading-relaxed text-ink-400">
              Each is enabled only if this address holds the role the contract requires.
            </p>

            {actionError && (
              <Callout tone="danger" title="The transaction was rejected">
                <p className="break-words">{actionError.message.split('\n')[0]}</p>
              </Callout>
            )}
            {actionDone && actionHash && (
              <Callout tone="verified" title="Done">
                <p>
                  <a href={explorerTx(actionHash)} target="_blank" rel="noreferrer">
                    View the transaction
                  </a>
                  .
                </p>
              </Callout>
            )}

            <div className="mt-4 flex flex-wrap gap-3">
              <button
                type="button"
                className="btn btn-quiet"
                disabled={!roles.keeper || actionBusy}
                title={roles.keeper ? undefined : 'Needs KEEPER_ROLE'}
                onClick={() => {
                  reset();
                  writeContract({ abi: vaultCommonAbi, address: selected.address, functionName: 'evaluateFees' });
                }}
              >
                Mark fees to the high-water mark
              </button>

              <button
                type="button"
                className="btn btn-quiet"
                disabled={!roles.riskCouncil || actionBusy}
                title={roles.riskCouncil ? undefined : 'Needs RISK_COUNCIL_ROLE'}
                onClick={() => {
                  reset();
                  writeContract({
                    abi: vaultCommonAbi,
                    address: selected.address,
                    functionName: 'setCircuitBreaker',
                    args: [!halted],
                  });
                }}
              >
                {halted ? 'Lift the halt on deposits' : 'Halt deposits'}
              </button>
            </div>
          </section>

          {selectedLaunch && (
            <LeaderActions
              shareDecimals={shareDecimals}
              launchId={selectedLaunch.launchId}
              vaultTotalSupply={totalSupply}
              currentTarget={yieldAdapter}
            />
          )}

          {/* Roles */}
          <section className="card p-5">
            <h2 className="mb-1 font-semibold tracking-tight">What this address can do</h2>
            <p className="mb-4 max-w-prose text-sm leading-relaxed text-ink-400">
              Read from the vault&rsquo;s own <Mono>hasRole</Mono>, not inferred.
            </p>

            {heldRoles.length === 0 ? (
              <Callout tone="info" title="No roles on this vault">
                <p>
                  {isLeaderVault
                    ? 'You launched this vault, which does not grant a role on it. The launcher hands DEFAULT_ADMIN, KEEPER_ROLE and RISK_COUNCIL_ROLE to governance so that a leader cannot move depositor funds. What you keep is reallocate, moving between approved venues; and reclaimBond once the vault is empty.'
                    : 'This address holds no role on this vault, so every action above is disabled. That is the expected state for a depositor.'}
                </p>
              </Callout>
            ) : (
              <ul className="flex flex-col gap-2">
                {heldRoles.map((r) => (
                  <li key={r} className="flex flex-col gap-0.5 border-l-2 border-void-700 pl-3">
                    <span className="text-sm font-semibold">{ROLE_LABEL[r]}</span>
                    <span className="text-sm text-ink-400">{ROLE_POWER[r]}</span>
                  </li>
                ))}
              </ul>
            )}
          </section>
        </>
      )}
    </div>
  );
}

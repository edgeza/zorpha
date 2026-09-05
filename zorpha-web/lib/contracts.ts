/**
 * Zorpha contract address + ABI registry.
 *
 * IMPORTANT, why every lookup below is a literal `process.env.NEXT_PUBLIC_X`:
 *
 * Next.js inlines client-side env vars with a webpack DefinePlugin pass that
 * only rewrites *statically analysable* member expressions. A previous revision
 * of this file read addresses through a helper as `process.env[name]` with a
 * variable key. That is not statically analysable, so nothing was substituted,
 * `process.env` was an empty object in the browser bundle, and every single
 * address silently fell back to `0x0000…0000`, meaning the token page and the
 * airdrop claim were reading state from the zero address in production while
 * looking perfectly healthy in dev (where the real `process.env` exists).
 *
 * Do not reintroduce a dynamic key here. Add a new literal line instead.
 */

import { erc20Abi, erc4626Abi } from 'viem';

export const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000' as const;

function normalise(value: string | undefined): `0x${string}` {
  if (!value) return ZERO_ADDRESS;
  const trimmed = value.trim();
  if (!/^0x[0-9a-fA-F]{40}$/.test(trimmed)) return ZERO_ADDRESS;
  return trimmed.toLowerCase() as `0x${string}`;
}

export const MAINNET_CHAIN_ID = 4663;
export const CHAIN_ID = Number(process.env.NEXT_PUBLIC_CHAIN_ID ?? '46630');

export const contracts = {
  zor: normalise(process.env.NEXT_PUBLIC_ZOR_ADDRESS),
  vesting: normalise(process.env.NEXT_PUBLIC_VESTING_ADDRESS),
  merkleDistributor: normalise(process.env.NEXT_PUBLIC_MERKLE_DISTRIBUTOR_ADDRESS),
  buyback: normalise(process.env.NEXT_PUBLIC_BUYBACK_ADDRESS),
  treasury: normalise(process.env.NEXT_PUBLIC_TREASURY_ADDRESS),
  insurance: normalise(process.env.NEXT_PUBLIC_INSURANCE_ADDRESS),
  timelock: normalise(process.env.NEXT_PUBLIC_TIMELOCK_ADDRESS),
  vaultFactory: normalise(process.env.NEXT_PUBLIC_VAULT_FACTORY_ADDRESS),
  strategyExecutor: normalise(process.env.NEXT_PUBLIC_STRATEGY_EXECUTOR_ADDRESS),
  reputationRegistry: normalise(process.env.NEXT_PUBLIC_REPUTATION_REGISTRY_ADDRESS),
  vaultLauncher: normalise(process.env.NEXT_PUBLIC_VAULT_LAUNCHER_ADDRESS),
  leaderFaucet: normalise(process.env.NEXT_PUBLIC_LEADER_FAUCET_ADDRESS),

  // The oracle and the three factory vaults. These were read straight from
  // process.env elsewhere and never appeared in this map, so `missingContracts`
  // could not see them and the environment banner could not report them. That
  // is why a deployment with no vault addresses at all still announced exactly
  // one missing entry -- it was only ever counting the twelve above.
  oracle: normalise(process.env.NEXT_PUBLIC_ORACLE_ADDRESS),
  spotVault: normalise(process.env.NEXT_PUBLIC_SPOT_VAULT_ADDRESS),
  rotationVault: normalise(process.env.NEXT_PUBLIC_ROTATION_VAULT_ADDRESS),
  yieldVault: normalise(process.env.NEXT_PUBLIC_YIELD_VAULT_ADDRESS),
} as const;

export type ContractKey = keyof typeof contracts;

/** True when an address is actually configured, so the UI can say so plainly. */
export function isDeployed(key: ContractKey): boolean {
  return contracts[key] !== ZERO_ADDRESS;
}

/** Every unconfigured contract, whether or not that is expected. */
export function missingContracts(): ContractKey[] {
  return (Object.keys(contracts) as ContractKey[]).filter((k) => !isDeployed(k));
}

/**
 * Whether a contract being unset is CORRECT on the given chain.
 *
 * The environment banner used to report all sixteen keys alike, which on
 * mainnet meant shouting "7 contract addresses are unset, so the panels below
 * have nothing to read" at every visitor -- while the panels below read fine.
 * Six of those seven are deliberate, and one of them was simply wrong.
 *
 * Crying wolf has a cost beyond looking untidy: this banner is the same
 * surface that has to be believed on the day something IS broken, and a
 * warning that is always on is a warning nobody reads.
 *
 * Testnet 46630 ran the full stack, so nothing is expected to be absent there
 * and this returns false for every key.
 */
export function isExpectedAbsence(key: ContractKey, chainId: number = CHAIN_ID): boolean {
  if (chainId !== MAINNET_CHAIN_ID) return false;

  switch (key) {
    // Written and tested, deliberately not deployed on 4663. lib/deployment.ts
    // NOT_ON_MAINNET carries the reasoning and the public disclosure; the
    // whitepaper and /protocol say so too. Absent by decision, not by fault.
    case 'oracle':
    case 'strategyExecutor':
    case 'spotVault':
    case 'rotationVault':
    case 'reputationRegistry':
      return true;

    // Testnet-only by design. `isMainnet` exists in lib/chains.ts precisely so
    // this cannot reach mainnet -- reporting its absence there as a
    // misconfiguration inverts the intent.
    case 'leaderFaucet':
      return true;

    // Deployed on mainnet (zsUSDG, 0x3829bC78...), just not through this env
    // var. Vaults stopped being env-configured singletons: the portal reads
    // them from `vaults` filtered by chain_id (migrations 011 and 012), which
    // is what lets a second yield vault exist at all. A singleton address here
    // could only ever name one of them, so leaving it unset is right and the
    // banner should not have called it missing.
    case 'yieldVault':
      return true;

    default:
      return false;
  }
}

/**
 * Unconfigured contracts that SHOULD have been configured -- the only ones
 * worth interrupting a reader about.
 */
export function misconfiguredContracts(chainId: number = CHAIN_ID): ContractKey[] {
  return missingContracts().filter((k) => !isExpectedAbsence(k, chainId));
}

export const explorerUrl =
  process.env.NEXT_PUBLIC_EXPLORER_URL ?? 'https://explorer.testnet.chain.robinhood.com';

export function explorerAddress(address: string): string {
  return `${explorerUrl.replace(/\/$/, '')}/address/${address}`;
}

export function explorerTx(hash: string): string {
  return `${explorerUrl.replace(/\/$/, '')}/tx/${hash}`;
}

/**
 * Vault deposits.
 *
 * These were gated off while audit finding V-01 was open, the yield vault
 * valued shares against an adapter balance it never funded, so a redeemer
 * received nothing. That is fixed, the full contract suite is green, and the
 * gate now defaults to ON.
 *
 * It remains an explicit kill switch: setting
 * NEXT_PUBLIC_ENABLE_VAULT_DEPOSITS=false disables the deposit surface across
 * every vault without a redeploy, which is what you want available during an
 * incident.
 */
export const VAULT_DEPOSITS_ENABLED =
  process.env.NEXT_PUBLIC_ENABLE_VAULT_DEPOSITS !== 'false';

// ─── ABIs ───────────────────────────────────────────────────────────────────

export const zorAbi = [
  ...erc20Abi,
  {
    type: 'function',
    name: 'MAX_SUPPLY',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'getVotes',
    stateMutability: 'view',
    inputs: [{ type: 'address', name: 'account' }],
    outputs: [{ type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'delegates',
    stateMutability: 'view',
    inputs: [{ type: 'address', name: 'account' }],
    outputs: [{ type: 'address' }],
  },
  {
    type: 'function',
    name: 'delegate',
    stateMutability: 'nonpayable',
    inputs: [{ type: 'address', name: 'delegatee' }],
    outputs: [],
  },
  {
    type: 'function',
    name: 'CLOCK_MODE',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'string' }],
  },
  {
    type: 'function',
    name: 'burn',
    stateMutability: 'nonpayable',
    inputs: [{ type: 'uint256', name: 'amount' }],
    outputs: [],
  },
] as const;

export const vestingAbi = [
  {
    type: 'function',
    name: 'claimable',
    stateMutability: 'view',
    inputs: [{ type: 'address', name: 'beneficiary' }],
    outputs: [{ type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'vestedTotal',
    stateMutability: 'view',
    inputs: [{ type: 'address', name: 'beneficiary' }],
    outputs: [{ type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'scheduleOf',
    stateMutability: 'view',
    inputs: [{ type: 'address', name: 'beneficiary' }],
    outputs: [
      {
        type: 'tuple',
        components: [
          { type: 'uint128', name: 'totalAmount' },
          { type: 'uint128', name: 'claimed' },
          { type: 'uint64', name: 'startTime' },
          { type: 'uint64', name: 'cliffDuration' },
          { type: 'uint64', name: 'vestDuration' },
          { type: 'bool', name: 'revocable' },
          { type: 'bool', name: 'revoked' },
        ],
      },
    ],
  },
  {
    type: 'function',
    name: 'claim',
    stateMutability: 'nonpayable',
    inputs: [],
    outputs: [{ type: 'uint256' }],
  },
] as const;

export const merkleDistributorAbi = [
  {
    type: 'function',
    name: 'merkleRoot',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'bytes32' }],
  },
  {
    type: 'function',
    name: 'claimDeadline',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'isClaimed',
    stateMutability: 'view',
    inputs: [{ type: 'uint256', name: 'index' }],
    outputs: [{ type: 'bool' }],
  },
  {
    type: 'function',
    name: 'claim',
    stateMutability: 'nonpayable',
    inputs: [
      { type: 'uint256', name: 'index' },
      { type: 'address', name: 'account' },
      { type: 'uint256', name: 'amount' },
      { type: 'bytes32[]', name: 'merkleProof' },
    ],
    outputs: [],
  },
] as const;

/**
 * The deployed buyback contract PREDATES the USDC -> USDG rename.
 *
 * `ZorphaBuyback.sol` now declares `uint256 public totalUsdgSpent`, and this
 * ABI was updated to match -- but the contract at the deployed address was
 * never redeployed, so that selector is simply absent from its bytecode:
 *
 *   cast call $BUYBACK 'totalUsdgSpent()(uint256)'  ->  execution reverted, data: "0x"
 *   cast call $BUYBACK 'totalUsdcSpent()(uint256)'  ->  0
 *   cast call $BUYBACK 'usdg()(address)'            ->  execution reverted
 *   cast call $BUYBACK 'usdc()(address)'            ->  0x1C23...
 *
 * An empty revert reason is what an unknown selector looks like, and wagmi
 * surfaces it as `undefined`, so "USDG spent" rendered an em dash next to a
 * "$ZOR burned" of 0 read from the same contract in the same breath. The event
 * signature still says `usdcSpent`, which is the fingerprint of the same rename.
 *
 * Both names are declared so the panel can read whichever the deployed
 * bytecode actually has. That keeps working after a redeploy instead of
 * needing a matching code change on the day.
 */
export const buybackAbi = [
  {
    type: 'function',
    // NOT the only spelling that matters. See `totalUsdcSpent` below.
    name: 'totalUsdgSpent',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'uint256' }],
  },
  {
    // The name actually present in the deployed bytecode today.
    type: 'function',
    name: 'totalUsdcSpent',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'totalZorBurned',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'minBuybackThreshold',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'uint256' }],
  },
  {
    type: 'event',
    name: 'BuybackExecuted',
    inputs: [
      { type: 'address', name: 'caller', indexed: true },
      { type: 'uint256', name: 'usdcSpent', indexed: false },
      { type: 'uint256', name: 'zorBurned', indexed: false },
    ],
  },
] as const;

export const vaultAbi = [
  ...erc4626Abi,
  {
    type: 'function',
    name: 'getNavPerShare',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'rebalanceCount',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'uint256' }],
  },
  {
    // `isCircuitBreakerActive`, NOT `circuitBreakerActive`.
    //
    // This read was wrong from the start and failed silently for it. All three
    // vaults declare `bool public isCircuitBreakerActive`, so the getter the
    // app asked for does not exist and every call reverted:
    //
    //   cast call $SPOT 'isCircuitBreakerActive()(bool)'  ->  false
    //   cast call $SPOT 'circuitBreakerActive()(bool)'    ->  execution reverted
    //
    // wagmi surfaces that as `undefined` rather than an error, so a halted
    // vault and a healthy one rendered identically -- the one piece of state
    // where being wrong matters most, because it is the state that says
    // "deposits are stopped".
    type: 'function',
    name: 'isCircuitBreakerActive',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'bool' }],
  },
  {
    // Basis points of gains taken above a high-water mark, paid to the
    // treasury. Needed to quote a depositor the rate they actually keep
    // rather than the underlying venue's headline number.
    type: 'function',
    name: 'performanceFee',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'uint256' }],
  },
  {
    // Yield vaults only. Reverts on the spot and rotation vaults, which is
    // how the APY panel tells the two apart without being told.
    type: 'function',
    name: 'adapter',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'address' }],
  },
] as const;

export { erc20Abi, erc4626Abi };

/**
 * ERC4626YieldAdapter: the hop from a Zorpha yield vault to the venue it
 * actually earns in. `target` is that venue.
 */
export const yieldAdapterAbi = [
  {
    type: 'function',
    name: 'target',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'address' }],
  },
] as const;

/**
 * Morpho Vault V2, the shape of the venue behind the live yield vault
 * (Steakhouse USDG, 0xBeEff0...09dd on chain 4663).
 *
 * These three reads are the whole live-APY measurement. `_totalAssets` is what
 * the vault has booked as of `lastUpdate`; the first return of
 * `accrueInterestView` is what it would book at the current block. The gap
 * between them, over the elapsed seconds, is the rate -- see lib/apy.ts.
 *
 * Deliberately NOT part of `vaultAbi`: these are the underlying venue's
 * functions, not Zorpha's, and a venue that is not a Morpho V2 vault will
 * revert on all three. The panel treats that as "cannot measure" and says so,
 * which is the honest outcome for a venue whose rate it has no way to read.
 */
/**
 * Multicall3's view of the block it is executing in.
 *
 * Read alongside the accrual figures in the SAME `useReadContracts` group, so
 * the timestamp and the balances come from one block. Taking the timestamp
 * from a separate `useBlock` instead lets the two drift apart, and at ~0.15s
 * blocks that skew lands directly in the numerator of the rate. See the note
 * on MULTICALL3 in lib/chains.ts.
 */
export const multicall3TimestampAbi = [
  {
    type: 'function',
    name: 'getCurrentBlockTimestamp',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'uint256' }],
  },
] as const;

export const MULTICALL3_ADDRESS =
  '0xcA11bde05977b3631167028862bE2a173976CA11' as const;

export const morphoVaultV2Abi = [
  {
    type: 'function',
    name: '_totalAssets',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'uint128' }],
  },
  {
    type: 'function',
    name: 'lastUpdate',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'uint64' }],
  },
  {
    type: 'function',
    name: 'accrueInterestView',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'uint256' }, { type: 'uint256' }, { type: 'uint256' }],
  },
] as const;

/**
 * VaultLauncher: permissionless vault creation.
 *
 * `vaultSummary` exists so a leaderboard row is one call rather than five.
 * The column that matters is coverage: the share of a vault's assets backed by
 * its leader's own subordinated capital. It is the only number on the page
 * that a competitor cannot also show, because no other vault protocol has the
 * leader's money standing in front of the depositors'.
 */
export const vaultLauncherAbi = [
  {
    type: 'function',
    name: 'launchCount',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'minCoverageBps',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'uint16' }],
  },
  {
    type: 'function',
    name: 'vaultSummary',
    stateMutability: 'view',
    inputs: [{ name: 'launchId', type: 'uint256' }],
    outputs: [
      { name: 'vault', type: 'address' },
      { name: 'leader', type: 'address' },
      { name: 'totalAssets', type: 'uint256' },
      { name: 'escrowBalance', type: 'uint256' },
      { name: 'coverageBps', type: 'uint256' },
      { name: 'adequatelyCovered', type: 'bool' },
    ],
  },
  // --- launching -----------------------------------------------------------
  // The cost of becoming a leader, read from the contract rather than written
  // into the copy. Governance can change both, and a hardcoded "10,000 $ZOR"
  // in the UI would go quietly wrong the day it does.
  {
    type: 'function',
    name: 'bondAmount',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'minSeedEscrow',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'approvedTarget',
    stateMutability: 'view',
    inputs: [{ type: 'address' }],
    outputs: [{ type: 'bool' }],
  },
  // The allowlist, enumerable. approvedTarget answers "is this one approved?"
  // and cannot answer "which ones are?", which is why the launch form used to
  // ask a leader to paste an address and guess.
  {
    type: 'function',
    name: 'allApprovedTargets',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'address[]' }],
  },
  {
    type: 'function',
    name: 'zor',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'address' }],
  },
  {
    type: 'function',
    name: 'launchYieldVault',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'target', type: 'address' },
      { name: 'seedEscrow', type: 'uint256' },
      { name: 'name', type: 'string' },
      { name: 'symbol', type: 'string' },
      { name: 'salt', type: 'bytes32' },
    ],
    outputs: [
      { name: 'vault', type: 'address' },
      { name: 'escrow', type: 'address' },
    ],
  },
] as const;

/**
 * LeaderFaucet: one bond plus one seed per address, testnet only.
 *
 * It exists because the leader programme was impossible to enter. Launching a
 * vault costs a 10,000 $ZOR bond and $ZOR has no mint function -- the whole
 * supply is minted in the constructor -- so a prospective leader had to ask
 * governance for tokens by hand. That is a favour, not a programme, and it is
 * why exactly one person has ever launched a vault here.
 *
 * `ticket` is read from the launcher on every call rather than stored, so a
 * governance change to the bond cannot leave the faucet paying the wrong
 * amount. `claimsRemaining` is bounded by the faucet's actual balance as well
 * as its cap, so the UI never promises a claim that would revert.
 */
export const leaderFaucetAbi = [
  // The three identities the faucet was built against. A faucet left over from
  // a previous deployment answers every other call happily while handing out a
  // superseded ZOR and a superseded tUSDG, so a claim succeeds and the launch
  // it was for reverts. Reading these is what lets the UI say so.
  {
    type: 'function',
    name: 'zor',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'address' }],
  },
  {
    type: 'function',
    name: 'usdg',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'address' }],
  },
  {
    type: 'function',
    name: 'launcher',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'address' }],
  },
  {
    type: 'function',
    name: 'ticket',
    stateMutability: 'view',
    inputs: [],
    outputs: [
      { name: 'bond', type: 'uint256' },
      { name: 'seed', type: 'uint256' },
    ],
  },
  {
    type: 'function',
    name: 'claimsRemaining',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'hasClaimed',
    stateMutability: 'view',
    inputs: [{ name: '', type: 'address' }],
    outputs: [{ type: 'bool' }],
  },
  {
    type: 'function',
    name: 'claim',
    stateMutability: 'nonpayable',
    inputs: [],
    outputs: [
      { name: 'bond', type: 'uint256' },
      { name: 'seed', type: 'uint256' },
    ],
  },
] as const;

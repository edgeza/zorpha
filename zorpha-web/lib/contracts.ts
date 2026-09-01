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
} as const;

export type ContractKey = keyof typeof contracts;

/** True when an address is actually configured, so the UI can say so plainly. */
export function isDeployed(key: ContractKey): boolean {
  return contracts[key] !== ZERO_ADDRESS;
}

/** Every unconfigured contract, for the portal's environment banner. */
export function missingContracts(): ContractKey[] {
  return (Object.keys(contracts) as ContractKey[]).filter((k) => !isDeployed(k));
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

export const buybackAbi = [
  {
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
    type: 'function',
    name: 'circuitBreakerActive',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'bool' }],
  },
] as const;

export { erc20Abi, erc4626Abi };

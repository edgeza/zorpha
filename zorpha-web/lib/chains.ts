import { defineChain } from 'viem';

/**
 * Multicall3, at its canonical cross-chain address, verified present on both
 * Robinhood chains (7,619 bytes of code on each).
 *
 * Declaring it is not just a round-trip saving. Without it viem sends each
 * `readContract` as its own `eth_call` against "latest", and blocks here are
 * ~0.15s apart, so a group of reads meant to describe one moment can straddle
 * several blocks. The live APY panel divides a change in assets by the seconds
 * it took, and at a one-second window a single block of skew between the
 * timestamp and the balances is a ~15% error in the rate -- in the flattering
 * direction. Batching pins every read in the group to one block, which is the
 * only way that division is honest.
 *
 * `blockCreated` is deliberately omitted: it exists to stop viem batching at
 * blocks older than the deployment, and every read here is against latest.
 */
const MULTICALL3 = {
  multicall3: { address: '0xcA11bde05977b3631167028862bE2a173976CA11' },
} as const;

const testnetRpc =
  process.env.NEXT_PUBLIC_RPC_URL ?? 'https://rpc.testnet.chain.robinhood.com/rpc';
const explorer =
  process.env.NEXT_PUBLIC_EXPLORER_URL ?? 'https://explorer.testnet.chain.robinhood.com';

export const robinhoodTestnet = defineChain({
  id: 46630,
  name: 'Robinhood Chain Testnet',
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: {
    default: { http: [testnetRpc] },
  },
  blockExplorers: {
    default: { name: 'Robinhood Chain Explorer', url: explorer },
  },
  contracts: MULTICALL3,
  testnet: true,
});

export const robinhoodMainnet = defineChain({
  id: 4663,
  name: 'Robinhood Chain',
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: {
    default: {
      http: [
        'https://rpc.mainnet.chain.robinhood.com',
        'https://robinhood-rpc.publicnode.com',
      ],
    },
  },
  blockExplorers: {
    default: {
      name: 'Robinhood Chain Explorer',
      url: 'https://robinhoodchain.blockscout.com',
    },
  },
  contracts: MULTICALL3,
});

/** The chain this deployment targets, driven by NEXT_PUBLIC_CHAIN_ID. */
export const activeChain =
  Number(process.env.NEXT_PUBLIC_CHAIN_ID ?? '46630') === 4663
    ? robinhoodMainnet
    : robinhoodTestnet;

/**
 * Whether this build is pointed at mainnet.
 *
 * Exported as a named fact rather than left as an inline chain-id comparison,
 * because things that must NOT exist on mainnet are easy to forget and hard to
 * notice: they render as an unfinished feature rather than an error. The bond
 * faucet is the first of them.
 */
export const isMainnet = activeChain.id === robinhoodMainnet.id;

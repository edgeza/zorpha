import { defineChain } from 'viem';

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
});

/** The chain this deployment targets, driven by NEXT_PUBLIC_CHAIN_ID. */
export const activeChain =
  Number(process.env.NEXT_PUBLIC_CHAIN_ID ?? '46630') === 4663
    ? robinhoodMainnet
    : robinhoodTestnet;

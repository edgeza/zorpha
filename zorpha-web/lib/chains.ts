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

/**
 * Which chain this build targets. Read here as well as below, because the
 * env-var RPC override has to be applied to the chain it actually describes.
 */
const targetChainId = Number(process.env.NEXT_PUBLIC_CHAIN_ID ?? '46630');

/**
 * The RPC override, applied ONLY to the chain this build targets.
 *
 * `NEXT_PUBLIC_RPC_URL` used to feed `robinhoodTestnet` unconditionally, while
 * `robinhoodMainnet` ignored it and carried a hardcoded list. On mainnet that
 * variable is set to the mainnet endpoint, so the testnet chain object in a
 * production build described mainnet: same URL, testnet's id and name. wagmi
 * registers both chains, so anything landing on chain 46630 read mainnet state
 * and labelled it testnet.
 *
 * It was visible in production as two different URLs in one page load, the
 * bare host from the mainnet transport and the `/rpc` path from the testnet
 * one. docs the app already carries make the same point from the other end:
 * lib/chain-guard.ts notes the env var and the mainnet list are not the same
 * thing, and app/(marketing)/writing/silent-failures explains that viem fails
 * over on transport errors and never on chain identity, so a wrong-chain
 * endpoint is served silently rather than rejected.
 *
 * Gating it on the target id means the override only ever reaches the chain it
 * was written for, and the other keeps its own default.
 */
const overrideRpc = process.env.NEXT_PUBLIC_RPC_URL;
const rpcOverrideFor = (id: number) => (id === targetChainId && overrideRpc ? [overrideRpc] : []);

/** Deduped, override first, so a configured endpoint is preferred but never sole. */
const rpcList = (id: number, defaults: string[]) => [
  ...new Set([...rpcOverrideFor(id), ...defaults]),
];

const explorer =
  process.env.NEXT_PUBLIC_EXPLORER_URL ?? 'https://explorer.testnet.chain.robinhood.com';

export const robinhoodTestnet = defineChain({
  id: 46630,
  name: 'Robinhood Chain Testnet',
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: {
    default: { http: rpcList(46630, ['https://rpc.testnet.chain.robinhood.com/rpc']) },
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
      /*
        Two independent endpoints, and the second is load-bearing rather than
        decoration now that lib/wagmi.ts actually builds a fallback over this
        list. publicnode was checked against the bar set by
        app/(marketing)/writing/silent-failures, which records a fallback that
        answered the right chain id and then could not serve the workload:
        eth_chainId returns 0x1237, it accepts viem's batched JSON-RPC arrays,
        it aggregates through Multicall3, it returns a single clean
        Access-Control-Allow-Origin so a browser can use it at all, and a
        multicall of the vault and token reads comes back byte-identical to the
        canonical node.
      */
      http: rpcList(4663, [
        'https://rpc.mainnet.chain.robinhood.com',
        'https://robinhood-rpc.publicnode.com',
      ]),
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
export const activeChain = targetChainId === 4663 ? robinhoodMainnet : robinhoodTestnet;

/**
 * Whether this build is pointed at mainnet.
 *
 * Exported as a named fact rather than left as an inline chain-id comparison,
 * because things that must NOT exist on mainnet are easy to forget and hard to
 * notice: they render as an unfinished feature rather than an error. The bond
 * faucet is the first of them.
 */
export const isMainnet = activeChain.id === robinhoodMainnet.id;

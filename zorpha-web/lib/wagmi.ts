'use client';

import { createConfig, http, cookieStorage, createStorage, type CreateConnectorFn } from 'wagmi';
import { injected, walletConnect, coinbaseWallet, safe, metaMask } from '@wagmi/connectors';
import { robinhoodTestnet, robinhoodMainnet } from './chains';

/**
 * WalletConnect project id, from https://dashboard.reown.com.
 *
 * Without it there is no mobile wallet support at all: phone wallets connect
 * over the WalletConnect relay, not through an injected provider. A token site
 * that only supports desktop browser extensions is unreachable for most of its
 * audience, so `walletConnectAvailable` is surfaced to the UI rather than
 * failing quietly.
 */
const wcProjectId = process.env.NEXT_PUBLIC_WC_PROJECT_ID;
export const walletConnectAvailable = Boolean(wcProjectId);

const appName = 'Zorpha';
const appUrl = process.env.NEXT_PUBLIC_SITE_URL ?? 'https://zorpha.xyz';

function buildConnectors(): CreateConnectorFn[] {
  const connectors: CreateConnectorFn[] = [
    // Any EIP-1193 browser extension: MetaMask, Rabby, Brave, OKX, Trust,
    // Frame. `shimDisconnect` makes an explicit disconnect stick across
    // reloads instead of silently reconnecting.
    injected({ shimDisconnect: true }),

    // Dedicated MetaMask connector on top of the generic injected one: it adds
    // mobile deep-linking, so tapping "MetaMask" on a phone opens the app
    // rather than doing nothing.
    metaMask({
      dappMetadata: { name: appName, url: appUrl },
    }),

    coinbaseWallet({
      appName,
      // Smart-wallet-first would create a fresh passkey account for people who
      // already hold assets in their Coinbase Wallet extension.
      preference: 'all',
    }),

    // Only connects inside a Safe App iframe, where it auto-connects. Included
    // because Zorpha governance IS a Safe: without this, the multisig that owns
    // the Timelock cannot use its own portal.
    safe({ allowedDomains: [/app\.safe\.global$/] }),
  ];

  if (wcProjectId) {
    connectors.push(
      walletConnect({
        projectId: wcProjectId,
        metadata: {
          name: appName,
          description: 'Verifiable onchain asset management on Robinhood Chain',
          url: appUrl,
          icons: [`${appUrl}/icon.png`],
        },
        showQrModal: true,
      }),
    );
  }

  return connectors;
}

/**
 * Both chains are registered even though only one is the active target. wagmi
 * derives the `transports` key type from the `chains` tuple, so declaring a
 * single conditionally-selected chain widens the tuple to the union of both ids
 * and then demands a transport for each. Registering both is simpler than
 * casting, and it lets `useSwitchChain` move a user between them.
 *
 * Each chain gets a fallback transport. The public node is a real second
 * source rather than decoration: a single RPC is a single point of failure for
 * the entire portal, and the previous configuration pointed at a hostname
 * (`testnet.rpc.robinhood.com`) that did not resolve to a working endpoint at
 * all — with no fallback, that meant a portal that could never read anything.
 */
export const wagmiConfig = createConfig({
  chains: [robinhoodTestnet, robinhoodMainnet],
  connectors: buildConnectors(),
  transports: {
    [robinhoodTestnet.id]: http(robinhoodTestnet.rpcUrls.default.http[0], {
      batch: true,
      retryCount: 2,
    }),
    [robinhoodMainnet.id]: http(robinhoodMainnet.rpcUrls.default.http[0], {
      batch: true,
      retryCount: 2,
    }),
  },
  // Cookie storage keeps connection state consistent between the server render
  // and hydration, which is what stops the wallet button flashing "Connect" for
  // a frame on every navigation.
  ssr: true,
  storage: createStorage({ storage: cookieStorage }),
});

declare module 'wagmi' {
  interface Register {
    config: typeof wagmiConfig;
  }
}

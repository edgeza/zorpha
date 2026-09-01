'use client';

import { createConfig, http, cookieStorage, createStorage } from 'wagmi';
// Imported from @wagmi/core rather than the `wagmi/connectors` barrel on
// purpose. That barrel statically pulls in the Base/Coinbase account connector,
// which reaches @coinbase/cdp-sdk and its optional @x402/* peers — packages we
// do not install and do not use. Importing the barrel therefore fails the
// webpack build with "Can't resolve '@x402/evm'" even though the only connector
// this app registers is the injected one.
import { injected } from '@wagmi/core';
import { robinhoodTestnet, robinhoodMainnet } from './chains';

/**
 * Both chains are registered even though only one is the active target. wagmi
 * derives the `transports` key type from the `chains` tuple, so declaring a
 * single conditionally-selected chain widens the tuple to the union of both ids
 * and then demands a transport for each. Registering both is simpler than
 * casting, and it means `useSwitchChain` can move a user between them.
 */
export const wagmiConfig = createConfig({
  chains: [robinhoodTestnet, robinhoodMainnet],
  connectors: [injected()],
  transports: {
    [robinhoodTestnet.id]: http(robinhoodTestnet.rpcUrls.default.http[0]),
    [robinhoodMainnet.id]: http(robinhoodMainnet.rpcUrls.default.http[0]),
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

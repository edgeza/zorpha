'use client';

import { useMemo } from 'react';
import { LiFiWidget, type WidgetConfig } from '@lifi/widget';
import { EthereumProvider } from '@lifi/widget-provider-ethereum';
import { robinhoodMainnet } from '@/lib/chains';

/**
 * Zorpha Bridging.
 *
 * A general cross-chain bridge over LI.FI: any supported chain to any other,
 * routed across every major bridge and DEX aggregator. It is deliberately not
 * restricted to Robinhood Chain, because a bridge that only accepts one
 * destination is useless to someone whose funds are somewhere else entirely.
 * The defaults below only set where the form OPENS; both sides are editable.
 *
 * This component is client-only. The page loads it through `next/dynamic` with
 * `ssr: false`, so the widget's own wagmi/viem stack never runs during a server
 * render.
 */

/* ─── Route defaults ──────────────────────────────────────────────────────
 * Open on Ethereum USDC into Robinhood Chain. Ethereum is the most universal
 * origin, and USDC is the asset people most often already hold there.
 *
 * The destination asset is USDG rather than USDC because Robinhood Chain has
 * no canonical USDC deployment. Its stablecoin is Paxos USDG, which is what
 * LI.FI's own token list carries for chain 4663. Defaulting to a token that
 * does not exist on the destination chain would open the widget on a route
 * that can never quote.
 *
 * Verified live against li.quest: Ethereum USDC to Robinhood Chain USDG routes
 * via Across in roughly two seconds for about 45bps all-in.
 * ------------------------------------------------------------------------ */
const FROM_CHAIN = 1;
const FROM_TOKEN = '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48'; // USDC, 6dp
const TO_CHAIN = robinhoodMainnet.id; // 4663
const TO_TOKEN = '0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168'; // USDG, 6dp

/**
 * Cross-chain transfers carry fixed costs: gas on both sides plus a bridge fee.
 * Below roughly $20 those costs dominate the transfer, and many bridges reject
 * the route outright. The widget surfaces a clear minimum instead of letting
 * someone burn $6 of gas to move $8.
 */
const MIN_FROM_AMOUNT_USD = 20;

/**
 * Must exactly match the integration string registered in the LI.FI dashboard.
 * LI.FI keys the integrator fee and its destination wallet off this string, so
 * a mismatch silently sends fees nowhere.
 *
 * `NEXT_PUBLIC_BRIDGE_FEE` therefore defaults to 0. Charging a fee against an
 * unregistered integrator makes LI.FI reject the quote, which would break the
 * bridge for everyone. Register `zorpha` in the dashboard first, then set the
 * variable to 0.0025 for 25bps.
 */
const INTEGRATOR = 'zorpha';

/**
 * No LI.FI API key here, deliberately. LI.FI's own guidance is that the widget
 * runs without one, and `x-lifi-api-key` must never reach the browser bundle.
 * If rate limits ever bite, the key belongs behind a route handler that injects
 * it server-side.
 */

const wcProjectId = (process.env.NEXT_PUBLIC_WC_PROJECT_ID ?? '').trim();
const wcEnabled = wcProjectId.length > 0;

export default function BridgeWidget() {
  const fee = Number(process.env.NEXT_PUBLIC_BRIDGE_FEE ?? 0);

  const config = useMemo<Partial<WidgetConfig>>(
    () => ({
      integrator: INTEGRATOR,
      ...(fee > 0 ? { fee } : {}),

      /**
       * The widget defaults to 0.5%, which is too tight for a two-hop route.
       * A swap leg plus pool drift between quote and signature routinely
       * exceeds it, and the transaction then reverts on the destination's
       * minimum-output check. 1% is the common bridge default; anyone who
       * wants it tighter can change it in the widget's own settings.
       */
      slippage: 0.01,
      minFromAmountUSD: MIN_FROM_AMOUNT_USD,

      fromChain: FROM_CHAIN,
      fromToken: FROM_TOKEN,
      toChain: TO_CHAIN,
      toToken: TO_TOKEN,

      // Show the recommended route only, rather than inviting people to
      // hand-pick an exotic path with thin liquidity.
      showSingleRoute: true,

      /**
       * `forceInternalWalletManagement` makes the widget build its own wagmi
       * config instead of adopting the portal's.
       *
       * This is load-bearing. The rest of the app is wrapped in a WagmiProvider
       * configured for Robinhood Chain only. LI.FI's EthereumProvider detects
       * an ancestor WagmiProvider and reuses it by default, and a two-chain
       * config cannot switch to Ethereum or Arbitrum, so every route would fail
       * with "chain not configured". With this flag the widget syncs in all of
       * LI.FI's supported chains privately, and the portal's config is left
       * exactly as it was.
       */
      walletConfig: { forceInternalWalletManagement: true },
      providers: [
        EthereumProvider({
          ...(wcEnabled ? { walletConnect: { projectId: wcProjectId } } : {}),
          coinbase: { appName: 'Zorpha' },
        }),
      ],

      // Drop the widget's third-party chrome so it reads as part of the site.
      hiddenUI: { poweredBy: true, language: true, appearance: true },
      appearance: 'dark',

      theme: {
        colorSchemes: {
          dark: {
            palette: {
              primary: { main: '#8b6dff' }, // zor-500
              secondary: { main: '#c4b5ff' }, // zor-300
              background: {
                default: '#0a0a11', // void-900
                paper: '#13131f', // void-800
              },
              text: {
                primary: '#f6f6fb', // ink-100
                secondary: '#b8b8cc', // ink-300
              },
              grey: {
                200: '#e2e2ee',
                300: '#b8b8cc',
                700: '#1c1c2b',
                800: '#13131f',
              },
            },
          },
        },
        // 14px matches the `rounded-card` radius every other surface uses.
        shape: { borderRadius: 14 },
        typography: { fontFamily: 'var(--font-sans), ui-sans-serif, system-ui, sans-serif' },
        container: {
          border: '1px solid #1c1c2b', // void-700, same as .card
          borderRadius: '14px',
          boxShadow: '0 1px 0 0 rgba(255,255,255,0.03) inset, 0 18px 48px -24px rgba(0,0,0,0.9)',
          // The widget ships `width: 100%; max-width: 416px; box-sizing:
          // content-box`. On a 375px phone the max-width wins over the parent
          // and content-box then adds the 1px borders on top, so the page ends
          // up scrolling sideways. Capping at 100% and switching to border-box
          // makes it track its parent instead. Its own 360px min-width still
          // applies, which is fine on any phone 360px or wider.
          width: '100%',
          maxWidth: '100%',
          boxSizing: 'border-box',
        },
      },
    }),
    [fee],
  );

  return <LiFiWidget integrator={INTEGRATOR} config={config} />;
}

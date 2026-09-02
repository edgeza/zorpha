import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.dirname(fileURLToPath(import.meta.url));

/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,

  // `next dev` and `next build` both write `.next`, so running one while the
  // other is live leaves a half-production, half-dev tree: the dev server asks
  // for `app/portal/layout.js` and finds only `layout-8ed2efd6.js`, every core
  // chunk 404s, the app never hydrates, and every on-chain value renders as the
  // server-side "--" placeholder. It looks exactly like broken contract reads
  // and is not.
  //
  // Setting NEXT_DIST_DIR gives a second build tree, so a verification server
  // can run beside a build without either corrupting the other. Unset in normal
  // use, and Vercel never sets it, so production is untouched.
  ...(process.env.NEXT_DIST_DIR ? { distDir: process.env.NEXT_DIST_DIR } : {}),

  images: {
    remotePatterns: [{ protocol: 'https', hostname: '**' }],
  },

  webpack: (config) => {
    config.resolve.alias = {
      ...config.resolve.alias,

      // `@wagmi/core@3.5.5` references `viem/tempo/zones`, which no published
      // viem exports (2.56.1 is latest and its exports map stops at
      // `./tempo/actions`). `@wagmi/connectors`'s barrel re-exports
      // `tempoWallet` from it, and `@lifi/widget-provider-ethereum` imports
      // `safe` from that barrel, so the bridge page cannot build without
      // cutting the subtree.
      //
      // `lib/wagmi.ts` sidesteps the barrel with per-connector subpath imports.
      // The LI.FI provider is third-party and cannot, hence this alias. The
      // stub keeps the barrel's re-exported bindings valid instead of aliasing
      // to `false`, which would leave a dangling re-export.
      '@wagmi/core/tempo': path.resolve(root, 'lib/stubs/wagmi-tempo.js'),

      // Two optional peers of `@wagmi/connectors` that this app deliberately
      // does NOT install, because it registers neither connector.
      //
      // Both are reached through guarded dynamic `import()` calls inside
      // connector methods, so severing them is safe: the code that would touch
      // them only runs if someone connects with Base Account or Porto, and
      // neither is offered here or in the bridge's provider config. The five
      // connectors that ARE offered (injected, MetaMask, Coinbase, Safe,
      // WalletConnect) have their peers installed properly in package.json,
      // because for those the same dynamic import is very much reachable and
      // throws "dependency not found" the moment a user clicks the wallet.
      //
      // `@base-org/account` in particular must stay severed rather than
      // installed: it pulls @coinbase/cdp-sdk, which pulls @x402/evm, @x402/svm
      // and @x402/core, none of which resolve. Cutting at the root beats
      // chasing those leaves one unresolvable specifier at a time.
      '@base-org/account': false,

      // `porto` is an optional peer of `@wagmi/connectors` that this app does
      // not install. Its connector reaches for it through a guarded dynamic
      // `import()` inside a function nothing here calls, so it is unreachable
      // at runtime, but webpack still resolves it for the chunk graph and
      // warns on every build. Aliasing keeps the build output clean enough
      // that a real warning is still visible in it.
      porto: false,
      'porto/internal': false,

      // Optional peers of the MetaMask SDK and pino that only exist for React
      // Native and pretty-printed server logs respectively. Neither is
      // reachable from a browser bundle; without these the build emits three
      // "Can't resolve" warnings on every run, which trains you to ignore
      // exactly the warnings you should be reading.
      '@react-native-async-storage/async-storage': false,
      'pino-pretty': false,
    };

    return config;
  },
};

export default nextConfig;

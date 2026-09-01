/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,

  images: {
    remotePatterns: [{ protocol: 'https', hostname: '**' }],
  },

  webpack: (config) => {
    // `@wagmi/connectors` only exposes a barrel export ("." in its exports map),
    // so importing any connector pulls in ALL of them — including
    // `baseAccount`, which reaches @base-org/account -> @coinbase/cdp-sdk ->
    // @x402/evm and @x402/svm. Those are optional peers we do not install, and
    // webpack fails the whole build with "Can't resolve '@x402/evm'".
    //
    // The Base account connector is not registered in lib/wagmi.ts, so this
    // whole subtree is unreachable at runtime. Cut it at the ROOT rather than
    // aliasing each unresolvable leaf: aliasing @x402/evm just surfaced
    // @x402/core/client next, and chasing individual specifiers through a
    // dependency tree we do not use is a losing game. Severing
    // @base-org/account removes @coinbase/cdp-sdk and every @x402/* package
    // with it, and stays correct if that tree gains more optional peers.
    config.resolve.alias = {
      ...config.resolve.alias,
      '@base-org/account': false,
      '@coinbase/cdp-sdk': false,

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

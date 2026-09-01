# Chainlink price feeds — Robinhood Chain mainnet (4663)

Fetched from the Chainlink reference-data directory. **57 feeds.** All 8 decimals,
which matches what  and  expect from an
AggregatorV3 source.

There is **no published testnet feed list** — the equivalent testnet path 404s. So
testnet runs on the self-operated , and mainnet should use these
instead.  already switches on  / :
set them to a feed below and the MedianOracle fallback is bypassed.

Verify every address against Chainlink docs before use. This file is a snapshot.

| Feed | Proxy address | Decimals | Heartbeat | Deviation |
|---|---|---|---|---|

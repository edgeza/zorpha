# Mainnet asset universe, Robinhood Chain 4663

Read off chain at block **53,639,835**, 3 September 2026 18:54 UTC. Every number
below came from `eth_call` against the live chain, not from a token list or a
block explorer. Re-run the method in section 4 before trusting it again: pool
depth moves daily.

---

## 1. The blocker: our staleness window rejects healthy Chainlink feeds

**This is a hard mainnet blocker, and it is not fixable after deploy.**

`DeployVaultsV1.s.sol` sets `maxOracleStaleness: 1 hours` (lines 203 and 238).
`maxOracleStaleness` is **`immutable`** in both `SpotVaultMinimal` (line 38) and
`RWRotationVault` (line 44), assigned in the constructor, with no setter. A vault
deployed with the wrong window is not reconfigurable. It is redeployable.

Chainlink's feeds on this chain publish on an **86,400s heartbeat** with a 0.5%
deviation trigger (52 of the 57 feeds in `CHAINLINK-FEEDS-MAINNET.md`). They update
when price moves half a percent, *or* once a day, whichever comes first. An old
timestamp is the feed working correctly, not a fault.

All 57 feeds, read live, mid-week, during US market hours:

```
answering      57 / 57      errors 0
fresh <3600s   26
STALE >3600s   31           <- 54%
oldest         85,240s (23.7h)
```

The ten oldest at the time of the scan:

```
syrupUSDG / USDG Exchange Rate    85,240s   23.7h
SYRUPUSDT / USDT Exchange Rate    85,088s   23.6h
SYRUPUSDC / USDC Exchange Rate    76,513s   21.3h
Robinhood SGOV-USD                66,984s   18.6h
Robinhood GOOGL / USD             16,571s    4.6h
EURC / USD                        14,582s    4.1h
Robinhood QQQ / USD               12,340s    3.4h
Robinhood SPY / USD               12,336s    3.4h
USDC / USD                        11,408s    3.2h
USDT / USD                        11,398s    3.2h
```

Ship the current configuration and **more than half the vaults revert on every
rebalance and every NAV read** with `StaleOracle`, against feeds behaving exactly
as designed. `SpotVaultMinimal._oraclePrice` fails closed deliberately, and that is
right. The window is what is wrong.

### Widening the window is not the whole fix

Setting it to `86400 + margin` makes the contracts work, and introduces a second
problem that needs an explicit decision.

A tokenised equity trades **24/7 on Robinhood Chain while its reference market is
closed sixteen hours a day and all weekend.** Chainlink's 0.5% deviation trigger
guards against acting on a stale price only while there is a live price to deviate
from. Overnight there is not: the feed is frozen because the market is shut, not
because the price is steady.

So with a 24-hour window, a manager who knows the stock gapped after hours can sign
a rebalance against the previous close, inside the slippage bound, and every check
in `StrategyExecutor` passes. The contract cannot distinguish "the price has not
moved" from "nobody is pricing this right now".

Options, none of them free:

1. **Per-asset windows.** Equities get heartbeat + margin; crypto and FX get
   something far tighter. Correct, and it means the launcher carries a staleness
   parameter per approved asset rather than one constant.
2. **Refuse rebalances outside reference-market hours.** Safest, and it makes a
   24/7 chain behave like a 6.5-hour venue.
3. **Widen the slippage bound outside hours** so the arbitrage is not free.
4. **Accept it and disclose it.**

This must be decided before an equity vault takes real money, and because it is a
constructor argument it cannot be deferred past deploy.

---

## 2. What Zorpha can actually list

A vault needs **both** a price feed and a venue. Neither alone is enough: a feed
without depth is a vault that cannot rebalance, and depth without a feed is a vault
that cannot mark its own NAV.

Scanned every `PoolCreated` event on the Uniswap V3 factory
(`0x1f7d7550B1b028f7571E69A784071F0205FD2EfA`) where one side is Paxos USDG
(`0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`, "Global Dollar", 6dp), then read the
USDG balance of every resulting pool.

```
USDG pools created        4,524
holding more than 1 USDG    322      <- 93% of pools on this chain are dust
```

**Deepest pool per asset, where a Chainlink feed also exists.** Depth is USDG held
on the quote side of that pool.

| Ticker | Depth (USDG) | Fee | Token | Feed |
|---|---:|---|---|---|
| NVDA  | 6,362,873 | 500   | `0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC` | `0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15` |
| SPCX  | 1,372,682 | 500   | `0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa` | `0xB265810950ba6c5C0Ff821c9963014a56fD8Bffb` |
| QQQ   | 1,365,099 | 500   | `0xD5f3879160bc7c32ebb4dC785F8a4F505888de68` | `0x80901d846d5D7B030F26B480776EE3b29374C2ae` |
| MU    |   641,470 | 3000  | `0xfF080c8ce2E5feadaCa0Da81314Ae59D232d4afD` | `0x425EEFdCf05ed6526C3cE61Af99429A228a6d596` |
| CRCL  |   593,011 | 3000  | `0xdF0992E440dD0be65BD8439b609d6D4366bf1CB5` | `0x6652eDf64bA3731C4F2D3ce821A0Fb1f1f6b482a` |
| DELL  |   405,542 | 10000 | `0x941AE714EC6D8130c7B75d67160Ca08f1e7d11Dd` | `0x1C6c8cADBe02E19129c39dDB92281cE4c0bf206b` |
| GOOGL |   405,370 | 500   | `0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3` | `0xF6f373a037c30F0e5010d854385cA89185AE638b` |
| TSLA  |   342,080 | 3000  | `0x322F0929c4625eD5bAd873c95208D54E1c003b2d` | `0x4A1166a659A55625345e9515b32adECea5547C38` |
| USO   |   336,089 | 3000  | `0xa30FA36Db767ad9eD3f7a60fC79526fB4d56D344` | `0x75a9c76Ef439e2C7c2E5a34Ab105EcFe3766431c` |
| GME   |   299,478 | 500   | `0x1b0E319c6A659F002271B69dB8A7df2F911c153E` | `0x27C71df6A64fB476468EdF256CF72c038baB5B67` |
| AMZN  |   252,753 | 3000  | `0x12f190a9F9d7D37a250758b26824B97CE941bF54` | `0xD5a1508ceD74c084eBf3cBe853e2C968fB2a651C` |
| AAPL  |   237,013 | 500   | `0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9` | `0x6B22A786bAa607d76728168703a39Ea9C99f2cD0` |
| MSFT  |   151,583 | 3000  | `0xe93237C50D904957Cf27E7B1133b510C669c2e74` | `0x45C3C877C15E6BA2EBB19eA114Ea508d14C1Af2E` |
| SGOV  |   132,357 | 3000  | `0x92FD66527192E3e61d4DDd13322Aa222DE86F9B5` | `0xa0DF4ee0fFf975306345875E3548Fcc519577A11` |
| SLV   |   126,753 | 3000  | `0x411eFb0E7f985935DAec3D4C3ebaEa0d0AD7D89f` | `0x209b73908e92Ae021826eD79609845451Ecba2ce` |
| SPY   |    91,224 | 500   | `0x117cc2133c37B721F49dE2A7a74833232B3B4C0C` | `0x319724394D3A0e3669269846abE664Cd621f9f6A` |
| MSTR  |    86,427 | 10000 | `0xec262a75e413fAfD0dF80480274532C79D42da09` | `0x396118bdFB181e6240E74D243F266B061c0edc3D` |
| META  |    75,840 | 3000  | `0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35` | `0x7C38C00C30BEe9378381E7B6135d7283356D71b1` |
| PLTR  |    71,670 | 3000  | `0x894E1EC2D74FFE5AEF8Dc8A9e84686acCB964F2A` | `0x820ABedFF239034956B7A9d2F0a331f9F075eB4c` |
| SNDK  |    55,155 | 10000 | `0xB90A19fF0Af67f7779afF50A882A9CfF42446400` | `0xfb133Fa4B7b385802B693a293606682Df47109A3` |
| TSM   |    53,295 | 10000 | `0x58FfE4a942d3885bAa22D7520691F611EF09e7AA` | `0x874cF94aa8eC88Fd9560094dD065f2fB3E41Fc2F` |
| BABA  |    41,429 | 3000  | `0xad25Ac6C84D497db898fa1E8387bf6Af3532a1c4` | `0x62Cc8F9b5f56a33c9C8A60c8B92779f523c4E984` |
| USAR  |    27,380 | 3000  | `0xd917B029C761D264c6A312BBbcDA868658eF86a6` | `0xA994d3684e8400A6c8078226925779FdeE682DD9` |
| ASML  |    23,174 | 10000 | `0x47F93d52cBeC7C6D2CfC080e154002370a60dAEA` | `0xB4106147E8cce40b7d46124090d373A71b70f87D` |
| INTC  |    22,956 | 3000  | `0xc72b96e0E48ecd4DC75E1e45396e26300BC39681` | `0x3f390C5C24628Ac7C489515402235FeAD71D1913` |
| AMD   |    22,203 | 3000  | `0x86923f96303D656E4aa86D9d42D1e57ad2023fdC` | `0x943A29E7ae51A4798823ca9eEd2ed533B2A22C72` |

Plus **WETH** (`0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73`) at **14,983,256 USDG**,
priced by the `ETH / USD` feed `0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9`. It is
the deepest pool on the chain, by a factor of two over NVDA.

### Depth is the binding constraint, and it varies 286×

NVDA has 6.36M USDG behind it. AMD has 22k. The router adapter's own measurements
(`RobinhoodChainRouterAdapter`) put $10k at 0.44% and $40k at 31% on a pool of
comparable size; so with `maxSlippageBps = 100`, **vault capacity is set by the
pool, not by demand.**

An AAPL vault against 237k of depth cannot rebalance half of a $100k book: that is a
$50k trade into a pool a fifth its size, and it reverts on slippage. The same vault
on NVDA has 27× the room.

Capacity per asset therefore has to be a launch parameter, or leaders will create
vaults that pass every check at launch and then cannot be operated.

### Feed exists, no USDG pool found (25)

`CLSK COIN CRWV EWY IONQ NBIS ORCL RGTI RKLB ENA EURC LINK USDC USDE USDS USDT LBTC
CBBTC BTC.B WBTC SYRUPUSDC SYRUPUSDG SYRUPUSDT WEETH WSTETH`

Not listable today. Some may have WETH-quoted pools this scan did not cover.

---

## 3. Ticker collisions are real here, key the allowlist on address

The scan matched feeds to tokens **by ticker**, and that method immediately picked
up two impostors:

| Claimed symbol | Address | Actual name |
|---|---|---|
| `USDG` | `0xc1a0957594A80aa55A12E76AE4cDf513e84301C7` | **UnicornSnakeDollarGoat** |
| `GME`  | `0x8ffE039e91e0873913Ee2275B6fFf206A3f99c04` | **I Like the Stock** |

against the genuine `Global Dollar` (`0x5fc5360D…`) and `GameStop • Robinhood Token`
(`0x1b0E319c…`). Both squatters had live USDG pools.

Anyone can deploy an ERC-20 with any symbol, and this chain has 4,524 USDG pools and
an active launchpad.

**The `approvedTarget` allowlist in `VaultLauncher` must be keyed on address, and
every entry verified by hand.** Never resolve an asset by symbol; not in the
contracts, not in the indexer, not in the portal. A symbol-matched allowlist would
let a leader launch a "GME" vault over a memecoin priced by the real GameStop feed,
which misprices silently rather than reverting.

---

## 4. Method, so this can be re-run

```bash
RPC=https://rpc.mainnet.chain.robinhood.com          # chain id 0x1237 = 4663
FACTORY=0x1f7d7550B1b028f7571E69A784071F0205FD2EfA   # cast call $ROUTER 'factory()(address)'
ROUTER=0xcaf681a66d020601342297493863e78c959e5cb2    # SwapRouter02
USDG=0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168      # 6dp, "Global Dollar"
WETH=0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73
```

1. `eth_getLogs` on the factory for `PoolCreated(address,address,uint24,int24,address)`
   (topic0 `0x783cca1c0412dd0d695e784568c96da2e9c22ff989357a2e8b1d9b2b4e6b7118`),
   filtered server-side on USDG in topic 1, then again in topic 2.
   **Unfiltered full-range queries time out.** The token filter is what lets it
   complete in a single request.
2. Multicall3 (`0xca11bde05977b3631167028862be2a173976ca11`) `balanceOf(pool)` on
   USDG across all 4,524 pools.
3. Keep the deepest pool per counterparty token, read `symbol()`, join to
   `CHAINLINK-FEEDS-MAINNET.md`, then **verify every match by address**.

Known limits of this snapshot:

- Depth is the **USDG balance of the pool contract**, not concentrated liquidity
  within a tick range. It overstates what is executable near spot. Quote the real
  number through the router before sizing a vault.
- Only USDG-quoted pools were enumerated. The unfiltered WETH query timed out, so
  WETH-quoted pools are not covered.
- The ticker join is exact, so `ETH`↔`WETH` and `BTC`↔`WBTC` do not match
  automatically. WETH is listed above by hand; WBTC was not checked.
- Blockscout was not used: its API sits behind a bot challenge. Everything here
  comes from the RPC.

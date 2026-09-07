# Zorpha (ZOR): evidence pack for Blockaid false-positive review

**Token:** ZOR (Zorpha) `0x9684AFe2422a0B03719201c78959b6B70e8d4ae8`
**Chain:** Robinhood Chain, chain id 4663 (Arbitrum Orbit L2, ETH gas token)
**Explorer:** https://robinhoodchain.blockscout.com
**Website:** https://zorpha.xyz
**Flag under appeal:** "Impersonates another token"

Every figure below was read from chain state and can be reproduced with
`eth_call` against `https://rpc.mainnet.chain.robinhood.com/rpc`.

---

## 1. Why the impersonation flag appears to be a false positive

There is no token named "Zorpha" on CoinGecko, and no other exact `ZOR`
symbol. The nearest string matches are ZORA, ZORO and ZORBY, which suggests a
name-similarity heuristic rather than an actual duplicate or clone.

Zorpha is not a copy of any token. It is the governance and fee-capture token
of an asset-management protocol with nine deployed contracts, a live product
holding deposits, and a published whitepaper.

## 2. Contract verification

All nine protocol contracts are source-verified on the chain's Blockscout
explorer. Verified at the time of writing by querying
`/api/v2/smart-contracts/<address>` and confirming a contract name is returned.

| Contract | Address |
|---|---|
| Zorpha (ZOR token) | `0x9684AFe2422a0B03719201c78959b6B70e8d4ae8` |
| Timelock | `0x813D69B8e1DBE2E08bcB892BE203A6BCE99b36Fc` |
| ZorphaVesting | `0x81613D9914F7b4c02c897941757a99BC191De88e` |
| ProtocolTreasury | `0x3D9FE37DC0D08BeD0CD48c74Cb344064df9fB3C6` |
| ZorphaBuyback | `0x91991311d353B530c497eC452B91C90CF6996c17` |
| InsuranceFund | `0x9D3B787a3492b4fe6D2a2C12062a4164263522Fd` |
| MerkleDistributor | `0x1045AeCaCad091eC791815Be8c28DA12Ed94D4E3` |
| VaultFactory | `0xAc444502A16602EAadF8720Fa6fD8A8A092e8A3D` |
| VaultLauncher | `0x9eD12842A222aeD986E768b3D50aDCf89691159A` |

## 3. Token safety properties

Fixed supply of 1,000,000,000, confirmed by `totalSupply()`.

The following functions were probed against the token and all revert, i.e.
they do not exist on the contract:

| Function | Result |
|---|---|
| `mint(address,uint256)` | absent |
| `pause()` | absent |
| `blacklist(address)` | absent |
| `setBlacklist(address,bool)` | absent |
| `upgradeTo(address)` | absent |
| `owner()` | absent |

There is no mint function, no pause, no blocklist, no transfer hook, no
upgrade path and no owner. Supply cannot be increased and transfers cannot be
censored by anyone, including the team.

## 4. Distribution, read from chain state

| Holder | ZOR | Note |
|---|---|---|
| ZorphaVesting | 800,000,000 | locked, see below |
| InsuranceFund | 40,000,000 | governance release only |
| Governance Safe | 96,311,116 | treasury and operations |
| ZOR/USDG pool | 36,255,384 | protocol-owned liquidity |
| MerkleDistributor | 0 | Season 1 tranche claimed by governance |

The vesting schedule for the governance Safe reads `revocable = false`. The
800,000,000 lock is a 180-day cliff followed by linear release to day 1095 and
cannot be cancelled or clawed back by anyone, including the team.

## 5. Governance

- Governance is a Safe multisig at `0xC75E64Ccf3ce6E2F40939Ab58255681769BcF8C4`
  with a **2-of-2** threshold.
- Privileged protocol actions route through a Timelock with a minimum delay of
  **172,800 seconds (48 hours)**, so every admin action is visible on chain
  before it can settle.

## 6. Live product

The protocol is not a token alone. A yield vault is deployed and holding
deposits:

- Vault (ERC-4626, "Zorpha Steakhouse USDG" / zsUSDG):
  `0x3829bC787d4eB15Ec855A6cA33e1492a9103d130`
- First-loss escrow: `0x96F36f4Cf1344A61d0cc4b965dDFc889200B6a10`, funded with
  **90.00 USDG** of the team's own capital, paid to the vault ahead of
  depositors on a shortfall.
- The vault routes to Steakhouse USDG, a third-party ERC-4626 vault holding
  approximately $446,000,000.

## 7. Liquidity

- Uniswap v3 ZOR/USDG 0.3% pool: `0x42AeA5CF1534498Db2f66F14bB9B9BeD2aB98d8d`
- Holding 36,255,384 ZOR and 572.42 USDG at the time of writing.
- This is an official Uniswap v3 deployment on chain 4663, not a fork. The
  factory, SwapRouter02 and NonfungiblePositionManager match the addresses
  published in Uniswap's own Robinhood Chain deployment documentation.

## 8. Security assessments, stated plainly

**Zorpha has not had a third-party audit.** The contracts were deployed to
mainnet unaudited and remain unaudited. We are not claiming otherwise.

What exists instead, offered as evidence rather than as a substitute:

- All nine contracts are source-verified and publicly readable.
- The token has no privileged functions at all (section 3).
- The supply lock is enforced on chain and is non-revocable (section 4).
- The protocol's published whitepaper contains a "What is not built" section
  that states the absence of an audit, the absence of a Governor contract, and
  that only one of three described vault types is deployed to mainnet.

## 9. Official links

- Website: https://zorpha.xyz
- Whitepaper: https://zorpha.xyz/whitepaper
- Tokenomics and on-chain custody: https://zorpha.xyz/token
- X: https://x.com/ZorphaProtocol
- GeckoTerminal (token info submission reviewed and approved):
  https://www.geckoterminal.com/robinhood/pools/0x42aea5cf1534498db2f66f14bb9b9bed2ab98d8d
- Explorer: https://robinhoodchain.blockscout.com/address/0x9684AFe2422a0B03719201c78959b6B70e8d4ae8

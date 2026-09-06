# Listing submissions: DexScreener and Blockscout

Everything needed to fill in the two token-profile forms, verified live on
2026-09-06. Both forms sit behind Cloudflare bot challenges, so they have to be
filled in by hand in a browser.

## The wallet

Blockscout verifies ownership against the **contract deployer**, because
`Zorpha` is `ERC20Votes, ERC20Permit` with no `owner()`, no admin role and no
mint function — there is no other authority to check against.

    deployer: 0x90D5fE6a51CbDA18C3960966D5830Ba03B4fFB02

Signing a message costs no gas, so that wallet's 0.00052 ETH is irrelevant.
Connect it, sign, done. It is not a Safe owner and holds no funds — nothing is
at risk in signing.

## Token facts

| field | value |
| --- | --- |
| Name | Zorpha |
| Symbol | ZOR |
| Decimals | 18 |
| Address | `0x9684AFe2422a0B03719201c78959b6B70e8d4ae8` |
| Chain | Robinhood Chain (4663) |
| Total supply | 1,000,000,000 (fixed, minted in constructor, no mint function) |
| Category | DeFi / Asset management |

## Links to submit

    Website       https://www.zorpha.xyz
    X (Twitter)   https://x.com/ZorphaProtocol
    Whitepaper    https://www.zorpha.xyz/whitepaper
    Docs/blog     https://www.zorpha.xyz/writing
    App/portal    https://www.zorpha.xyz/portal
    GitHub        https://github.com/edgeza/zorpha

**Submit the GitHub link.** UPDATED 6 Sep 2026: the repository was made public
that morning — the API reports `private: false` — so the link now resolves for
anonymous visitors and is worth including. For a project whose whole claim is
that its record can be checked rather than taken on trust, readable source is
among the strongest signals a listing can carry.

This section previously said the opposite, and the earlier Blockscout,
CoinGecko and GeckoTerminal submissions were filed with the GitHub field blank
on that basis. All three were still in review when the repo went public, and
Blockscout and GeckoTerminal both allow a pending request to be amended, so the
link should be added to each rather than waiting for a re-submission.

The original reasoning still holds whenever the link is dead: a "source code"
link that 404s is worse than no link, which is why the whitepaper page removed
its own. What changed is the fact, not the rule.

## Images (all live, all 200)

    64x64      https://www.zorpha.xyz/zorpha-64.png
    128x128    https://www.zorpha.xyz/zorpha-128.png
    256x256    https://www.zorpha.xyz/zorpha-256.png     <- use for both icons
    banner     https://www.zorpha.xyz/zorpha-banner.png  1280x430 (~2.98:1)

DexScreener's header slot is 3:1. The banner is 1280x430, which is 2.977:1 —
it will be cropped by about three pixels vertically. Not worth re-cutting.

## Short description (DexScreener, ~245 chars)

> Curated ERC-4626 vaults on Robinhood Chain where every rebalance is signed
> onchain and published as a public receipt, so a track record can be audited
> rather than asserted. Fixed 1,000,000,000 supply, no mint function,
> 800,000,000 locked non-revocably.

## Long description (Blockscout)

> Zorpha runs curated investment vaults on Robinhood Chain where a manager's
> decisions are cryptographically committed onchain and publicly
> reconstructible, so a track record can be audited by anyone rather than
> asserted by its owner.
>
> $ZOR is a fixed-supply ERC-20 with no mint function and no admin: the entire
> 1,000,000,000 supply was minted in the constructor. 800,000,000 is locked in
> a non-revocable vesting contract. Protocol fees split 50/50 between an onchain
> buyback-and-burn and operations, and every admin action passes through a
> 48-hour timelock.
>
> The first live vault, zsUSDG, routes USDG into Steakhouse USDG and carries a
> first-loss escrow that absorbs losses ahead of depositors.

## Supporting detail if a form asks for it

All nine mainnet contracts are source-verified on the explorer:

    Zorpha ($ZOR)      0x9684AFe2422a0B03719201c78959b6B70e8d4ae8
    Timelock           0x813D69B8e1DBE2E08bcB892BE203A6BCE99b36Fc
    ZorphaVesting      0x81613D9914F7b4c02c897941757a99BC191De88e
    ProtocolTreasury   0x3D9FE37DC0D08BeD0CD48c74Cb344064df9fB3C6
    ZorphaBuyback      0x91991311d353B530c497eC452B91C90CF6996c17
    InsuranceFund      0x9D3B787a3492b4fe6D2a2C12062a4164263522Fd
    MerkleDistributor  0x1045AeCaCad091eC791815Be8c28DA12Ed94D4E3
    VaultFactory       0xAc444502A16602EAadF8720Fa6fD8A8A092e8A3D
    VaultLauncher      0x9eD12842A222aeD986E768b3D50aDCf89691159A

    zsUSDG vault       0x3829bC787d4eB15Ec855A6cA33e1492a9103d130
    ZOR/USDG 0.3% pool 0x42AeA5CF1534498Db2f66F14bB9B9BeD2aB98d8d

## Support email

Left blank deliberately. Both profiles are public, so whatever address goes here
gets scraped. Use a role address (support@ / hello@ on the zorpha.xyz domain)
rather than a personal inbox.

---

# CoinGecko submission

Verified 2026-09-05. Form: https://www.coingecko.com/en/coins/new

## Prerequisites — both already satisfied

- **CoinGecko has the chain as an asset platform**: `id: "robinhood"`,
  `chain_identifier: 4663`. A contract-linked listing is therefore possible.
- **GeckoTerminal already indexes the pool** as `ZOR / USDG 0.3%`
  (`/networks/robinhood/pools/0x42AeA5CF1534498Db2f66F14bB9B9BeD2aB98d8d`),
  reserve $629, 24h volume $2,712, 7 buyers / 8 sellers.

## Form fields

| field | value |
| --- | --- |
| Coin name | Zorpha |
| Symbol | ZOR |
| Asset platform / chain | Robinhood (chain id 4663) |
| Contract address | `0x9684AFe2422a0B03719201c78959b6B70e8d4ae8` |
| Website | https://www.zorpha.xyz |
| Whitepaper | https://www.zorpha.xyz/whitepaper |
| Explorer | https://robinhoodchain.blockscout.com/token/0x9684AFe2422a0B03719201c78959b6B70e8d4ae8 |
| Where traded | https://www.geckoterminal.com/robinhood/pools/0x42aea5cf1534498db2f66f14bb9b9bed2ab98d8d |
| X | https://x.com/ZorphaProtocol |
| Contact email | info@zorpha.xyz |
| Logo | `public/zorpha-200.png` (200x200 PNG, generated for CoinGecko's spec) |

GitHub: `https://github.com/edgeza/zorpha` — public since 6 Sep 2026. If this
submission was filed before then with the field blank, amend it.

## Supply figures — the part that decides the outcome

    total supply       1,000,000,000
    max supply         1,000,000,000   (fixed; no mint function exists)

    ZorphaVesting        800,000,000   non-revocable lock
    MerkleDistributor     80,000,000   airdrop, unclaimed
    InsuranceFund         40,000,000   governance release only
    Safe (2-of-2)         16,311,116   treasury
    protocol-owned LP     40,360,868   all three Uniswap positions are Safe-owned

    genuine third-party   23,328,016   = 2.33% of supply     <- report THIS

**Circulating supply is the third-party figure, not the residual.** The
governance Safe and the protocol-owned liquidity are both treasury-controlled --
the Safe holds those LP NFTs and can withdraw them at will -- so neither counts
as circulating under CoinGecko's definition. `ON_CHAIN_CUSTODY` in
`lib/tokenomics.ts` uses a broader sense of the word and says so in its own note;
the two are not in conflict, but do not copy that 80,000,000 into a listing form.

**THIS NUMBER MOVES. Recompute it before every submission.** It was 4,025,166 on
5 Sep and 23,328,016 the next morning -- a 5.8x change from a single $198 buy,
because at this size one purchase is a large fraction of the float. Any earlier
submission quoting 4,025,166 is now understated by roughly 19,300,000 tokens and
should be amended.

Recompute with:

    total supply
      - ZorphaVesting        0x81613D9914F7b4c02c897941757a99BC191De88e
      - MerkleDistributor    0x1045AeCaCad091eC791815Be8c28DA12Ed94D4E3
      - InsuranceFund        0x9D3B787a3492b4fe6D2a2C12062a4164263522Fd
      - governance Safe      0xC75E64Ccf3ce6E2F40939Ab58255681769BcF8C4
      - ZOR/USDG pool        0x42AeA5CF1534498Db2f66F14bB9B9BeD2aB98d8d
      = circulating

Every one of those is a plain `balanceOf` on the ZOR contract, so the figure can
always be rebuilt from chain rather than trusted from this file.

## Honest read on the odds

Everything procedural is in place. Distribution is thin but no longer nil:
2.33% of supply sits with four external addresses, and on 6 Sep one of them --
`0x44e4208f7806e009beff792f7c323ff1b359d308` -- bought 19,302,849 ZOR for $198
unprompted and has held it since. That is the first buy on this pool that was
not a bot round-tripping within the hour, and it arrived the day after the pool
became tradeable at a sane slippage.

This paragraph previously read "every trader who has bought so far has
round-tripped and left", which was true when written and stopped being true the
next morning. CoinGecko weighs genuine holder distribution and organic volume,
so the distinction matters to the application: one holder who stayed is a
different claim from none.

Submitting is free and a rejection costs little, so it is a reasonable thing to
try. But the lever that changes the answer is more holders like that one, not a
better form.

## Name collision — state the canonical contract explicitly

A GeckoTerminal search for "zorpha" returns FOUR pools. Only the first is real:

    ZOR / USDG 0.3%   uniswap-v3   0x42aea5cf...8d8d   token 0x9684afe2...4ae8   <- REAL
    ZORPHA / WETH     pons-v2      0xa0a19ed2...9986   token 0x4817b927...05cd
    ZORPHA / WETH     pons-v2      0xbca55eb7...1f74   token 0x684e5dd3...5fe8
    ZOR / USDG 1%     uniswap-v3   0xd31aac5b...c237   token 0x9684afe2...4ae8   <- dead pool

The two `pons-v2` entries are separate ERC-20s named "Zorpha", symbol "ZORPHA",
1,000,000,000 supply each, both created 3 Sep 2026 about two minutes apart. Pons
mints its own token rather than listing an existing one, which is why ZOR was
never eligible there.

Their displayed liquidity of ~$4,090 and ~$4,139 is an artifact: GeckoTerminal
values the unsold token side at the bootstrap price. The pools actually hold
**0.000576 ETH and 0.000024 ETH — $1.49 combined at $2,483/ETH.** There is
nothing to recover from them.

The fourth entry is the retired 1% pool, drained to zero liquidity, which
GeckoTerminal renders with a nonsense reserve above $999T and a stale price of
$0.0000427 against the real $0.0000087.

**Consequence:** a newcomer searching the project name sees four results, and the
genuine one displays the *lowest* liquidity of the four. Every listing form that
asks for a contract address should therefore name
`0x9684AFe2422a0B03719201c78959b6B70e8d4ae8` explicitly, and the site should
state the canonical address somewhere a person checks before buying.

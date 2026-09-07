/**
 * What is actually deployed on Robinhood Chain mainnet, as distinct from what
 * exists in this repository.
 *
 * The whitepaper describes the protocol as designed, and as it ran on testnet
 * 46630 where the full stack was deployed. Mainnet launched on the minimal
 * path: the token, treasury, vesting and the yield-vault factory, without the
 * oracle, the strategy executor or either priced vault type. A reader with a
 * block explorer finds that kind of gap in about ninety seconds, so the
 * document states it rather than being caught by it.
 *
 * On 6 September 2026 the first priced vault joined it. The oracle gap was
 * closed by removing the requirement rather than funding it: a Uniswap V3
 * time-weighted average of the pool the vault trades in needs no updater set
 * and no signing key. So MedianOracle and the spot vault left the list below,
 * and the strategy executor and the rotation vault remain on it.
 */

export const MAINNET = {
  chainId: 4663,
  chainName: 'Robinhood Chain',
  launchedOn: '4 September 2026',
} as const;

/**
 * Live on mainnet.
 *
 * Source verification is a separate step from deployment on this chain, and it
 * is unreliable enough to need its own script: see
 * sidequest-protocol/contracts/script/verify-mainnet.sh, and the note that the
 * explorer's API answers 429 or 500 far more often than it answers 200. So this
 * list is what EXISTS on 4663, which is checkable from the chain alone, rather
 * than what the explorer has finished indexing. Verify a given address by
 * clicking through; do not read membership here as a verification claim.
 */
export const DEPLOYED_ON_MAINNET: { name: string; address: string; role: string }[] = [
  { name: 'Zorpha ($ZOR)', address: '0x9684AFe2422a0B03719201c78959b6B70e8d4ae8', role: 'Fixed-supply token, no mint function' },
  { name: 'Timelock', address: '0x813D69B8e1DBE2E08bcB892BE203A6BCE99b36Fc', role: '48-hour delay on every admin action' },
  { name: 'ZorphaVesting', address: '0x81613D9914F7b4c02c897941757a99BC191De88e', role: '800,000,000 locked, non-revocable' },
  { name: 'ProtocolTreasury', address: '0x3D9FE37DC0D08BeD0CD48c74Cb344064df9fB3C6', role: 'Splits fees 50/50 to buyback and operations' },
  { name: 'ZorphaBuyback', address: '0x91991311d353B530c497eC452B91C90CF6996c17', role: 'Buys $ZOR on the open market and burns it' },
  { name: 'InsuranceFund', address: '0x9D3B787a3492b4fe6D2a2C12062a4164263522Fd', role: '40,000,000, governance release only' },
  { name: 'MerkleDistributor', address: '0x1045AeCaCad091eC791815Be8c28DA12Ed94D4E3', role: 'Season 1 airdrop. Emptied 6 Sep 2026 when governance claimed the tranche' },
  { name: 'VaultFactory', address: '0xAc444502A16602EAadF8720Fa6fD8A8A092e8A3D', role: 'Deterministic vault deployment' },
  { name: 'VaultLauncher', address: '0x9eD12842A222aeD986E768b3D50aDCf89691159A', role: 'Gated launch, leader bond and first-loss escrow' },
  { name: 'UniswapV3TwapAdapter', address: '0xaBefb351777d8E68FCafa4D2F8A5848F326298cA', role: 'Prices NVDA from a 30-minute average of the pool the vault trades in. No updater, no key, no off-chain component' },
  { name: 'RobinhoodChainRouterAdapter', address: '0x8E50FC336f87b454cc44a89dA3a7267412B045dc', role: 'Routes the stock vault’s rebalances through Uniswap V3. Single hop, fixed fee tier' },
];

/** Vaults live on mainnet today. */
export const LIVE_VAULTS: { name: string; address: string; role: string }[] = [
  {
    name: 'Zorpha Steakhouse USDG (zsUSDG)',
    address: '0x3829bC787d4eB15Ec855A6cA33e1492a9103d130',
    role: 'Yield vault routing USDG to Steakhouse USDG, with a first-loss escrow ahead of depositors',
  },
  {
    name: 'Zorpha NVDA Long/Flat (zqNVDA)',
    address: '0xB129495f0ad616EdD2f28b3B49470FC1f0FAD413',
    role: 'Long or flat on tokenized NVDA. The manager sets one number: how much sits in NVDA and how much in USDG. Priced by a 30-minute average of the same Uniswap pool the trades clear against, so a price that fools the accounting also gives the attacker a bad fill',
  },
];

/**
 * Written, tested, and deployed on testnet, but NOT on mainnet. The
 * whitepaper describes these in the present tense because they exist as code;
 * this list is what stops that reading as a claim about 4663.
 */
export const NOT_ON_MAINNET: { name: string; note: string }[] = [
  { name: 'StrategyExecutor', note: 'The signed-rebalance path, where a manager signs an instruction and anyone can submit it. Not deployed because nothing on mainnet is driven that way yet: the stock vault is operated directly by the address holding its keeper role.' },
  { name: 'Rotation vault (basket)', note: 'Reweights a basket of Stock Tokens. Every leg needs its own pool deep enough to price against, and only some of them have one. Deferred until they do.' },
  { name: 'ReputationRegistry', note: 'Manager commitments. Deferred with the manager-bonding design it belongs to.' },
];

/**
 * What is actually deployed on Robinhood Chain mainnet, as distinct from what
 * exists in this repository.
 *
 * The whitepaper describes the protocol as designed, and as it ran on testnet
 * 46630 where the full stack was deployed. Mainnet took the minimal path: the
 * token, treasury, vesting and the yield-vault factory, WITHOUT the oracle,
 * the strategy executor, or the two priced vault types. A reader with a block
 * explorer finds that gap in about ninety seconds, so the document states it
 * rather than being caught by it.
 */

export const MAINNET = {
  chainId: 4663,
  chainName: 'Robinhood Chain',
  launchedOn: '4 September 2026',
} as const;

/** Live on mainnet. Every address here is source-verified on the explorer. */
export const DEPLOYED_ON_MAINNET: { name: string; address: string; role: string }[] = [
  { name: 'Zorpha ($ZOR)', address: '0x9684AFe2422a0B03719201c78959b6B70e8d4ae8', role: 'Fixed-supply token, no mint function' },
  { name: 'Timelock', address: '0x813D69B8e1DBE2E08bcB892BE203A6BCE99b36Fc', role: '48-hour delay on every admin action' },
  { name: 'ZorphaVesting', address: '0x81613D9914F7b4c02c897941757a99BC191De88e', role: '800,000,000 locked, non-revocable' },
  { name: 'ProtocolTreasury', address: '0x3D9FE37DC0D08BeD0CD48c74Cb344064df9fB3C6', role: 'Splits fees 50/50 to buyback and operations' },
  { name: 'ZorphaBuyback', address: '0x91991311d353B530c497eC452B91C90CF6996c17', role: 'Buys $ZOR on the open market and burns it' },
  { name: 'InsuranceFund', address: '0x9D3B787a3492b4fe6D2a2C12062a4164263522Fd', role: '40,000,000, governance release only' },
  { name: 'MerkleDistributor', address: '0x1045AeCaCad091eC791815Be8c28DA12Ed94D4E3', role: 'Season 1 airdrop, 80,000,000' },
  { name: 'VaultFactory', address: '0xAc444502A16602EAadF8720Fa6fD8A8A092e8A3D', role: 'Deterministic vault deployment' },
  { name: 'VaultLauncher', address: '0x9eD12842A222aeD986E768b3D50aDCf89691159A', role: 'Gated launch, leader bond and first-loss escrow' },
];

/** Vaults live on mainnet today. */
export const LIVE_VAULTS: { name: string; address: string; role: string }[] = [
  {
    name: 'Zorpha Steakhouse USDG (zsUSDG)',
    address: '0x3829bC787d4eB15Ec855A6cA33e1492a9103d130',
    role: 'Yield vault routing USDG to Steakhouse USDG, with a first-loss escrow ahead of depositors',
  },
];

/**
 * Written, tested, and deployed on testnet — but NOT on mainnet. The
 * whitepaper describes these in the present tense because they exist as code;
 * this list is what stops that reading as a claim about 4663.
 */
export const NOT_ON_MAINNET: { name: string; note: string }[] = [
  { name: 'MedianOracle', note: 'Priced vaults need it. Running one on mainnet means funding an independent updater set, which is a recurring cost the protocol does not yet carry.' },
  { name: 'StrategyExecutor', note: 'The signed-rebalance path. Not deployed because the vaults it drives are not deployed.' },
  { name: 'Spot vault (long/flat)', note: 'Prices a Stock Token against cash, so it depends on the oracle above.' },
  { name: 'Rotation vault (basket)', note: 'Reweights a basket against a base asset, so it depends on the oracle above.' },
  { name: 'ReputationRegistry', note: 'Manager commitments. Deferred with the manager-bonding design it belongs to.' },
];

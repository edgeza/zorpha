/**
 * Zorpha ($ZOR) token facts and published allocation.
 *
 * This file is the SINGLE SOURCE OF TRUTH for every supply number rendered on
 * the marketing site. The same basis points are hardcoded in
 * `sidequest-protocol/contracts/script/DeployZorphaToken.s.sol`, which asserts
 * they sum to 10_000 and that the distribution consumes exactly MAX_SUPPLY.
 * If you change a number here, change it there too. The deploy script will
 * refuse to run if the two ever disagree on the total.
 */

export const TOKEN = {
  name: 'Zorpha',
  symbol: 'ZOR',
  ticker: '$ZOR',
  decimals: 18,
  /** Fixed at deploy. No mint function exists on the contract. */
  maxSupply: 1_000_000_000,
  chain: 'Robinhood Chain',
  standard: 'ERC-20 · ERC-2612 Permit · ERC-5805 Votes',
  domain: 'zorpha.xyz',
} as const;

/**
 * What the chain actually holds TODAY, which is not the same thing as the
 * allocation policy below.
 *
 * The policy describes six buckets with separate cliffs. On mainnet the
 * treasury, contributor and backer buckets were locked as a SINGLE
 * non-revocable schedule to the governance Safe rather than as separate
 * per-cohort schedules, so the site must not imply four independent cliffs
 * exist onchain when one does. These figures are what a block explorer shows.
 */
export const ON_CHAIN_CUSTODY: {
  label: string;
  tokens: number;
  note: string;
  address: string | null;
}[] = [
  {
    label: 'Locked in vesting',
    tokens: 800_000_000,
    note: '180-day cliff, then linear release to day 1095. Non-revocable: the schedule cannot be cancelled or clawed back.',
    address: '0x81613D9914F7b4c02c897941757a99BC191De88e',
  },
  {
    /**
     * Claimed out of the distributor, NOT distributed.
     *
     * The deployed Merkle tree had one leaf naming the governance Safe, so the
     * whole tranche was claimable by governance and nobody else. Claiming moved
     * custody from the distributor to the Safe and changed nothing about who
     * the tokens are for.
     *
     * It stays its own line rather than folding into Circulating. The Safe
     * holds it earmarked for Season 1, and counting earmarked tokens as
     * circulating would overstate the float by 8% of supply -- which is the
     * number a reader is most likely to act on.
     */
    label: 'Season 1 airdrop, held by governance',
    tokens: 80_000_000,
    note:
      'Claimed from the Merkle distributor by the governance Safe, its sole eligible claimant. Not yet distributed: per-wallet Season 1 criteria are unpublished, and paying them out needs a second distributor built from a real recipient list.',
    address: '0xC75E64Ccf3ce6E2F40939Ab58255681769BcF8C4',
  },
  {
    label: 'Insurance fund',
    tokens: 40_000_000,
    note: 'Released only by governance, only against a verified shortfall.',
    address: '0x9D3B787a3492b4fe6D2a2C12062a4164263522Fd',
  },
  {
    label: 'Circulating',
    tokens: 80_000_000,
    note: 'Governance Safe, protocol-owned liquidity and holders.',
    address: null,
  },
];

/** Circulating share of max supply, measured onchain rather than planned. */
export const CIRCULATING_PCT =
  (ON_CHAIN_CUSTODY.find((c) => c.label === 'Circulating')!.tokens / 1_000_000_000) * 100;

if (ON_CHAIN_CUSTODY.reduce((s, c) => s + c.tokens, 0) !== 1_000_000_000) {
  throw new Error('Zorpha: ON_CHAIN_CUSTODY must sum to max supply.');
}

export type UnlockShape = 'tge' | 'cliff-linear' | 'seasonal' | 'locked';

export interface Allocation {
  key: string;
  label: string;
  /** Basis points of max supply. All entries must sum to 10_000. */
  bps: number;
  /** Portion unlocked at TGE, in bps of max supply. */
  tgeBps: number;
  cliffMonths: number;
  vestMonths: number;
  shape: UnlockShape;
  /** Tailwind-friendly CSS custom property name for charts. */
  color: string;
  rationale: string;
}

export const ALLOCATIONS: Allocation[] = [
  {
    key: 'community',
    label: 'Community & Ecosystem',
    bps: 3800,
    tgeBps: 800,
    cliffMonths: 0,
    vestMonths: 48,
    shape: 'seasonal',
    color: 'var(--zor-500)',
    rationale:
      'The largest single bucket, and deliberately so. 8% of supply is already funded on-chain for the Season 1 airdrop, held by governance until the season criteria are published and voted. The remaining 30% is released season by season against published criteria, each season approved by governance rather than dripped automatically. Emissions that nobody votes for are just inflation with extra steps.',
  },
  {
    key: 'treasury',
    label: 'DAO Treasury',
    bps: 2000,
    tgeBps: 0,
    cliffMonths: 6,
    vestMonths: 48,
    shape: 'cliff-linear',
    color: 'var(--verified-500)',
    rationale:
      'Funds audits, insurance top-ups, integrations and market operations. Held by the governance Safe and spendable only through the 48-hour Timelock, so every treasury movement is visible on-chain before it settles.',
  },
  {
    key: 'contributors',
    label: 'Core Contributors',
    bps: 1700,
    tgeBps: 0,
    cliffMonths: 12,
    vestMonths: 48,
    shape: 'cliff-linear',
    color: 'var(--cyan-500)',
    rationale:
      'Nothing at launch, nothing for twelve months, then linear to month 48. Contributors are the last cohort to become liquid, which is the only version of this line item that means anything. Unvested tokens are held by the vesting contract and carry zero voting weight, nobody votes with tokens they have not earned.',
  },
  {
    key: 'liquidity',
    label: 'Protocol-Owned Liquidity',
    bps: 1300,
    tgeBps: 1300,
    cliffMonths: 0,
    vestMonths: 0,
    shape: 'tge',
    color: 'var(--amber-500)',
    rationale:
      'Fully unlocked at launch and paired into the primary market, owned by the protocol rather than rented from mercenary LPs. Thin books are what turn ordinary unlock events into 40% candles, so this is priced as insurance, not as a cost.',
  },
  {
    key: 'backers',
    label: 'Early Backers',
    bps: 800,
    tgeBps: 0,
    cliffMonths: 12,
    vestMonths: 36,
    shape: 'cliff-linear',
    color: 'var(--magenta-500)',
    rationale:
      'Intentionally small. A thin backer allocation on a 12-month cliff keeps the cap table from becoming the protocol’s largest structural seller, and keeps governance in the hands of people who use the product.',
  },
  {
    key: 'insurance',
    label: 'Insurance Fund',
    bps: 400,
    tgeBps: 0,
    cliffMonths: 0,
    vestMonths: 0,
    shape: 'locked',
    color: 'var(--danger-500)',
    rationale:
      'Locked in the InsuranceFund contract and payable only by governance against a verified shortfall: an exploit, an oracle failure, bad debt. It is not a marketing line: it is the reason a depositor has something to be made whole from.',
  },
];

// ─── Derived values. Computed, never hand-typed. ────────────────────────────

export const BPS_TOTAL = ALLOCATIONS.reduce((sum, a) => sum + a.bps, 0);
export const TGE_BPS_TOTAL = ALLOCATIONS.reduce((sum, a) => sum + a.tgeBps, 0);

export function tokensFor(bps: number): number {
  return (TOKEN.maxSupply * bps) / 10_000;
}

export function pctFor(bps: number): number {
  return bps / 100;
}

/** Circulating supply at launch, as a percentage of max supply. */
export const FLOAT_AT_LAUNCH_PCT = pctFor(TGE_BPS_TOTAL);

/** Share of supply held by insiders (contributors + backers). */
export const INSIDER_PCT = pctFor(
  ALLOCATIONS.filter((a) => a.key === 'contributors' || a.key === 'backers').reduce(
    (s, a) => s + a.bps,
    0,
  ),
);

if (BPS_TOTAL !== 10_000) {
  throw new Error(
    `Zorpha tokenomics: allocations sum to ${BPS_TOTAL} bps, expected 10000. ` +
      'Fix lib/tokenomics.ts and DeployZorphaToken.s.sol together.',
  );
}

// ─── Value accrual ─────────────────────────────────────────────────────────

export const FEE_SPLIT = {
  buybackBps: 5000,
  operationsBps: 5000,
} as const;

/**
 * Emission schedule for the seasonal ecosystem tail, in tokens per year.
 * Used by the supply-curve chart. Year 0 is TGE.
 */
export function supplyCurve(): { year: number; circulating: number }[] {
  const points: { year: number; circulating: number }[] = [];
  for (let year = 0; year <= 5; year++) {
    let circulating = 0;
    for (const a of ALLOCATIONS) {
      const total = tokensFor(a.bps);
      const tge = tokensFor(a.tgeBps);
      circulating += tge;

      const remaining = total - tge;
      if (remaining <= 0) continue;

      const months = year * 12;
      if (a.shape === 'locked') continue;

      if (months <= a.cliffMonths) continue;
      const vested = Math.min(1, months / Math.max(a.vestMonths, 1));
      circulating += remaining * vested;
    }
    points.push({ year, circulating: Math.min(circulating, TOKEN.maxSupply) });
  }
  return points;
}

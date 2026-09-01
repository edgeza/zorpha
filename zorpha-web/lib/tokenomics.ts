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
      'The largest single bucket, and deliberately so. 8% of supply unlocks at launch as the Season 1 airdrop to early depositors and vault managers. The remaining 30% is released season by season against published criteria, each season approved by governance rather than dripped automatically. Emissions that nobody votes for are just inflation with extra steps.',
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

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
/**
 * The Season 1 tranche as originally claimed, in whole tokens. A ceiling on the
 * reserve, not the reserve itself: it only binds if the Safe is ever topped up
 * beyond what it holds today, which would be a new tranche and a policy change.
 */
export const SEASON_1_RESERVE = 80_000_000;

/**
 * The governance Safe's OWN holding, excluding the Season 1 tranche.
 *
 * THE ONE NUMBER HERE THAT IS NOT ON CHAIN, and it cannot be. The Safe's
 * balance is readable by anyone; which part of it is spoken for is a policy
 * fact that lives in the Season 1 criteria, not in a contract. Splitting the
 * balance needs one of the two halves declared.
 *
 * The FLOAT is declared rather than the reserve, deliberately, because it is
 * the stable half. The reserve shrinks every time Season 1 pays out; the float
 * only moves if governance spends its own treasury. Declaring the shrinking
 * half and capping it against the balance looks correct and is not: a
 * 30,000,000 payout would drop the reserve by only 13,688,884, because the cap
 * quietly absorbs the float into the reserve. The first version of this did
 * exactly that and the test below caught it.
 */
export const SAFE_FLOAT = 16_311_116;

export interface CustodyLine {
  label: string;
  tokens: number;
  note: string;
  address: string | null;
}

/**
 * Custody, derived from balances rather than typed in.
 *
 * WHY THIS IS A FUNCTION NOW
 *
 * It was four hardcoded numbers with a module-level assertion that they summed
 * to max supply. Those matched the chain on the day they were written and had
 * nothing behind them afterwards. The moment Season 1 pays out, the reserve
 * line overstates what the Safe holds and the circulating line understates the
 * float, on a page headed "What the chain actually holds" and lede'd "this is
 * custody, readable from any block explorer". The numbers would have been wrong
 * in the one place the copy tells a reader to go and check.
 *
 * Vesting and the insurance fund are read too, not just the Safe. Vesting is
 * the larger risk of the two: the schedule has a 180-day cliff from the
 * 4 September 2026 launch and then releases linearly, so that balance starts
 * falling in March 2027 whether or not anyone updates this file.
 *
 * @param balances whole-token balances read from the chain. Omit to get the
 *        last measured figures, which is what the build-time consumers use.
 */
export function custodyFrom(balances?: {
  vesting: number;
  safe: number;
  insurance: number;
}): CustodyLine[] {
  const b = balances ?? LAST_MEASURED;
  // What the Safe holds beyond its own float is the earmarked tranche. Floored
  // at zero so a Safe drawn below its float reports no reserve rather than a
  // negative one, and capped so a top-up cannot silently inflate the claim.
  const reserve = Math.max(0, Math.min(SEASON_1_RESERVE, b.safe - SAFE_FLOAT));
  // Everything not locked, not in the insurance fund and not earmarked. The
  // Safe's own float counts as circulating, which the note below says out loud.
  const circulating = TOKEN.maxSupply - b.vesting - b.insurance - reserve;

  return [
    {
      label: 'Locked in vesting',
      tokens: b.vesting,
      note: '180-day cliff, then linear release to day 1095. Non-revocable: the schedule cannot be cancelled or clawed back.',
      address: '0x81613D9914F7b4c02c897941757a99BC191De88e',
    },
    {
      label: 'Community airdrop reserve, held by governance',
      tokens: reserve,
      note:
        'Claimed from the Merkle distributor by the governance Safe, its sole eligible claimant. Not yet distributed: the Season 1 criteria are published and the 90 day window is open, but paying allocations out needs a second distributor built from the recipient list the snapshot produces once the window closes.',
      address: '0xC75E64Ccf3ce6E2F40939Ab58255681769BcF8C4',
    },
    {
      label: 'Insurance fund',
      tokens: b.insurance,
      note: 'Released only by governance, only against a verified shortfall.',
      address: '0x9D3B787a3492b4fe6D2a2C12062a4164263522Fd',
    },
    {
      label: 'Circulating',
      tokens: circulating,
      note:
        'The governance Safe excluding the Season 1 tranche above, protocol-owned liquidity and holders.',
      address: null,
    },
  ];
}

/**
 * The balances as last read from chain, 7 September 2026.
 *
 * Not a fallback in the "good enough" sense. Three consumers cannot await a
 * network read: `metadata` on two pages, the edge-runtime opengraph image, and
 * the client-side Hero. They get these, and `lib/tokenomics.test.ts` fails the
 * build if they have drifted from the chain, so a stale figure is a red CI job
 * rather than a quiet wrong number on a social card.
 */
export const LAST_MEASURED = {
  vesting: 800_000_000,
  safe: 96_311_116,
  insurance: 40_000_000,
} as const;

/** Custody as last measured. Prefer `custodyFrom(live)` where you can await. */
export const ON_CHAIN_CUSTODY: CustodyLine[] = custodyFrom();

/** Circulating share of max supply, measured onchain rather than planned. */
export const CIRCULATING_PCT =
  (ON_CHAIN_CUSTODY.find((c) => c.label === 'Circulating')!.tokens / TOKEN.maxSupply) * 100;

if (ON_CHAIN_CUSTODY.reduce((s, c) => s + c.tokens, 0) !== TOKEN.maxSupply) {
  throw new Error('Zorpha: custody must sum to max supply.');
}

/**
 * The vesting schedule THE CHAIN ENFORCES, as read from
 * ZorphaVesting.scheduleOf() on 7 September 2026.
 *
 * WHY THIS IS STATED SEPARATELY FROM THE POLICY BELOW
 *
 * The allocation policy describes six buckets, four of them with their own
 * cliff. On mainnet there is exactly one schedule: `beneficiaryCount()`
 * returns 1, and its beneficiary is the governance Safe. Everything except
 * protocol-owned liquidity and the insurance fund went into that single
 * non-revocable schedule.
 *
 * So a reader comparing the two sections found the contributor and backer
 * cliffs quoted as 12 months while the chain enforces 180 days on the whole
 * 800M, and reasonably asked which one was true. Both were, of different
 * things, and the page did not say which was which. The per-bucket cliffs are
 * commitments the Safe honours by choice; the figures here are the only ones a
 * contract will refuse to break.
 *
 * The cliff release is DERIVED, not written down. ZorphaVesting measures
 * `vestDuration` from `startTime` and does not add the cliff to it, so at the
 * cliff the whole elapsed fraction becomes claimable at once. Hardcoding that
 * number would let it drift away from the two it comes from.
 */
export const VESTING_ONCHAIN = {
  contract: '0x81613D9914F7b4c02c897941757a99BC191De88e',
  /** Sole beneficiary: the 2-of-2 governance Safe. */
  beneficiary: '0xC75E64Ccf3ce6E2F40939Ab58255681769BcF8C4',
  tokens: 800_000_000,
  /** Schedule start, matching the 4 September 2026 launch. */
  start: '2026-09-04',
  cliffDays: 180,
  /** Total term measured from `start`, NOT additive with the cliff. */
  vestDays: 1095,
  cliffEnds: '2027-03-03',
  fullyVested: '2029-09-03',
  revocable: false,
} as const;

/**
 * Tokens that become claimable in a single block when the cliff passes.
 *
 * 180/1095 of the schedule, about 16.4%, which is larger than the entire
 * protocol-owned-liquidity bucket. Material enough that leaving it to be
 * inferred from two durations was itself a disclosure failure.
 */
export const VESTING_CLIFF_RELEASE = Math.floor(
  (VESTING_ONCHAIN.tokens * VESTING_ONCHAIN.cliffDays) / VESTING_ONCHAIN.vestDays,
);

/** Tokens released per day after the cliff, on the same linear schedule. */
export const VESTING_DAILY_RELEASE = Math.round(
  VESTING_ONCHAIN.tokens / VESTING_ONCHAIN.vestDays,
);

/**
 * Protocol-owned liquidity ACTUALLY committed to the pool, summed from the
 * four Mint events on the ZOR/USDG pool and net of the one Burn.
 *
 * The policy bucket is 130,000,000. This is what reached a position, and the
 * gap is not a rounding difference. Stated because the pool is public: anyone
 * can sum the same events, and a page claiming the bucket was "paired at
 * launch" while the pool holds a third of it is a page that loses the argument
 * on inspection.
 *
 * `quoteUsdg` is the number that actually governs what a buyer experiences.
 * Depth, not token count, is what decides whether a purchase moves the price.
 */
export const POL_ONCHAIN = {
  /** ZOR deposited across the four mints, net of the single burn. */
  zorPaired: 45_226_945,
  /** Every USDG ever placed on the quote side, net of the burn's return. */
  quoteUsdg: 576,
  positionManager: '0x73991a25c818bf1f1128deaab1492d45638de0d3',
  /** Uniswap V3 position NFTs, all held by the governance Safe. */
  positions: [1_034_952, 1_045_817, 1_052_227, 1_052_234],
  /** Position 1045817 was closed once its ZOR side had been bought out. */
  positionsClosed: [1_045_817],
  measured: '2026-09-07',
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
  /**
   * Whether a contract enforces `cliffMonths` and `vestMonths`, or whether
   * they are a commitment the governance Safe keeps by choice.
   *
   * Only `liquidity` and `insurance` have their own onchain home. Everything
   * else sits in the single 800M schedule described by VESTING_ONCHAIN, whose
   * cliff is 180 days for all of it, so quoting a 12-month contributor cliff
   * without this distinction told a reader something no contract will hold to.
   */
  enforcement: 'onchain' | 'policy';
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
    enforcement: 'policy',
    shape: 'seasonal',
    color: 'var(--zor-500)',
    rationale:
      'The largest single bucket, and deliberately so. 8% of supply is already funded on-chain as the community airdrop reserve, of which Season 1 allocates 8,000,000, held by governance until the window closes and a second distributor is funded against the snapshot. The remaining 30% is released season by season against published criteria, each season approved by governance rather than dripped automatically. Emissions that nobody votes for are just inflation with extra steps.',
  },
  {
    key: 'treasury',
    label: 'DAO Treasury',
    bps: 2000,
    tgeBps: 0,
    cliffMonths: 6,
    vestMonths: 48,
    enforcement: 'policy',
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
    enforcement: 'policy',
    shape: 'cliff-linear',
    color: 'var(--cyan-500)',
    rationale:
      'Nothing at launch, and the intent is nothing for twelve months, then linear to month 48. Contributors are meant to be the last cohort to become liquid, which is the only version of this line item that means anything. Note the enforcement below: this cohort has no separate contract, so the twelve months is a commitment rather than a lock. What the chain enforces on these tokens is the single 800,000,000 schedule, whose cliff is 180 days. Unvested tokens carry zero voting weight either way.',
  },
  {
    key: 'liquidity',
    label: 'Protocol-Owned Liquidity',
    bps: 1300,
    tgeBps: 1300,
    cliffMonths: 0,
    vestMonths: 0,
    enforcement: 'onchain',
    shape: 'tge',
    color: 'var(--amber-500)',
    rationale:
      'Unlocked at launch and owned by the protocol rather than rented from mercenary LPs. Only part of the bucket is deployed: 45,226,945 ZOR sits across four Uniswap V3 positions, roughly a third of the 130,000,000 allocated, and the quote side of those positions has received $576 in total. That is the real depth of the ZOR market, and it is the reason a $100 purchase moves the price by double digits. The rationale for the bucket stands, thin books are what turn ordinary unlock events into 40% candles, but the bucket is not yet doing that job and saying otherwise would be a claim the pool contradicts.',
  },
  {
    key: 'backers',
    label: 'Early Backers',
    bps: 800,
    tgeBps: 0,
    cliffMonths: 12,
    vestMonths: 36,
    enforcement: 'policy',
    shape: 'cliff-linear',
    color: 'var(--magenta-500)',
    rationale:
      'Intentionally small, so the cap table never becomes the protocol’s largest structural seller. As with contributors, the 12-month cliff is policy: these tokens are inside the same 800,000,000 schedule and the contract releases them from day 180.',
  },
  {
    key: 'insurance',
    label: 'Insurance Fund',
    bps: 400,
    tgeBps: 0,
    cliffMonths: 0,
    vestMonths: 0,
    enforcement: 'onchain',
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

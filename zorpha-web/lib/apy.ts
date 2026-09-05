/**
 * Live yield measurement for the vaults, derived from on-chain accrual state.
 *
 * Why this exists rather than a number in a config file: an APY typed into the
 * repo is wrong the day after it is typed, and this one is the figure a
 * depositor decides on. Everything here is computed from state read at request
 * time, so the site cannot drift from the chain.
 *
 * The measurement uses the underlying vault's own pending interest -- the gap
 * between the assets it has booked (`_totalAssets`, as of `lastUpdate`) and the
 * assets it would book right now (`accrueInterestView`). That gap over that
 * elapsed time is the rate, and it needs no historical state, which matters
 * because the public RPCs for chain 4663 prune archive state and refuse
 * full-range log queries.
 */

/** Seconds in a 365-day year. Annualisation basis for every figure here. */
export const SECONDS_PER_YEAR = 31_536_000;

const WAD = 10n ** 18n;
const BPS_DENOMINATOR = 10_000;

/** A single reading of a vault's interest accrual, all from the same block. */
export type AccrualSample = {
  /** Assets the vault has booked, as of `lastUpdate`. */
  storedAssets: bigint;
  /** Assets the vault would book if interest were accrued at `now`. */
  accruedAssets: bigint;
  /** When the vault last accrued interest. */
  lastUpdate: bigint;
  /** The timestamp `accruedAssets` was projected to. */
  now: bigint;
};

export type VaultApy = {
  /** The underlying's own rate, before any Zorpha fee. */
  gross: number;
  /** What a depositor keeps, after the vault's performance fee. */
  net: number;
};

/**
 * Annualise a per-second rate with continuous compounding.
 *
 * `expm1`/`log1p` rather than `(1 + r) ** SECONDS_PER_YEAR`: r is around 1e-9,
 * and `1 + r` throws away most of its significant digits before `**` ever runs.
 */
function annualise(perSecond: number): number {
  return Math.expm1(SECONDS_PER_YEAR * Math.log1p(perSecond));
}

/**
 * Gross and net APY from one accrual reading, or `null` when the reading
 * cannot support a number.
 *
 * Null is returned rather than zero on every unmeasurable input. Integer
 * truncation makes "earning nothing" and "earning too little to have moved the
 * counter yet" identical here, and a confident "0.00%" on a vault that is
 * actually paying is a worse failure than showing nothing for a few seconds --
 * callers should poll, since the gap widens on its own as time passes.
 */
export function apyFromAccrual(
  sample: AccrualSample,
  performanceFeeBps: number
): VaultApy | null {
  const { storedAssets, accruedAssets, lastUpdate, now } = sample;

  if (
    !Number.isInteger(performanceFeeBps) ||
    performanceFeeBps < 0 ||
    performanceFeeBps > BPS_DENOMINATOR
  ) {
    return null;
  }

  const elapsed = now - lastUpdate;
  if (elapsed <= 0n) return null;
  if (storedAssets <= 0n) return null;

  const interest = accruedAssets - storedAssets;
  if (interest <= 0n) return null;

  // Scale into WAD before dividing so the ratio survives operands past 2^53,
  // where converting to Number first would already have rounded them.
  const rateScaled = (interest * WAD) / (storedAssets * elapsed);
  const grossRate = Number(rateScaled) / Number(WAD);

  // The fee comes off the rate, not off the annualised figure: it is charged
  // on gains as they accrue, so it compounds against the depositor rather than
  // being deducted once at the end. The difference is small but it is real,
  // and it is in the depositor's disfavour, so it should not be rounded away.
  const netRate = grossRate * (1 - performanceFeeBps / BPS_DENOMINATOR);

  return { gross: annualise(grossRate), net: annualise(netRate) };
}

/** A rate as a percentage, e.g. 0.037492 -> "3.75%". */
export function formatApy(value: number): string {
  return `${(value * 100).toFixed(2)}%`;
}

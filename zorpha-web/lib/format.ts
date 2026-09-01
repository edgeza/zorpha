/**
 * Formatting helpers. Everything returns display-ready strings — no raw
 * BigInts, no `[object Object]`, no NaN leaking into the UI.
 */

export function formatAddress(addr: string | null | undefined, head = 4, tail = 4): string {
  if (!addr) return '—';
  if (addr.length <= head + tail + 2) return addr;
  return `${addr.slice(0, head + 2)}…${addr.slice(-tail)}`;
}

/** Exact decimal string from a raw integer amount. */
export function formatUnits(
  raw: bigint | string | number | null | undefined,
  decimals = 18,
  fractionDigits = 4,
): string {
  if (raw === null || raw === undefined) return '—';
  let value: bigint;
  try {
    value = typeof raw === 'bigint' ? raw : BigInt(raw);
  } catch {
    return '—';
  }
  const negative = value < 0n;
  if (negative) value = -value;

  const base = 10n ** BigInt(decimals);
  const whole = value / base;
  const frac = value % base;

  const wholeStr = whole.toLocaleString('en-US');
  if (fractionDigits === 0) return `${negative ? '-' : ''}${wholeStr}`;

  const fracStr = frac.toString().padStart(decimals, '0').slice(0, fractionDigits);
  const trimmed = fracStr.replace(/0+$/, '');
  return `${negative ? '-' : ''}${wholeStr}${trimmed ? `.${trimmed}` : ''}`;
}

/** Compact form for headline numbers: 1.2B, 380M, 12.5K. */
export function formatCompact(n: number | null | undefined, digits = 1): string {
  if (n === null || n === undefined || !Number.isFinite(n)) return '—';
  const abs = Math.abs(n);
  const sign = n < 0 ? '-' : '';
  if (abs >= 1e12) return `${sign}${(abs / 1e12).toFixed(digits).replace(/\.0$/, '')}T`;
  if (abs >= 1e9) return `${sign}${(abs / 1e9).toFixed(digits).replace(/\.0$/, '')}B`;
  if (abs >= 1e6) return `${sign}${(abs / 1e6).toFixed(digits).replace(/\.0$/, '')}M`;
  if (abs >= 1e3) return `${sign}${(abs / 1e3).toFixed(digits).replace(/\.0$/, '')}K`;
  return `${sign}${abs.toLocaleString('en-US')}`;
}

/** Compact form for a raw on-chain amount. */
export function formatCompactUnits(
  raw: bigint | string | number | null | undefined,
  decimals = 18,
): string {
  if (raw === null || raw === undefined) return '—';
  let value: bigint;
  try {
    value = typeof raw === 'bigint' ? raw : BigInt(raw);
  } catch {
    return '—';
  }
  // Keep 4 decimal places of precision before crossing into float, so large
  // 18-decimal balances do not lose their integer part to Number overflow.
  const scaled = Number((value * 10_000n) / 10n ** BigInt(decimals)) / 10_000;
  return formatCompact(scaled);
}

/** Parse a user-typed decimal string into a raw integer amount. */
export function parseUnits(input: string, decimals = 18): bigint | null {
  const trimmed = input.trim();
  if (!trimmed || !/^\d*\.?\d*$/.test(trimmed)) return null;
  const [whole = '0', frac = ''] = trimmed.split('.');
  if (frac.length > decimals) return null;
  const padded = frac.padEnd(decimals, '0');
  try {
    return BigInt(whole || '0') * 10n ** BigInt(decimals) + BigInt(padded || '0');
  } catch {
    return null;
  }
}

export function formatPercent(value: number | null | undefined, digits = 2): string {
  if (value === null || value === undefined || !Number.isFinite(value)) return '—';
  return `${value.toFixed(digits)}%`;
}

export function bpsToPct(bps: number | null | undefined, digits = 2): string {
  if (bps === null || bps === undefined) return '—';
  return `${(bps / 100).toFixed(digits)}%`;
}

export function formatDateTime(value: string | number | Date | null | undefined): string {
  if (value === null || value === undefined) return '—';
  const d = value instanceof Date ? value : new Date(value);
  if (Number.isNaN(d.getTime())) return '—';
  return d.toLocaleString('en-US', {
    year: 'numeric',
    month: 'short',
    day: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  });
}

export function formatDate(value: string | number | Date | null | undefined): string {
  if (value === null || value === undefined) return '—';
  const d = value instanceof Date ? value : new Date(value);
  if (Number.isNaN(d.getTime())) return '—';
  return d.toLocaleDateString('en-US', { year: 'numeric', month: 'short', day: 'numeric' });
}

/** "3 hours ago" / "in 12 days". */
export function formatRelative(value: string | number | Date | null | undefined): string {
  if (value === null || value === undefined) return '—';
  const d = value instanceof Date ? value : new Date(value);
  if (Number.isNaN(d.getTime())) return '—';

  const diffSec = Math.round((d.getTime() - Date.now()) / 1000);
  const abs = Math.abs(diffSec);
  const units: [Intl.RelativeTimeFormatUnit, number][] = [
    ['year', 31_536_000],
    ['month', 2_592_000],
    ['day', 86_400],
    ['hour', 3_600],
    ['minute', 60],
  ];
  const rtf = new Intl.RelativeTimeFormat('en-US', { numeric: 'auto' });
  for (const [unit, seconds] of units) {
    if (abs >= seconds) return rtf.format(Math.round(diffSec / seconds), unit);
  }
  return rtf.format(diffSec, 'second');
}

/** Months as a human duration: 48 -> "4 years", 18 -> "18 months". */
export function formatMonths(months: number): string {
  if (months === 0) return 'none';
  if (months % 12 === 0) {
    const years = months / 12;
    return `${years} ${years === 1 ? 'year' : 'years'}`;
  }
  return `${months} months`;
}

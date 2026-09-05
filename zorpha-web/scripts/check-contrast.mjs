#!/usr/bin/env node
/**
 * Fails the build if a UI-tier colour token drops below its WCAG threshold
 * against the void background.
 *
 * The graphic tier is deliberately absent from THRESHOLDS: those values live
 * on WebGL and gradient surfaces that carry no contrast obligation, and
 * asserting a threshold on them would be false precision.
 */
import fs from 'node:fs';

const BG = '#06060a';
const CSS = 'app/globals.css';

const THRESHOLDS = {
  '--zor-500': 3.0,
  '--verified-500': 3.0,
  '--cyan-500': 3.0,
  '--amber-500': 3.0,
  '--magenta-500': 3.0,
  '--danger-500': 3.0,
};

const hexToRgb = (h) => [1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16));

const luminance = ([r, g, b]) => {
  const f = (v) => {
    v /= 255;
    return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
  };
  return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b);
};

const contrast = (a, b) => {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
  return (hi + 0.05) / (lo + 0.05);
};

const css = fs.readFileSync(CSS, 'utf8');
const bg = hexToRgb(BG);
const failures = [];

for (const [token, min] of Object.entries(THRESHOLDS)) {
  const m = css.match(new RegExp(token + ':\\s*(#[0-9a-fA-F]{6})'));
  if (!m) {
    failures.push(token + ': not found in ' + CSS);
    continue;
  }
  const ratio = contrast(hexToRgb(m[1]), bg);
  const ok = ratio >= min;
  console.log(
    '  ' + token.padEnd(18) + ' ' + m[1] + '  contrast ' + ratio.toFixed(2) +
    '  min ' + min.toFixed(1) + '  ' + (ok ? 'ok' : 'FAIL'),
  );
  if (!ok) failures.push(token + ' (' + m[1] + ') scores ' + ratio.toFixed(2) + ', needs ' + min);
}

// A graphic-tier value must never be reachable as a UI token.
if (/--zor-500:\s*#(4700f8|8700f9)/i.test(css)) {
  failures.push('--zor-500 is set to a graphic-tier value; it governs text and borders.');
}

if (failures.length) {
  console.error('\ncontrast check FAILED:\n' + failures.map((f) => '  - ' + f).join('\n'));
  process.exit(1);
}
console.log('\n  contrast ok');

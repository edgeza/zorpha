#!/usr/bin/env node
/**
 * Fails the build if a UI-tier colour token drops below its WCAG threshold
 * against the void background.
 *
 * UI-tier colour lives in two places that must agree: the CSS custom
 * properties below (THRESHOLDS) in app/globals.css, and the `zor`/`ink`
 * scales in tailwind.config.mjs — which is what every real `text-*`,
 * `border-*`, `bg-*` and `ring-*` utility across app/components actually
 * compiles to. This script reads both files, asserts tailwind's `zor.500`
 * agrees with `--zor-500` (the plan requires the two to agree), and runs
 * every stop of both Tailwind scales through the same contrast floor as the
 * CSS custom properties.
 *
 * Body text (`text-ink-200`, set on `body` in globals.css) is held to AA
 * (4.5:1); every other UI-tier stop takes the 3.0 "large text / UI
 * component" floor.
 *
 * The graphic tier — `--zor-graphic-*` in globals.css, plus `tint` in
 * lib/brand.ts, which has no CSS custom property — is deliberately exempt
 * from those floors: those values live on WebGL and gradient surfaces that
 * carry no contrast obligation, and asserting a threshold on them would be
 * false precision. Instead, this script derives a denylist from those same
 * values and asserts no UI-tier token, CSS or Tailwind, is ever set to one of
 * them.
 */
import fs from 'node:fs';

const BG = '#06060a';
const CSS_PATH = 'app/globals.css';
const TAILWIND_PATH = 'tailwind.config.mjs';
const BRAND_PATH = 'lib/brand.ts';

const THRESHOLDS = {
  '--zor-500': 3.0,
  '--verified-500': 3.0,
  '--cyan-500': 3.0,
  '--amber-500': 3.0,
  '--magenta-500': 3.0,
  '--danger-500': 3.0,
};

// `ink.200` is the body-text token (`body { @apply ... text-ink-200 }` in
// globals.css) and must clear AA. Every other ink stop is UI chrome —
// headings, labels, placeholders — and takes the shared 3.0 floor.
const INK_MIN = { 100: 3.0, 200: 4.5, 300: 3.0, 400: 3.0, 500: 3.0, 600: 3.0 };

// zor stops actually reachable as text/border/ring colour across
// app/components (text-zor-300, text-zor-400, border-zor-500,
// border-zor-600, ring-zor-500, ...). `700` is unused anywhere in the
// codebase; `900` appears exactly once, as a decorative card border (the
// homepage's Final CTA panel), never as text or an interactive boundary.
// Neither carries a contrast obligation, so — like the graphic tier — gating
// on them would be false precision. Both are still parsed and reported below
// for visibility, just not gated.
const ZOR_GATED = new Set(['300', '400', '500', '600']);
const ZOR_MIN = 3.0;

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

// ─── Shared hex extraction ────────────────────────────────────────────────
// First `#rrggbb` captured by a non-global regex, or null.
const findFirst = (text, re) => {
  const m = text.match(re);
  return m ? m[1] : null;
};
// Every match of a global regex, as full match arrays (callers read whichever
// capture groups they need).
const findAll = (text, re) => [...text.matchAll(re)];
// Inner text of the first `name: { ... }` object literal in `text`. Safe
// without a non-greedy qualifier: the character class already excludes `}`,
// so it cannot overshoot into a later block.
const block = (text, name) => findFirst(text, new RegExp('\\b' + name + ':\\s*\\{([^}]*)\\}')) ?? '';
// A Tailwind colour scale block (`{ NNN: '#rrggbb', ... }`) as a plain object
// keyed by stop.
const scale = (text, name) =>
  Object.fromEntries(findAll(block(text, name), /(\d+):\s*'(#[0-9a-fA-F]{6})'/g).map((m) => [m[1], m[2]]));

const css = fs.readFileSync(CSS_PATH, 'utf8');
const tailwind = fs.readFileSync(TAILWIND_PATH, 'utf8');
const brand = fs.readFileSync(BRAND_PATH, 'utf8');
const bg = hexToRgb(BG);
const failures = [];

// Graphic-tier denylist, derived rather than hand-listed: three values live
// as CSS custom properties, `tint` only in lib/brand.ts.
const graphicHexes = new Set(
  [
    ...findAll(css, /--zor-graphic-[a-z]+:\s*(#[0-9a-fA-F]{6})/g).map((m) => m[1]),
    findFirst(brand, /tint:\s*'(#[0-9a-fA-F]{6})'/),
  ]
    .filter(Boolean)
    .map((h) => h.toLowerCase()),
);

const report = (label, hex, min, gated = true) => {
  const ratio = contrast(hexToRgb(hex), bg);
  const status = !gated ? 'not gated' : ratio >= min ? 'ok' : 'FAIL';
  console.log(
    '  ' + label.padEnd(20) + ' ' + hex + '  contrast ' + ratio.toFixed(2) +
    '  min ' + (gated ? min.toFixed(1) : 'n/a') + '  ' + status,
  );
  return ratio;
};

const denyCheck = (label, hex) => {
  if (graphicHexes.has(hex.toLowerCase())) {
    failures.push(label + ' (' + hex + ') is set to a graphic-tier value; UI tokens must not reuse graphic-tier colours.');
  }
};

// ─── app/globals.css custom properties ─────────────────────────────────────
console.log('\n  app/globals.css:');
const cssHexes = {};
for (const [token, min] of Object.entries(THRESHOLDS)) {
  const hex = findFirst(css, new RegExp(token + ':\\s*(#[0-9a-fA-F]{6})'));
  if (!hex) {
    failures.push(token + ': not found in ' + CSS_PATH);
    continue;
  }
  cssHexes[token] = hex;
  const ratio = report(token, hex, min);
  if (ratio < min) failures.push(token + ' (' + hex + ') scores ' + ratio.toFixed(2) + ', needs ' + min);
  denyCheck(token, hex);
}

// ─── tailwind.config.mjs `zor` scale ───────────────────────────────────────
console.log('\n  tailwind.config.mjs (zor):');
const zorScale = scale(tailwind, 'zor');

if (!zorScale['500']) {
  failures.push('tailwind.config.mjs: zor.500 not found');
} else if (cssHexes['--zor-500'] && zorScale['500'].toLowerCase() !== cssHexes['--zor-500'].toLowerCase()) {
  failures.push(
    'tailwind.config.mjs zor.500 (' + zorScale['500'] + ') does not match --zor-500 (' +
    cssHexes['--zor-500'] + ') in ' + CSS_PATH + ' — the plan requires the two to agree.',
  );
}

for (const [stop, hex] of Object.entries(zorScale)) {
  const gated = ZOR_GATED.has(stop);
  const ratio = report('zor.' + stop, hex, ZOR_MIN, gated);
  if (gated && ratio < ZOR_MIN) {
    failures.push('tailwind zor.' + stop + ' (' + hex + ') scores ' + ratio.toFixed(2) + ', needs ' + ZOR_MIN);
  }
  denyCheck('zor.' + stop, hex);
}

// ─── tailwind.config.mjs `ink` scale ───────────────────────────────────────
console.log('\n  tailwind.config.mjs (ink):');
const inkScale = scale(tailwind, 'ink');

for (const [stop, hex] of Object.entries(inkScale)) {
  const min = INK_MIN[stop] ?? ZOR_MIN;
  const ratio = report('ink.' + stop, hex, min);
  if (ratio < min) failures.push('tailwind ink.' + stop + ' (' + hex + ') scores ' + ratio.toFixed(2) + ', needs ' + min);
  denyCheck('ink.' + stop, hex);
}

if (failures.length) {
  console.error('\ncontrast check FAILED:\n' + failures.map((f) => '  - ' + f).join('\n'));
  process.exit(1);
}
console.log('\n  contrast ok');

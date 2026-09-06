# Visual Foundation (Phase 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the site's brand colour match the logo without breaking contrast, and recolour the hero prism from its white wash to true logo chroma.

**Architecture:** A two-tier colour system. The UI tier (`--zor-*`) stays legible and governs text, borders and focus rings. A new graphic tier (`--zor-graphic-*`) carries true logo chroma and is used only on surfaces with no contrast obligation, currently just the WebGL prism. Because every surface already reads from tokens, the change propagates site-wide from two files. A new `scripts/check-contrast.mjs` guard makes the contrast requirement executable rather than aspirational.

**Tech Stack:** Next.js 15.5, Tailwind (config in `tailwind.config.mjs`), CSS custom properties in `app/globals.css`, React Three Fiber (`components/ui/prism-hero.tsx`), Node 22 for scripts.

**Spec:** `docs/design/visual-system-design.md`

## Global Constraints

- Working directory for all commands: `zorpha-web/`
- UI-tier tokens must score **>= 3.0** contrast against `#06060a`; body-text tokens **>= 4.5**. Source: spec section 1.
- Graphic-tier values are exempt from contrast rules and MUST NOT be used for text, borders or focus rings.
- Logo-measured chroma range is `#4700f8` (hue 257) to `#8700f9` (hue 273), both HSL saturation 100%, lightness 49%.
- `prefers-reduced-motion` handling in `app/globals.css:72` and in `components/motion/*` is authoritative and must not regress.
- Out of scope this phase: legal pages, the custody/allocation tables on `/token`, whitepaper restructuring, and any motion adoption (that is Phase 2/3).
- Line endings in this repo are **LF**. Do not write files with Python text-mode writes on Windows; that produces CRLF and turns a 40-line diff into a 900-line one.

---

### Task 1: Contrast guard

Makes the spec's contrast requirement executable. Written first so the token change in Task 2 is verified rather than assumed.

**Files:**
- Create: `zorpha-web/scripts/check-contrast.mjs`
- Modify: `zorpha-web/package.json` (add `check:contrast`, chain into `prebuild`)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `npm run check:contrast`, exit code 0 on pass and 1 on failure. Tasks 2 and 4 both run it.

- [ ] **Step 1: Write the guard**

Create `zorpha-web/scripts/check-contrast.mjs`:

```js
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
```

- [ ] **Step 2: Run it against the CURRENT tokens to prove it passes today**

Run: `cd zorpha-web && node scripts/check-contrast.mjs`

Expected: PASS. Line reading `--zor-500  #8b6dff  contrast 5.52  min 3.0  ok`, ending `contrast ok`.

This is the baseline. If it fails now, the guard is wrong, not the tokens.

- [ ] **Step 3: Prove the guard actually catches a bad value**

Temporarily edit `app/globals.css` and set `--zor-500: #4700f8;`

Run: `node scripts/check-contrast.mjs`

Expected: FAIL, exit code 1, reporting both `scores 2.53, needs 3` and `is set to a graphic-tier value`.

Then revert that edit: `git checkout app/globals.css`

A guard that has never failed has not been tested.

- [ ] **Step 4: Wire it into the build**

In `zorpha-web/package.json`, add to `scripts`:

```json
"check:contrast": "node scripts/check-contrast.mjs",
```

Then change the existing prebuild from:

```json
"prebuild": "node scripts/check-env.mjs && node scripts/check-tokenomics.mjs",
```

to:

```json
"prebuild": "node scripts/check-env.mjs && node scripts/check-tokenomics.mjs && node scripts/check-contrast.mjs",
```

- [ ] **Step 5: Verify the wiring**

Run: `npm run check:contrast`

Expected: PASS, same output as Step 2.

- [ ] **Step 6: Commit**

```bash
git add zorpha-web/scripts/check-contrast.mjs zorpha-web/package.json
git commit -m "A contrast rule nobody runs is a preference, not a rule"
```

---

### Task 2: Two-tier colour tokens

**Files:**
- Modify: `zorpha-web/app/globals.css:11` (the `:root` token block)
- Modify: `zorpha-web/tailwind.config.mjs:20-27` (the `zor` scale)
- Create: `zorpha-web/lib/brand.ts`

**Interfaces:**
- Consumes: `npm run check:contrast` from Task 1.
- Produces: `BRAND_GRAPHIC` from `lib/brand.ts`, shape `{ core: string; bright: string; accent: string; tint: string }`. Task 3 imports it for the prism props.

- [ ] **Step 1: Raise the UI tier**

In `app/globals.css`, change line 11 only:

```css
    --zor-500: #7c4dff;
```

Leave `--verified-500`, `--cyan-500`, `--amber-500`, `--magenta-500` and `--danger-500` untouched; they already sit in the logo's secondary range per spec section 1.

- [ ] **Step 2: Add the graphic tier**

In the same `:root` block, immediately after the `--danger-500` line, add:

```css

    /* Graphic tier: true logo chroma, measured from public/zorpha-256.png.
       WebGL and gradient surfaces only. These FAIL WCAG as text colours
       (#4700f8 scores 2.53 on this background) and check-contrast.mjs
       rejects them if they reach --zor-500. */
    --zor-graphic-core: #4700f8;
    --zor-graphic-bright: #8700f9;
    --zor-graphic-accent: #7a3cff;
```

- [ ] **Step 3: Mirror the UI tier into Tailwind**

In `tailwind.config.mjs`, in the `zor` scale, change the `500` entry so Tailwind and the CSS custom property agree:

```js
          500: '#7c4dff',
```

Leave `300`, `400`, `600`, `700` and `900` unchanged. The other stops are not referenced by the contrast guard and changing them is out of scope.

- [ ] **Step 4: Create the TS mirror for the prism**

Create `zorpha-web/lib/brand.ts`:

```ts
/**
 * Graphic-tier brand colours, mirrored from the `--zor-graphic-*` custom
 * properties in app/globals.css.
 *
 * These exist as TypeScript because the prism is a WebGL component that takes
 * colours as props, and reading custom properties out of getComputedStyle at
 * render time would tie a canvas to stylesheet timing for no benefit. The
 * mirroring follows the pattern already used for chart colours.
 *
 * Do NOT use these for text, borders or focus rings: #4700f8 scores 2.53
 * against the void background and fails WCAG even for large text.
 */
export const BRAND_GRAPHIC = {
  /** Deepest logo violet. */
  core: '#4700f8',
  /** Brightest logo violet. */
  bright: '#8700f9',
  /** Mid value used for prism glow and dispersion. */
  accent: '#7a3cff',
  /** Prism body tint. Replaces the previous pure white, which caused the wash-out. */
  tint: '#6d2bff',
} as const;
```

- [ ] **Step 5: Verify contrast still passes**

Run: `cd zorpha-web && npm run check:contrast`

Expected: PASS. Line reading `--zor-500  #7c4dff  contrast 4.20  min 3.0  ok`, ending `contrast ok`.

If this fails, the token value is wrong. Do not lower the threshold.

- [ ] **Step 6: Verify types and build**

Run: `npx tsc --noEmit`

Expected: no output.

Run: `npm run build`

Expected: `Compiled successfully`, 29/29 static pages generated.

- [ ] **Step 7: Commit**

```bash
git add zorpha-web/app/globals.css zorpha-web/tailwind.config.mjs zorpha-web/lib/brand.ts
git commit -m "The brand token was a tint of the logo, 22 points too light"
```

---

### Task 3: Recolour the prism

**Files:**
- Modify: `zorpha-web/components/marketing/Hero.tsx:49-68` (the `<PrismHero>` call)

**Interfaces:**
- Consumes: `BRAND_GRAPHIC` from `lib/brand.ts` (Task 2).
- Produces: nothing consumed downstream.

Note: `components/ui/prism-hero.tsx` is a generic `ui/` component and its defaults (`tint = '#ffffff'` at line 217, `accent = '#a48dff'` at line 221) stay as they are. Brand values belong at the call site, not baked into a reusable component.

- [ ] **Step 1: Import the graphic tier**

In `components/marketing/Hero.tsx`, add to the imports:

```ts
import { BRAND_GRAPHIC } from '@/lib/brand';
```

- [ ] **Step 2: Pass the prism its colours**

In the same file, in the `<PrismHero ...>` call beginning at line 49, add two props immediately after `topInset`:

```tsx
        tint={BRAND_GRAPHIC.tint}
        accent={BRAND_GRAPHIC.accent}
```

Change nothing else in that call. `word`, `eyebrow`, `description`, `footnote` and `meta` are copy and are out of scope.

- [ ] **Step 3: Verify types**

Run: `cd zorpha-web && npx tsc --noEmit`

Expected: no output. If `tint` or `accent` are rejected, the prop names are wrong, check `components/ui/prism-hero.tsx:217,221`.

- [ ] **Step 4: Verify it renders**

If port 3000 is occupied by a stale server the page will serve an old build. Free it first:

```bash
powershell -Command "Get-NetTCPConnection -LocalPort 3000 -State Listen -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess -Unique | ForEach-Object { Stop-Process -Id $_ -Force }"
```

Then:

```bash
npm run build
npm run start
```

Open `http://localhost:3000/` and confirm by eye that the prism reads as electric violet rather than pale lavender.

- [ ] **Step 5: Verify reduced motion still holds**

In browser devtools, Rendering panel, set **Emulate CSS prefers-reduced-motion: reduce**, then reload `/`.

Expected: the prism paints a static frame and does not animate. If it animates, stop; the change has regressed `components/ui/prism-hero.tsx:271-277` and must be fixed before commit.

- [ ] **Step 6: Commit**

```bash
git add zorpha-web/components/marketing/Hero.tsx
git commit -m "The prism was tinted pure white, so it washed the logo out"
```

---

### Task 4: Full-surface verification

Proves the token change propagated everywhere without breaking anything, and that nothing from the accuracy work regressed.

**Files:**
- Create: `zorpha-web/scripts/crawl-routes.mjs`
- Modify: `zorpha-web/package.json` (add `check:routes`)

**Interfaces:**
- Consumes: a running production server on port 3000.
- Produces: `npm run check:routes`, exit 0 on pass, 1 on failure.

- [ ] **Step 1: Write the crawler**

Create `zorpha-web/scripts/crawl-routes.mjs`:

```js
#!/usr/bin/env node
/**
 * Crawls every static route against a running production server.
 *
 * Guards three things at once: that pages render, that no testnet chain id or
 * RPC host leaked back in, and that the tokenomics figures corrected on
 * 5 September have not regressed.
 */
const BASE = process.env.BASE ?? 'http://localhost:3000';

const ROUTES = [
  '/', '/faq', '/protocol', '/roadmap', '/token', '/whitepaper', '/tools/bridge',
  '/legal/terms', '/legal/privacy', '/legal/disclaimer',
  '/portal', '/portal/airdrop', '/portal/governance', '/portal/leaderboard',
  '/portal/leaders', '/portal/leaders/launch', '/portal/manage',
  '/portal/receipts', '/portal/vaults', '/portal/vesting',
];

const failures = [];

for (const route of ROUTES) {
  let res, body;
  try {
    res = await fetch(BASE + route);
    body = await res.text();
  } catch (err) {
    failures.push(route + ': unreachable (' + err.message + ')');
    continue;
  }

  if (res.status !== 200) failures.push(route + ': HTTP ' + res.status);
  if (/application error|Internal Server Error/i.test(body)) failures.push(route + ': render error');
  if (/46630|testnet\.chain\.robinhood/i.test(body)) failures.push(route + ': testnet reference');
  if (/21% (of supply|float)|Float at launch/i.test(body)) failures.push(route + ': stale 21% float claim');
  console.log('  ' + String(res.status).padEnd(4) + route);
}

if (failures.length) {
  console.error('\nroute crawl FAILED:\n' + failures.map((f) => '  - ' + f).join('\n'));
  process.exit(1);
}
console.log('\n  ' + ROUTES.length + ' routes ok');
```

- [ ] **Step 2: Add the script**

In `zorpha-web/package.json`, add to `scripts`:

```json
"check:routes": "node scripts/crawl-routes.mjs",
```

Do NOT add this to `prebuild`; it needs a running server, and prebuild runs before one exists.

- [ ] **Step 3: Run the full verification set**

With a production server running on port 3000:

```bash
cd zorpha-web
npm run check:contrast
npm run check:tokenomics
npm run check:env
npm run check:routes
npx tsc --noEmit
```

Expected: contrast ok; tokenomics parity 6 allocations summing to 100%; env ok; `20 routes ok`; tsc silent.

- [ ] **Step 4: Confirm the change is visible site-wide**

```bash
node -e "(async()=>{for(const r of ['/','/token','/protocol']){const h=await(await fetch('http://localhost:3000'+r)).text();console.log(r.padEnd(12),'new brand token present:',/7c4dff/i.test(h));}})();"
```

Expected: at least the root route reports true. If every route reports false, Tailwind did not pick up the config change, rebuild.

- [ ] **Step 5: Commit**

```bash
git add zorpha-web/scripts/crawl-routes.mjs zorpha-web/package.json
git commit -m "Crawl every route so a colour change cannot quietly break a page"
```

---

## Phase exit criteria

Phase 1 is done when all four tasks are committed and:

- `npm run check:contrast` passes with `--zor-500 #7c4dff` at 4.20
- `npm run check:routes` reports `20 routes ok`
- `npx tsc --noEmit` and `npm run build` are clean
- The prism reads as electric violet, and holds a static frame under `prefers-reduced-motion: reduce`

Phases 2 (marketing motion) and 3 (portal motion) are separate plans, written after this one ships.

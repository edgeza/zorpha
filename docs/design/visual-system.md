# Zorpha visual system: design

Date: 5 September 2026
Status: approved design, not yet planned or implemented
Scope: `zorpha-web`, all 20 routes, marketing and portal

## Problem

Two problems, one root cause.

The hero prism reads as pale lavender glass while the logo reads as electric
violet. The initial diagnosis, "the prism is under-saturated", was wrong.
Measured in HSL, the prism accent and the logo are both 100% saturated. The gap
is **lightness**:

| | hex | hue | HSL sat | lightness | contrast on `#06060a` |
|---|---|---|---|---|---|
| `--zor-500` (brand token) | `#8b6dff` | 252 | 100% | 71% | 5.52 |
| prism `accent` prop | `#a48dff` | 252 | 100% | 78% | 7.54 |
| logo core | `#4700f8` | 257 | 100% | 49% | 2.53 |
| logo bright | `#8700f9` | 273 | 100% | 49% | 3.27 |

The brand token is a **tint of the logo**, 22 lightness points lighter. Every
surface reading from that token inherits the wash-out, so this is a token
problem that happens to be most visible in the prism.

Second problem: the site has three motion primitives and barely uses them.
`Reveal` appears in 1 file, `CountUp` in 2, `ScrambleHash` in none. **21 of 22
page files contain no motion at all**, including the entire portal.

## Design

### 1. Two-tier colour

Logo chroma is unusable as an interface colour: `#4700f8` scores **2.53**
against the void background, failing WCAG even for large text (3.0). Raising
the brand token to full logo chroma would make the site inaccessible.

So the system splits by obligation:

**UI tier**, anything subject to contrast rules: text, links, borders, focus
rings, badges.
- `--zor-500`: `#8b6dff` → `#7c4dff` (hue 256, lightness 65%, contrast **4.20**)
- Passes large-text and UI contrast (3.0). Body copy remains on `ink` tokens,
  which is already the case, so no body text depends on this value.

**Graphic tier**, surfaces with no contrast obligation: the WebGL prism, glow
layers, gradient fills, the OG banner.
- New tokens spanning the measured logo range, `#4700f8` → `#8700f9`.
- This is where the logo match actually happens.

`--cyan-500` (`#22d3ee`) and `--magenta-500` (`#e849c0`) already sit in the
logo's secondary range and are unchanged; they move from incidental use to
deliberate use.

Because every surface reads from tokens, this propagates site-wide from
`app/globals.css` plus `tailwind.config.mjs`. No per-page colour edits.

### 2. Motion

**The prism is a props change, not a rewrite.** `components/ui/prism-hero.tsx`
is React Three Fiber and already accepts `tint`, `accent` and `dispersion` as
props. It already reads `prefers-reduced-motion` and pauses when off-screen.

- `tint`: `#ffffff` → graphic-tier violet. The white tint is the direct cause of
  the wash-out.
- `accent`: `#a48dff` → `#7a3cff` as designed here, but the implementation
  ships `#8362ff` (`PRISM_ACCENT` in `lib/brand.ts`) instead: the prism paints
  its eyebrow label in this colour as real text, and `#7a3cff` scored 3.77
  there, failing AA (4.5); `#8362ff` scores 4.97 and clears it.

A WebGL surface carries no contrast obligation, so this is the one place full
logo chroma belongs, and it is the designated showpiece.

**Everything else applies primitives that already exist.** This is not a new
motion system; it is adoption of `components/motion/{Reveal,CountUp,ScrambleHash}`,
all three of which are already `prefers-reduced-motion` aware.

Motion is split by surface:

- **Marketing, cinematic.** Prism performs at full chroma. `Reveal` on section
  entry. `CountUp` on every real number. Depth via graphic-tier gradient and
  glow layers. Motion lands once and settles; no infinite loops.
- **Portal, restrained.** Motion only where it carries information: balances
  counting when they change, transaction state transitions, `ScrambleHash`
  resolving addresses and hashes, hover states that confirm a control is live.
  Nothing decorative near money.

Every addition routes through the existing primitives so reduced-motion keeps
working. The `@media (prefers-reduced-motion: reduce)` block in `globals.css`
remains authoritative.

### 3. Sequencing

**Phase 1, Foundation.** `globals.css`, `tailwind.config.mjs`, and the prism
props. Two files plus one component; propagates to all 20 routes. Highest visual
delta per line changed in the project.

**Phase 2, Marketing.** Nine pages in impact order: homepage → token →
protocol → whitepaper → roadmap, faq, bridge.

**Phase 3, Portal.** The portal's substance is in **14 components under
`components/portal/` that already read live chain data**, not in the thin page
shells (24–163 lines). Work happens in the components.

### Out of scope, deliberately

- **Legal pages** (`terms`, `privacy`, `disclaimer`). Plain is correct for legal
  text; decorating disclaimers reads as a project dressing them up.
- **The custody and allocation tables** on `/token`. Made accurate on
  5 September; legibility beats styling and restyling risks reintroducing the
  ambiguity just removed.
- **Whitepaper structure.** 755 lines, the most credibility-bearing document on
  the site. Motion on entry only; no restructuring.

## Verification

Run at every phase:

1. Contrast recomputed for every changed token against `#06060a`, asserting
   UI-tier values stay at or above 3.0 and no body-text token drops below 4.5.
2. The 20-route crawl: HTTP 200, no render errors, no testnet chain id or RPC
   host.
3. Reduced-motion pass: with `prefers-reduced-motion: reduce`, `Reveal` and
   `CountUp` no-op and the prism holds a static frame.
4. `npx tsc --noEmit` and `npm run build` clean.

## Risks

- **Chroma changes can quietly break contrast in unmeasured places**, borders,
  disabled states, focus rings, placeholder text. Phase 1 measures these rather
  than assuming; any token failing its threshold is adjusted before shipping.
- **Motion can undercut the trust story.** The project spent its build avoiding
  memecoin signalling, and heavy animation is that vocabulary. The
  marketing/portal split is the mitigation and is not optional.
- **The prism is WebGL.** Any change must be checked on a machine without
  hardware acceleration; the existing off-screen pause and reduced-motion
  fallback must survive.

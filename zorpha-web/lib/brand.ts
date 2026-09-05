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

/**
 * Text-safe violet for the prism's `accent` prop.
 *
 * `accent` is not purely decorative: prism-hero.tsx renders the eyebrow label
 * as real 10px text with `style={{ color: accent }}`, so it carries a contrast
 * obligation BRAND_GRAPHIC deliberately does not. #8362ff scores 4.97 against
 * the #06060a background, clearing AA for small text, while sitting nine
 * lightness points more electric than the component's #a48dff default.
 */
export const PRISM_ACCENT = '#8362ff';

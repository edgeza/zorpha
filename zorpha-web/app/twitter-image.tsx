/**
 * X/Twitter reads `twitter:image` in preference to `og:image`. Rather than
 * maintain a second design, this re-exports the Open Graph card: the aspect
 * ratio a `summary_large_image` card wants is the same 1200x630.
 */
export { default, alt, size, contentType } from './opengraph-image';

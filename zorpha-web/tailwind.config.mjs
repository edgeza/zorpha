/** @type {import('tailwindcss').Config} */
export default {
  content: ['./app/**/*.{ts,tsx}', './components/**/*.{ts,tsx}', './lib/**/*.{ts,tsx}'],
  theme: {
    extend: {
      colors: {
        // Surfaces. Near-black with a cool violet cast so the accent reads as
        // emitted light rather than paint.
        void: {
          950: '#06060a',
          900: '#0a0a11',
          850: '#0e0e18',
          800: '#13131f',
          700: '#1c1c2b',
          600: '#282839',
          500: '#3a3a4f',
        },
        // Primary brand: electric violet. Deliberately not the teal/green that
        // every other DeFi protocol uses.
        zor: {
          300: '#c4b5ff',
          400: '#a48dff',
          500: '#7c4dff',
          600: '#6f4ae8',
          700: '#5734c4',
          900: '#2a1a63',
        },
        // "Verified" state, receipts, proofs, passing checks.
        verified: {
          400: '#c8ff5e',
          500: '#a8ee2b',
          600: '#86c410',
        },
        cyan: {
          400: '#5ee9ff',
          500: '#22d3ee',
          600: '#0aa5c0',
        },
        magenta: {
          400: '#ff7ad9',
          500: '#e849c0',
          600: '#b62f96',
        },
        amber: {
          400: '#fbc457',
          500: '#f59e0b',
          600: '#c67c05',
        },
        danger: {
          400: '#ff7a7a',
          500: '#f2555a',
          600: '#c9353a',
        },
        ink: {
          100: '#f6f6fb',
          200: '#e2e2ee',
          300: '#b8b8cc',
          400: '#8f8fa8',
          500: '#82829a',
          600: '#5f5f74',
        },
      },
      fontFamily: {
        sans: ['var(--font-sans)', 'ui-sans-serif', 'system-ui', 'sans-serif'],
        display: ['var(--font-display)', 'ui-serif', 'Charter', 'Georgia', 'serif'],
        mono: ['var(--font-mono)', 'ui-monospace', 'SFMono-Regular', 'Menlo', 'monospace'],
      },
      fontSize: {
        '2xs': ['0.6875rem', { lineHeight: '1rem', letterSpacing: '0.06em' }],
      },
      borderRadius: {
        card: '14px',
      },
      backgroundImage: {
        'grid-fade':
          'linear-gradient(to bottom, rgba(139,109,255,0.10), rgba(6,6,10,0) 70%)',
        'zor-sheen':
          'linear-gradient(135deg, #8b6dff 0%, #6f4ae8 45%, #22d3ee 100%)',
      },
      boxShadow: {
        glow: '0 0 0 1px rgba(139,109,255,0.35), 0 12px 48px -12px rgba(139,109,255,0.45)',
        panel: '0 1px 0 0 rgba(255,255,255,0.03) inset, 0 18px 48px -24px rgba(0,0,0,0.9)',
      },
      keyframes: {
        'fade-up': {
          from: { opacity: '0', transform: 'translateY(10px)' },
          to: { opacity: '1', transform: 'translateY(0)' },
        },
        ticker: {
          from: { transform: 'translateX(0)' },
          to: { transform: 'translateX(-50%)' },
        },
        'pulse-dot': {
          '0%, 100%': { opacity: '1' },
          '50%': { opacity: '0.35' },
        },
        // A polish highlight travelling across the glass wordmark. Animates
        // background-position, so nothing reflows and nothing repaints but
        // the one clipped gradient.
        'glass-sweep': {
          from: { backgroundPosition: '-140% 0' },
          to: { backgroundPosition: '240% 0' },
        },
      },
      animation: {
        'fade-up': 'fade-up 0.5s cubic-bezier(0.22,1,0.36,1) both',
        ticker: 'ticker 40s linear infinite',
        'pulse-dot': 'pulse-dot 2s ease-in-out infinite',
        'glass-sweep': 'glass-sweep 9s cubic-bezier(0.5,0,0.5,1) infinite',
      },
    },
  },
  plugins: [],
};

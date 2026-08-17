/** @type {import('tailwindcss').Config} */
export default {
  content: ['./index.html', './src/**/*.{js,ts,jsx,tsx}'],
  theme: {
    extend: {
      colors: {
        midnight: {
          DEFAULT: '#0D2737',
          950: '#08161F',
          900: '#0D2737',
          800: '#123245',
          700: '#1B3A4B',
          600: '#274A5E',
        },
        gold: {
          DEFAULT: '#DAA520',
          light: '#F0C75E',
          dim: '#8A6A1E',
        },
        mist: '#E6E8EB',
        paper: '#F7F8FA',
      },
      fontFamily: {
        display: ['"Exo 2"', 'sans-serif'],
        body: ['"Exo 2"', 'sans-serif'],
        arabic: ['"Tajawal"', 'sans-serif'],
      },
      backgroundImage: {
        'gold-arc': 'linear-gradient(90deg, #0D2737 0%, #DAA520 50%, #0D2737 100%)',
        'gateway-glow': 'radial-gradient(ellipse at center, rgba(218,165,32,0.35) 0%, rgba(13,39,55,0) 70%)',
      },
      boxShadow: {
        gold: '0 0 40px -8px rgba(218,165,32,0.45)',
      },
    },
  },
  plugins: [],
};

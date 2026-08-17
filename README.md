# Fantasy

Frontend scaffold for the Fantasy platform (church-league fantasy sports),
built on the existing schema/RLS/triggers/points-engine migrations and the
`finalize-gameweek` edge function.

## Stack
React + TypeScript + Vite + Tailwind + Supabase JS + React Router + Recharts.

## Setup
```
npm install
cp .env.example .env.local   # fill in your Supabase project URL + anon key
npm run dev
```

## Structure
- `src/pages/Landing.tsx` — gateway hero, matches the brand's arch/glow key art
- `src/pages/Dashboard.tsx` — signed-in overview (stats, live matches, top players, leaderboard)
- `src/components/Logo.tsx` — the cross-topped arch + runner mark, built as SVG (no image asset)
- `src/lib/supabase.ts` — client + `finalizeGameweek()` wrapper for the edge function
- `src/types/database.ts` — TS types mirroring `001_schema.sql`
- `src/data/mock.ts` — placeholder data; swap for real Supabase queries once `.env.local` is set
- `supabase/migrations/` — your four migrations, copied in as-is
- `supabase/functions/finalize-gameweek/` — your edge function, copied in as-is

## Brand tokens (tailwind.config.js)
- `midnight-900` #0D2737 · `gold` #DAA520 · `mist` #E6E8EB · `paper` #F7F8FA
- Display/body font: Exo 2 (bold italic for the wordmark) · Arabic: Tajawal
- Signature element: the gold arc (`ArcDivider`) used as a recurring
  section-break motif, echoing the "energy arc" in the brand mark

## Not yet wired up
Auth, real Supabase queries (My Teams, Transfers, Standings pages), and
the super_admin gameweek-finalize trigger UI — the dashboard currently
renders from `src/data/mock.ts` so you can see the design without a live DB.

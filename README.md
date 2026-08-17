# Faggala Fantasy

Production-oriented church-league fantasy football application built with React 19, TypeScript, Vite, Tailwind, Supabase Auth/PostgreSQL/RLS and Supabase Edge Functions.

## Local setup

```bash
npm install
cp .env.example .env.local
npm run dev
```

Set only the public browser credentials in `.env.local`:

```text
VITE_SUPABASE_URL=https://YOUR_PROJECT.supabase.co
VITE_SUPABASE_ANON_KEY=YOUR_PUBLIC_ANON_KEY
```

Apply migrations `001` through `010` in order. Deploy both protected functions:

```bash
supabase functions deploy lock-gameweek
supabase functions deploy finalize-gameweek
```

`SUPABASE_SERVICE_ROLE_KEY` is supplied by the Edge Function environment and must never be exposed through a `VITE_*` variable.

## Verification

```bash
npm run lint
npm test
npm run build
```

The hardening migrations add immutable gameweek/rule snapshots, price history, bank/purchase-price accounting, validated squad and lineup RPCs, atomic transfers, transfer penalties, deadline locking, automatic substitutions, captain fallback, deterministic scoring, payment idempotency, an atomic wallet ledger, scoped storage, restrictive grants, and hardened RLS. See [`supabase/SCHEMA_AUDIT.md`](supabase/SCHEMA_AUDIT.md) and [`supabase/DATABASE_ARCHITECTURE.md`](supabase/DATABASE_ARCHITECTURE.md).

## Competition setup

1. Create the first Supabase Auth account, then promote it once to `super_admin` using a trusted server/admin SQL session.
2. In `/admin`, configure real teams, players, a current season, gameweeks and fixtures.
3. Create a validated default `fantasy_rules` version for the current season before league/team creation.
4. Add allowed production URLs to Supabase Auth redirect URLs (`/auth/callback` and `/reset-password`).
5. Enable Realtime for `notifications` and match/stat tables if live push updates are desired.

All competition timestamps are stored as `timestamptz` and rendered in `Africa/Cairo`.

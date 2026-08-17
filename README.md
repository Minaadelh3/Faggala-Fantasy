# Faggala Fantasy

Production-oriented church-league fantasy football application built with React 19, TypeScript, Vite, Tailwind, Supabase Auth/PostgreSQL/RLS and Supabase Edge Functions.

## Local setup

```bash
npm install
cp .env.example .env.local
npm run dev
```

## Supabase setup

1. Copy `.env.example` to `.env.local`.
2. In the intended Supabase project, open **Project Settings > API**.
3. Copy the project URL and a browser-safe publishable/anon key into:

```text
VITE_SUPABASE_URL=
VITE_SUPABASE_ANON_KEY=
```

4. Restart `npm run dev` whenever environment values change. Vite embeds `VITE_*` values into the browser bundle at startup/build time.

Only the public browser credentials belong in `.env.local`. Never use a Supabase service-role secret in a client-side `VITE_*` variable. `.env.local` and other local environment variants are ignored by Git; `.env.example` remains a safe, credential-free template.

For production, configure the same two variables in the deployment provider's environment settings and rebuild/redeploy the application. This repository does not currently contain provider-specific deployment configuration.

Apply every migration in `supabase/migrations` in numeric order. Deploy both protected functions:

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

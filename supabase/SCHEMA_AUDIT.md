# Supabase schema audit

Audit date: 2026-08-17. The 23-page `new database fantasy.pdf` is retained as the before snapshot. The implemented source of truth is migrations `001` through `010`.

## Current architecture

The original database separated identity/tenancy, global football data, Fantasy state, billing/wallet data, and communications. It already had most primary and foreign keys, baseline RLS, timestamp triggers, a JSON scoring configuration, and a service-role scoring entry point. Migration `005` introduced RPC-based squad operations and gameweek snapshots, but still encoded product constants in SQL and left several authorization and transactional gaps.

The application is a browser Supabase client. It uses the public anon key and authenticated user JWTs. Service-role credentials occur only in the two server-side Edge Functions. No service-role value is present in browser source. The locally configured `.env` contained only a URL and public anon key; it has nevertheless been removed from Git tracking so environment-specific values do not remain in source control.

## Findings

| Priority | Finding | Resolution |
|---|---|---|
| P0 | `profiles_update_own` allowed an owner to submit a different `platform_role`. | Column grants plus a trigger protect identity/role; audited `set_platform_role` checks the caller. |
| P0 | `church_members_insert_self_or_admin` trusted the self-join row's role. | Direct membership writes are revoked. `join_church` always creates `member/active`; admin changes use an audited tenant-scoped RPC. Removed users cannot self-reactivate. |
| P0 | Church lifecycle fields and owner/status were client-writable. | Church creation/update use narrow RPCs; creation is forced to `pending`. |
| P0 | Owners could directly mutate squads, transfers, team budgets/points, and historical state. | Direct DML is revoked; validated transactional RPCs own all gameplay mutations. Finalized records have a defense-in-depth immutability trigger. |
| P0 | Several `SECURITY DEFINER` functions had a mutable/default search path and helper/scoring functions retained default PUBLIC execute. | Functions use `search_path = ''` with schema-qualified objects; internal functions are revoked from PUBLIC/anon/authenticated. |
| P0 | League rivals could read current pre-deadline squads, and the Fantasy-team policy self-read risked RLS recursion. | Current squads/teams are owner-only. Safe standings are exposed through `fantasy_leaderboard`; snapshots become visible to league participants only after lock. |
| P1 | Team capacity was checked when accepting an invite but not atomically when the team was created. | Team creation locks the league row and checks count, uniqueness, access, and capacity in the same transaction. |
| P1 | Rules were partly JSON and gameplay RPCs hard-coded 15/100/3/4/2. | Validated, versioned rule JSON is resolved church-over-global and frozen into each lineup/transfer snapshot. The existing UI rules were used as initial data. |
| P1 | No stable historical rule or player-price source existed. | Gameweek lineup snapshots carry rule/version/price data; `player_price_history` records a baseline and every price change. |
| P1 | Captain/vice/bench rules relied mainly on application code. | Checks, partial unique indexes, ordered-bench uniqueness, and full transactional validation enforce them. |
| P1 | Advertisement admins could set their own status to `active`. | A transition trigger limits church admins to draft/submission/pause behavior; only `review_advertisement` can approve/reject. |
| P1 | Provider events and wallet ledger entries were not idempotent; the old wallet trigger allowed overdrafts. | Unique provider events/references, a service-only event RPC, wallet-row locking, mandatory idempotency keys, nonnegative balances, and an immutable ledger were added. |
| P1 | Financial FKs cascaded when a church was deleted. | Subscription/payment/invoice/wallet history now uses RESTRICT. Cross-church payment/invoice links are trigger-validated. |
| P1 | Notification owners could update every column so long as ownership remained theirs. | Only the `read` column is grantable, a trigger protects all other fields, and `mark_notifications_read` is the application API. |
| P2 | Date/value/status checks and FK indexes were incomplete. | Non-destructive `NOT VALID` checks protect all new writes; focused FK/query/RLS indexes were added. Existing corrupt rows can be remediated before later validation. |
| P2 | A nullable church ID in a standard UNIQUE did not prevent multiple global rules. | Partial active-scope indexes make global and church resolution deterministic. |
| P2 | Private invite codes lived on otherwise selectable league rows and had only 20 bits in the draft generator. | Codes moved to an RLS-protected secret table; new and automatically rotated short legacy codes use 80 random bits. Creators retrieve the replacement through an authorized RPC. |
| P2 | Storage policy was undocumented/absent. | Four bounded image buckets now enforce MIME, size, user/tenant path ownership, and admin scope. |
| P3 | Football positions/stat columns couple the engine to football. | Kept for the MVP. Tenant, finance, identity, audit, and storage layers remain sport-neutral; see future notes below. |

## Structural and deletion decisions

- Operational children such as settings, memberships, leagues, teams, current squads, and snapshots retain existing cascades because they have no meaning without the parent.
- Financial rows now block destructive church/payment/subscription deletion. They must be retained or explicitly archived.
- Player price and finalized scoring references use RESTRICT to preserve explainability.
- Audit rows retain nullable references, block referenced-parent deletion by default, and are append-only; a future retention/anonymization job may explicitly clear those references.
- Existing uniqueness for membership, gameweek number, team-per-league, squad player, match stat, and gameweek aggregate is retained. Partial indexes add single captain, vice-captain, and bench position.
- Legacy CHECK constraints are `NOT VALID`: PostgreSQL enforces them for all new/changed rows without rejecting deployment because an old row needs remediation.

## Security and performance notes

RLS helper calls now use indexed `(church_id,user_id)` and `(league_id,user_id)` paths. High-volume access is covered for snapshot team/week, snapshot week/player, transfers team/week, match week/status, player filtering, payment/wallet chronology, and audit actor/church. No speculative index was added for every scalar statistic.

RLS is not column security. Invite codes moved to their own table; standings moved to a narrow view; profile phone and team bank remain absent from shared standings. Live squads are no longer readable by rivals.

## Migration strategy

1. Apply existing migrations in filename order. Do not reset or replace the PDF snapshot.
2. `006` hardens identity, tenant access, protected columns, constraints, indexes, ads, notifications, and audit history.
3. `007` backfills current UI rules into JSON, adds rule/price history, separates invite secrets, and replaces gameplay RPCs. IDs and squad membership are retained.
4. `008` replaces scoring with deterministic per-snapshot rules.
5. `009` changes financial deletion semantics, introduces idempotency/locking, and creates storage policies.
6. `010` narrows live read policies and adds safe application views/RPCs.
7. Run `supabase db test`. Investigate legacy rows that prevent optional `VALIDATE CONSTRAINT` operations; do not delete them automatically.

The only automatic legacy repair is deterministic removal of duplicate captain/vice flags and duplicate bench ordering. Player membership, IDs, transfers, points, and financial rows are never discarded.

## Financial-data assessment

Amounts remain fixed-scale `numeric(10,2)` in the existing single-currency model. ISO-like uppercase currency checks prevent malformed values. A provider event stores a SHA-256 payload digest rather than sensitive raw webhook material. A duplicate `(provider,event_id)` returns the original result and creates no second payment. Wallet operations lock one wallet row before checking the retry key and applying a credit/debit, so concurrent operations serialize and cannot overdraw. Wallet entries are immutable and store `balance_after` for reconciliation.

## Remaining product decisions

- Whether churches will eventually require join approval rather than the currently implemented open join for active churches. The present UI explicitly offers immediate joining, so the safe forced `member/active` flow was preserved.
- Whether multiple overlapping paid subscriptions per church are a supported billing scenario. No speculative one-active-subscription constraint was added.
- Whether selling price should be current price or purchase price. Both are supported by `selling_price_basis`; the migrated UI behavior remains `current`.
- Multi-sport support is not an MVP requirement evidenced by this repository. A later design would extract sport/competition, position taxonomy, stat definitions, and scoring inputs while retaining the tenant/finance layers.

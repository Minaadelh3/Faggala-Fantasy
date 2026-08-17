-- ============================================================
-- FANTASY CHURCH PLATFORM — ROW LEVEL SECURITY
-- Migration: 002_rls_policies.sql
-- Depends on: 001_schema.sql
-- ============================================================

-- ------------------------------------------------------------
-- HELPER FUNCTIONS (security definer so they can read profiles/
-- church_members regardless of the caller's own RLS restrictions)
-- ------------------------------------------------------------

create or replace function is_super_admin()
returns boolean
language sql
security definer
stable
as $$
  select exists (
    select 1 from profiles
    where id = auth.uid() and platform_role = 'super_admin'
  );
$$;

create or replace function is_church_member(target_church_id uuid)
returns boolean
language sql
security definer
stable
as $$
  select exists (
    select 1 from church_members
    where church_id = target_church_id
      and user_id = auth.uid()
      and status = 'active'
  );
$$;

create or replace function has_church_role(target_church_id uuid, allowed_roles church_role[])
returns boolean
language sql
security definer
stable
as $$
  select exists (
    select 1 from church_members
    where church_id = target_church_id
      and user_id = auth.uid()
      and status = 'active'
      and role = any (allowed_roles)
  );
$$;

create or replace function is_church_admin(target_church_id uuid)
returns boolean
language sql
security definer
stable
as $$
  select has_church_role(target_church_id, array['church_admin']::church_role[])
      or is_super_admin();
$$;

create or replace function owns_fantasy_team(target_team_id uuid)
returns boolean
language sql
security definer
stable
as $$
  select exists (
    select 1 from fantasy_teams
    where id = target_team_id and user_id = auth.uid()
  );
$$;

-- ------------------------------------------------------------
-- ENABLE RLS
-- ------------------------------------------------------------
alter table profiles enable row level security;
alter table churches enable row level security;
alter table church_settings enable row level security;
alter table church_members enable row level security;
alter table seasons enable row level security;
alter table gameweeks enable row level security;
alter table teams enable row level security;
alter table players enable row level security;
alter table matches enable row level security;
alter table match_player_stats enable row level security;
alter table fantasy_rules enable row level security;
alter table fantasy_leagues enable row level security;
alter table fantasy_teams enable row level security;
alter table fantasy_team_players enable row level security;
alter table transfers enable row level security;
alter table fantasy_team_gameweek_points enable row level security;
alter table advertisements enable row level security;
alter table subscriptions enable row level security;
alter table payments enable row level security;
alter table invoices enable row level security;
alter table church_wallet enable row level security;
alter table church_wallet_transactions enable row level security;
alter table notifications enable row level security;
alter table announcements enable row level security;
alter table audit_logs enable row level security;

-- ------------------------------------------------------------
-- PROFILES
-- ------------------------------------------------------------
create policy "profiles_select_own_or_admin"
  on profiles for select
  using (id = auth.uid() or is_super_admin());

create policy "profiles_update_own"
  on profiles for update
  using (id = auth.uid())
  with check (id = auth.uid());

-- ------------------------------------------------------------
-- CHURCHES
-- Public read of active churches (directory); full manage = owner/admin/super_admin
-- ------------------------------------------------------------
create policy "churches_select_active_or_member_or_admin"
  on churches for select
  using (
    status = 'active'
    or owner_id = auth.uid()
    or is_church_member(id)
    or is_super_admin()
  );

create policy "churches_insert_authenticated"
  on churches for insert
  with check (auth.uid() is not null and owner_id = auth.uid());

create policy "churches_update_owner_or_admin"
  on churches for update
  using (owner_id = auth.uid() or is_church_admin(id) or is_super_admin());

create policy "churches_delete_super_admin"
  on churches for delete
  using (is_super_admin());

-- ------------------------------------------------------------
-- CHURCH SETTINGS
-- ------------------------------------------------------------
create policy "church_settings_select"
  on church_settings for select
  using (is_church_member(church_id) or is_super_admin() or
         exists (select 1 from churches c where c.id = church_id and c.status = 'active'));

create policy "church_settings_manage"
  on church_settings for all
  using (is_church_admin(church_id))
  with check (is_church_admin(church_id));

-- ------------------------------------------------------------
-- CHURCH MEMBERS
-- ------------------------------------------------------------
create policy "church_members_select"
  on church_members for select
  using (user_id = auth.uid() or is_church_member(church_id) or is_super_admin());

create policy "church_members_insert_self_or_admin"
  on church_members for insert
  with check (user_id = auth.uid() or is_church_admin(church_id));

create policy "church_members_manage_admin"
  on church_members for update
  using (is_church_admin(church_id));

create policy "church_members_delete_admin_or_self"
  on church_members for delete
  using (is_church_admin(church_id) or user_id = auth.uid());

-- ------------------------------------------------------------
-- SEASONS / GAMEWEEKS / TEAMS / PLAYERS / MATCHES / STATS
-- Global reference data: readable by everyone, writable by super_admin only
-- ------------------------------------------------------------
create policy "seasons_select_all" on seasons for select using (true);
create policy "seasons_manage_super_admin" on seasons for all
  using (is_super_admin()) with check (is_super_admin());

create policy "gameweeks_select_all" on gameweeks for select using (true);
create policy "gameweeks_manage_super_admin" on gameweeks for all
  using (is_super_admin()) with check (is_super_admin());

create policy "teams_select_all" on teams for select using (true);
create policy "teams_manage_super_admin" on teams for all
  using (is_super_admin()) with check (is_super_admin());

create policy "players_select_all" on players for select using (true);
create policy "players_manage_super_admin" on players for all
  using (is_super_admin()) with check (is_super_admin());

create policy "matches_select_all" on matches for select using (true);
create policy "matches_manage_super_admin" on matches for all
  using (is_super_admin()) with check (is_super_admin());

create policy "mps_select_all" on match_player_stats for select using (true);
create policy "mps_manage_super_admin" on match_player_stats for all
  using (is_super_admin()) with check (is_super_admin());

-- ------------------------------------------------------------
-- FANTASY RULES
-- Platform default (church_id is null) readable by all; church override
-- readable by church members, writable by church admin
-- ------------------------------------------------------------
create policy "fantasy_rules_select"
  on fantasy_rules for select
  using (church_id is null or is_church_member(church_id) or is_super_admin());

create policy "fantasy_rules_manage"
  on fantasy_rules for all
  using (
    (church_id is not null and is_church_admin(church_id))
    or is_super_admin()
  )
  with check (
    (church_id is not null and is_church_admin(church_id))
    or is_super_admin()
  );

-- ------------------------------------------------------------
-- FANTASY LEAGUES
-- church_id null = platform-wide league (visible to all)
-- ------------------------------------------------------------
create policy "leagues_select"
  on fantasy_leagues for select
  using (
    church_id is null
    or is_church_member(church_id)
    or is_super_admin()
  );

create policy "leagues_manage"
  on fantasy_leagues for all
  using (
    (church_id is not null and has_church_role(church_id, array['church_admin','league_admin']::church_role[]))
    or is_super_admin()
  )
  with check (
    (church_id is not null and has_church_role(church_id, array['church_admin','league_admin']::church_role[]))
    or is_super_admin()
  );

-- ------------------------------------------------------------
-- FANTASY TEAMS (a user's own squad, or visible to league co-members)
-- ------------------------------------------------------------
create policy "fteams_select"
  on fantasy_teams for select
  using (
    user_id = auth.uid()
    or is_super_admin()
    or exists (
      select 1 from fantasy_teams ft2
      where ft2.league_id = fantasy_teams.league_id and ft2.user_id = auth.uid()
    )
  );

create policy "fteams_insert_self"
  on fantasy_teams for insert
  with check (user_id = auth.uid());

create policy "fteams_update_own_or_admin"
  on fantasy_teams for update
  using (user_id = auth.uid() or is_super_admin());

create policy "fteams_delete_own_or_admin"
  on fantasy_teams for delete
  using (user_id = auth.uid() or is_super_admin());

-- ------------------------------------------------------------
-- FANTASY TEAM PLAYERS / TRANSFERS / GAMEWEEK POINTS
-- ------------------------------------------------------------
create policy "ftplayers_select"
  on fantasy_team_players for select
  using (owns_fantasy_team(fantasy_team_id) or is_super_admin() or
    exists (
      select 1 from fantasy_teams ft
      join fantasy_teams ft2 on ft2.league_id = ft.league_id
      where ft.id = fantasy_team_players.fantasy_team_id and ft2.user_id = auth.uid()
    ));

create policy "ftplayers_manage_own"
  on fantasy_team_players for all
  using (owns_fantasy_team(fantasy_team_id))
  with check (owns_fantasy_team(fantasy_team_id));

create policy "transfers_select_own"
  on transfers for select
  using (owns_fantasy_team(fantasy_team_id) or is_super_admin());

create policy "transfers_insert_own"
  on transfers for insert
  with check (owns_fantasy_team(fantasy_team_id));

create policy "ftgw_points_select"
  on fantasy_team_gameweek_points for select
  using (owns_fantasy_team(fantasy_team_id) or is_super_admin() or
    exists (
      select 1 from fantasy_teams ft
      join fantasy_teams ft2 on ft2.league_id = ft.league_id
      where ft.id = fantasy_team_gameweek_points.fantasy_team_id and ft2.user_id = auth.uid()
    ));

create policy "ftgw_points_manage_system"
  on fantasy_team_gameweek_points for all
  using (is_super_admin())
  with check (is_super_admin());

-- ------------------------------------------------------------
-- ADVERTISEMENTS — tenant isolated; active ads publicly viewable
-- ------------------------------------------------------------
create policy "ads_select"
  on advertisements for select
  using (status = 'active' or is_church_admin(church_id) or is_super_admin());

create policy "ads_manage"
  on advertisements for all
  using (is_church_admin(church_id))
  with check (is_church_admin(church_id));

-- ------------------------------------------------------------
-- SUBSCRIPTIONS / PAYMENTS / INVOICES / WALLET — strictly tenant isolated
-- ------------------------------------------------------------
create policy "subscriptions_select"
  on subscriptions for select
  using (is_church_admin(church_id) or is_super_admin());

create policy "subscriptions_manage_super_admin"
  on subscriptions for all
  using (is_super_admin())
  with check (is_super_admin());

create policy "payments_select"
  on payments for select
  using (is_church_admin(church_id) or is_super_admin());

create policy "payments_manage_super_admin"
  on payments for all
  using (is_super_admin())
  with check (is_super_admin());

create policy "invoices_select"
  on invoices for select
  using (is_church_admin(church_id) or is_super_admin());

create policy "wallet_select"
  on church_wallet for select
  using (is_church_admin(church_id) or is_super_admin());

create policy "wallet_manage_super_admin"
  on church_wallet for all
  using (is_super_admin())
  with check (is_super_admin());

create policy "wallet_tx_select"
  on church_wallet_transactions for select
  using (is_church_admin(church_id) or is_super_admin());

-- ------------------------------------------------------------
-- NOTIFICATIONS / ANNOUNCEMENTS / AUDIT LOGS
-- ------------------------------------------------------------
create policy "notifications_select_own"
  on notifications for select
  using (user_id = auth.uid() or is_super_admin());

create policy "notifications_update_own"
  on notifications for update
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

create policy "announcements_select"
  on announcements for select
  using (is_church_member(church_id) or is_super_admin());

create policy "announcements_manage"
  on announcements for all
  using (is_church_admin(church_id))
  with check (is_church_admin(church_id));

create policy "audit_logs_select_admin"
  on audit_logs for select
  using (
    (church_id is not null and is_church_admin(church_id))
    or is_super_admin()
  );

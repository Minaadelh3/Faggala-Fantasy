-- ============================================================
-- FANTASY CHURCH PLATFORM — TRIGGERS & AUTOMATION
-- Migration: 003_triggers.sql
-- Depends on: 001_schema.sql, 002_rls_policies.sql
-- ============================================================

-- ------------------------------------------------------------
-- Generic updated_at maintainer
-- ------------------------------------------------------------
create or replace function set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger trg_profiles_updated_at before update on profiles
  for each row execute function set_updated_at();
create trigger trg_churches_updated_at before update on churches
  for each row execute function set_updated_at();
create trigger trg_matches_updated_at before update on matches
  for each row execute function set_updated_at();
create trigger trg_leagues_updated_at before update on fantasy_leagues
  for each row execute function set_updated_at();
create trigger trg_fteams_updated_at before update on fantasy_teams
  for each row execute function set_updated_at();
create trigger trg_ads_updated_at before update on advertisements
  for each row execute function set_updated_at();
create trigger trg_subscriptions_updated_at before update on subscriptions
  for each row execute function set_updated_at();

-- ------------------------------------------------------------
-- On new user signup (auth.users insert) -> create profile row
-- ------------------------------------------------------------
create or replace function handle_new_user()
returns trigger
language plpgsql
security definer
as $$
begin
  insert into profiles (id, full_name, avatar_url)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', new.email),
    new.raw_user_meta_data ->> 'avatar_url'
  );
  return new;
end;
$$;

create trigger trg_on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();

-- ------------------------------------------------------------
-- On new church -> auto-provision wallet, free subscription,
-- default settings row, and register owner as church_admin
-- ------------------------------------------------------------
create or replace function handle_new_church()
returns trigger
language plpgsql
security definer
as $$
begin
  insert into church_wallet (church_id, balance) values (new.id, 0);

  insert into subscriptions (church_id, tier, status, current_period_start)
  values (new.id, 'free', 'active', now());

  insert into church_settings (church_id) values (new.id);

  insert into church_members (church_id, user_id, role, status)
  values (new.id, new.owner_id, 'church_admin', 'active');

  return new;
end;
$$;

create trigger trg_on_church_created
  after insert on churches
  for each row execute function handle_new_church();

-- ------------------------------------------------------------
-- Wallet transaction consistency: keep church_wallet.balance in
-- sync whenever a row is added to church_wallet_transactions
-- ------------------------------------------------------------
create or replace function apply_wallet_transaction()
returns trigger
language plpgsql
security definer
as $$
begin
  if new.type = 'credit' then
    update church_wallet set balance = balance + new.amount, updated_at = now()
    where church_id = new.church_id;
  else
    update church_wallet set balance = balance - new.amount, updated_at = now()
    where church_id = new.church_id;
  end if;
  return new;
end;
$$;

create trigger trg_apply_wallet_transaction
  after insert on church_wallet_transactions
  for each row execute function apply_wallet_transaction();

-- ------------------------------------------------------------
-- Recompute fantasy_team.total_points whenever a gameweek score
-- is written for that team (sum across all gameweeks)
-- ------------------------------------------------------------
create or replace function recompute_team_total_points()
returns trigger
language plpgsql
security definer
as $$
begin
  update fantasy_teams
  set total_points = (
    select coalesce(sum(points), 0)
    from fantasy_team_gameweek_points
    where fantasy_team_id = new.fantasy_team_id
  ),
  updated_at = now()
  where id = new.fantasy_team_id;
  return new;
end;
$$;

create trigger trg_recompute_total_points
  after insert or update on fantasy_team_gameweek_points
  for each row execute function recompute_team_total_points();

-- Identity, tenant, relational and workflow hardening.
-- This migration is forward-only and deliberately preserves existing rows/IDs.

begin;

-- SECURITY DEFINER helpers used by RLS must not resolve attacker-controlled objects.
create or replace function public.is_super_admin()
returns boolean
language sql
security definer
stable
set search_path = ''
as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and platform_role = 'super_admin'
  );
$$;

create or replace function public.is_church_member(target_church_id uuid)
returns boolean
language sql
security definer
stable
set search_path = ''
as $$
  select exists (
    select 1 from public.church_members
    where church_id = target_church_id
      and user_id = auth.uid()
      and status = 'active'
  );
$$;

create or replace function public.has_church_role(
  target_church_id uuid,
  allowed_roles public.church_role[]
)
returns boolean
language sql
security definer
stable
set search_path = ''
as $$
  select exists (
    select 1 from public.church_members
    where church_id = target_church_id
      and user_id = auth.uid()
      and status = 'active'
      and role = any (allowed_roles)
  );
$$;

create or replace function public.is_church_admin(target_church_id uuid)
returns boolean
language sql
security definer
stable
set search_path = ''
as $$
  select public.has_church_role(
           target_church_id,
           array['church_admin']::public.church_role[]
         ) or public.is_super_admin();
$$;

create or replace function public.owns_fantasy_team(target_team_id uuid)
returns boolean
language sql
security definer
stable
set search_path = ''
as $$
  select exists (
    select 1 from public.fantasy_teams
    where id = target_team_id and user_id = auth.uid()
  );
$$;

revoke all on function public.is_super_admin() from public;
revoke all on function public.is_church_member(uuid) from public;
revoke all on function public.has_church_role(uuid, public.church_role[]) from public;
revoke all on function public.is_church_admin(uuid) from public;
revoke all on function public.owns_fantasy_team(uuid) from public;
grant execute on function public.is_super_admin() to anon, authenticated, service_role;
grant execute on function public.is_church_member(uuid) to anon, authenticated, service_role;
grant execute on function public.has_church_role(uuid, public.church_role[]) to anon, authenticated, service_role;
grant execute on function public.is_church_admin(uuid) to anon, authenticated, service_role;
grant execute on function public.owns_fantasy_team(uuid) to authenticated, service_role;

-- Protected columns are guarded twice: column privileges stop PostgREST writes,
-- and triggers protect alternate SQL/RPC paths.
create or replace function public.protect_profile_privileged_columns()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.id <> old.id then
    raise exception 'Profile identity is immutable' using errcode = '42501';
  end if;
  if new.platform_role is distinct from old.platform_role
     and not (public.is_super_admin() or auth.role() = 'service_role') then
    raise exception 'Only a platform administrator may change platform_role'
      using errcode = '42501';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_protect_profile_privileged_columns on public.profiles;
create trigger trg_protect_profile_privileged_columns
before update on public.profiles
for each row execute function public.protect_profile_privileged_columns();

revoke update on public.profiles from anon, authenticated;
grant update (full_name, avatar_url, phone) on public.profiles to authenticated;

create or replace function public.set_platform_role(
  target_user_id uuid,
  new_role public.platform_role
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  previous_role public.platform_role;
begin
  if not public.is_super_admin() then
    raise exception 'Super admin only' using errcode = '42501';
  end if;
  if target_user_id = auth.uid() and new_role <> 'super_admin' then
    raise exception 'A super admin cannot demote their own account';
  end if;

  select platform_role into previous_role
  from public.profiles where id = target_user_id for update;
  if not found then raise exception 'Profile not found'; end if;

  update public.profiles set platform_role = new_role where id = target_user_id;
  insert into public.audit_logs(actor_id, action, entity_type, entity_id, metadata)
  values (auth.uid(), 'profile.platform_role_changed', 'profile', target_user_id,
          jsonb_build_object('from', previous_role, 'to', new_role));
end;
$$;
revoke all on function public.set_platform_role(uuid, public.platform_role) from public, anon;
grant execute on function public.set_platform_role(uuid, public.platform_role) to authenticated;

-- The UI implements open joining for active churches. Preserve that workflow,
-- but force the only self-created membership to member/active and never allow a
-- removed membership to reactivate itself.
alter table public.church_members
  add constraint church_members_status_check
  check (status in ('active', 'invited', 'removed')) not valid;

drop policy if exists "church_members_insert_self_or_admin" on public.church_members;
drop policy if exists "church_members_manage_admin" on public.church_members;
drop policy if exists "church_members_delete_admin_or_self" on public.church_members;
revoke insert, update, delete on public.church_members from anon, authenticated;

create or replace function public.join_church(target_church_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  existing_status text;
begin
  if auth.uid() is null then
    raise exception 'Authentication required' using errcode = '28000';
  end if;
  if not exists (
    select 1 from public.churches
    where id = target_church_id and status = 'active'
  ) then
    raise exception 'Church is not active';
  end if;

  select status into existing_status
  from public.church_members
  where church_id = target_church_id and user_id = auth.uid()
  for update;

  if existing_status = 'removed' then
    raise exception 'Membership was removed; contact a church administrator';
  elsif existing_status is null then
    insert into public.church_members(church_id, user_id, role, status)
    values(target_church_id, auth.uid(), 'member', 'active');
  end if;
end;
$$;

create or replace function public.manage_church_member(
  target_church_id uuid,
  target_user_id uuid,
  new_role public.church_role,
  new_status text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  old_row public.church_members;
begin
  if not public.is_church_admin(target_church_id) then
    raise exception 'Church admin only' using errcode = '42501';
  end if;
  if new_status not in ('active', 'invited', 'removed') then
    raise exception 'Invalid membership status';
  end if;

  select * into old_row from public.church_members
  where church_id = target_church_id and user_id = target_user_id
  for update;
  if old_row.id is null then raise exception 'Membership not found'; end if;

  if old_row.role = 'church_admin' and old_row.status = 'active'
     and (new_role <> 'church_admin' or new_status <> 'active')
     and not exists (
       select 1 from public.church_members cm
       where cm.church_id = target_church_id
         and cm.id <> old_row.id
         and cm.role = 'church_admin' and cm.status = 'active'
     ) then
    raise exception 'A church must retain an active church administrator';
  end if;

  update public.church_members
  set role = new_role, status = new_status
  where id = old_row.id;

  insert into public.audit_logs(actor_id, church_id, action, entity_type, entity_id, metadata)
  values(auth.uid(), target_church_id, 'church.member_changed', 'church_member', old_row.id,
         jsonb_build_object('old_role', old_row.role, 'new_role', new_role,
                            'old_status', old_row.status, 'new_status', new_status));
end;
$$;

revoke all on function public.join_church(uuid) from public, anon;
grant execute on function public.join_church(uuid) to authenticated;
revoke all on function public.manage_church_member(uuid, uuid, public.church_role, text) from public, anon;
grant execute on function public.manage_church_member(uuid, uuid, public.church_role, text) to authenticated;

-- Church lifecycle fields cannot be client-selected. Creation stays available
-- through an RPC and starts pending, matching the existing schema default.
drop policy if exists "churches_insert_authenticated" on public.churches;
drop policy if exists "churches_update_owner_or_admin" on public.churches;
revoke insert, update on public.churches from anon, authenticated;

create or replace function public.create_church(
  p_name text,
  p_slug text,
  p_description text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare result_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if length(btrim(p_name)) not between 2 and 120 then raise exception 'Invalid church name'; end if;
  if p_slug !~ '^[a-z0-9]+(?:-[a-z0-9]+)*$' then raise exception 'Invalid church slug'; end if;
  insert into public.churches(owner_id, name, slug, description, status)
  values(auth.uid(), btrim(p_name), lower(p_slug), p_description, 'pending')
  returning id into result_id;
  return result_id;
end;
$$;

create or replace function public.update_church_profile(
  target_church_id uuid,
  p_name text,
  p_description text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_church_admin(target_church_id) then
    raise exception 'Church admin only' using errcode = '42501';
  end if;
  if length(btrim(p_name)) not between 2 and 120 then raise exception 'Invalid church name'; end if;
  update public.churches set name = btrim(p_name), description = p_description
  where id = target_church_id;
end;
$$;

create or replace function public.set_church_status(
  target_church_id uuid,
  new_status public.church_status
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare previous_status public.church_status;
begin
  if not public.is_super_admin() then raise exception 'Super admin only' using errcode='42501'; end if;
  select status into previous_status from public.churches where id=target_church_id for update;
  if not found then raise exception 'Church not found'; end if;
  update public.churches set status=new_status where id=target_church_id;
  insert into public.audit_logs(actor_id,church_id,action,entity_type,entity_id,metadata)
  values(auth.uid(),target_church_id,'church.status_changed','church',target_church_id,
         jsonb_build_object('from',previous_status,'to',new_status));
end;
$$;

revoke all on function public.create_church(text, text, text) from public, anon;
revoke all on function public.update_church_profile(uuid, text, text) from public, anon;
revoke all on function public.set_church_status(uuid,public.church_status) from public,anon;
grant execute on function public.create_church(text, text, text) to authenticated;
grant execute on function public.update_church_profile(uuid, text, text) to authenticated;
grant execute on function public.set_church_status(uuid,public.church_status) to authenticated;

-- Relational and value integrity. NOT VALID preserves legacy rows while all new
-- writes are checked; constraints can be validated after production preflight.
update public.seasons s set is_current = false
where is_current and id not in (
  select id from (
    select id, row_number() over(order by start_date desc, created_at desc, id) rn
    from public.seasons where is_current
  ) ranked where rn = 1
);
create unique index if not exists uq_seasons_one_current
  on public.seasons(is_current) where is_current;

alter table public.seasons
  add constraint seasons_dates_check check(start_date <= end_date) not valid;
alter table public.gameweeks
  add constraint gameweeks_dates_check
  check(start_date <= transfer_deadline and transfer_deadline <= end_date) not valid;
alter table public.players
  add constraint players_price_nonnegative check(price >= 0) not valid;
alter table public.matches
  add constraint matches_distinct_teams check(home_team_id <> away_team_id) not valid,
  add constraint matches_scores_nonnegative
    check((home_score is null or home_score >= 0) and (away_score is null or away_score >= 0)) not valid;
alter table public.match_player_stats
  add constraint match_player_stats_nonnegative check(
    minutes_played >= 0 and goals >= 0 and assists >= 0 and shots >= 0
    and shots_on_target >= 0 and passes >= 0 and tackles >= 0
    and interceptions >= 0 and saves >= 0 and yellow_cards >= 0
    and red_cards >= 0 and own_goals >= 0 and penalties_saved >= 0
    and penalties_missed >= 0 and bonus >= 0
  ) not valid;
alter table public.fantasy_leagues
  add constraint fantasy_leagues_max_members_positive check(max_members > 0) not valid;
alter table public.transfers
  add constraint transfers_distinct_players check(player_out_id is null or player_out_id <> player_in_id) not valid;
alter table public.advertisements
  add constraint advertisements_dates_check check(start_date < end_date) not valid,
  add constraint advertisements_values_check
    check(coalesce(budget, 0) >= 0 and impressions >= 0 and clicks >= 0 and clicks <= impressions) not valid;
alter table public.subscriptions
  add constraint subscriptions_period_check
    check(current_period_end is null or current_period_start <= current_period_end) not valid;
alter table public.payments
  add constraint payments_amount_positive check(amount > 0) not valid,
  add constraint payments_currency_check check(currency ~ '^[A-Z]{3}$') not valid;
alter table public.invoices
  add constraint invoices_amount_nonnegative check(amount >= 0) not valid,
  add constraint invoices_dates_check check(due_at is null or issued_at <= due_at) not valid;
alter table public.church_wallet
  add constraint church_wallet_balance_nonnegative check(balance >= 0) not valid,
  add constraint church_wallet_currency_check check(currency ~ '^[A-Z]{3}$') not valid;
alter table public.church_wallet_transactions
  add constraint church_wallet_transactions_amount_positive check(amount > 0) not valid;

create or replace function public.validate_match_gameweek_season()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not exists (
    select 1 from public.gameweeks
    where id = new.gameweek_id and season_id = new.season_id
  ) then
    raise exception 'Match gameweek must belong to the match season';
  end if;
  return new;
end;
$$;
drop trigger if exists trg_validate_match_gameweek_season on public.matches;
create trigger trg_validate_match_gameweek_season
before insert or update of season_id, gameweek_id on public.matches
for each row execute function public.validate_match_gameweek_season();

create index if not exists idx_gameweeks_season on public.gameweeks(season_id);
create index if not exists idx_matches_season on public.matches(season_id);
create index if not exists idx_matches_home_team on public.matches(home_team_id);
create index if not exists idx_matches_away_team on public.matches(away_team_id);
create index if not exists idx_fantasy_rules_season on public.fantasy_rules(season_id);
create index if not exists idx_fantasy_rules_church on public.fantasy_rules(church_id) where church_id is not null;
create index if not exists idx_leagues_season on public.fantasy_leagues(season_id);
create index if not exists idx_ftplayers_player on public.fantasy_team_players(player_id);
create index if not exists idx_transfers_gameweek on public.transfers(gameweek_id);
create index if not exists idx_transfers_player_out on public.transfers(player_out_id) where player_out_id is not null;
create index if not exists idx_transfers_player_in on public.transfers(player_in_id);
create index if not exists idx_ftgw_points_gameweek on public.fantasy_team_gameweek_points(gameweek_id);
create index if not exists idx_subscriptions_church on public.subscriptions(church_id);
create index if not exists idx_payments_church_created on public.payments(church_id, created_at desc);
create index if not exists idx_payments_subscription on public.payments(subscription_id) where subscription_id is not null;
create index if not exists idx_invoices_church on public.invoices(church_id);
create index if not exists idx_invoices_payment on public.invoices(payment_id) where payment_id is not null;
create index if not exists idx_wallet_transactions_church_created on public.church_wallet_transactions(church_id, created_at desc);
create index if not exists idx_announcements_church_published on public.announcements(church_id, published_at desc);
create index if not exists idx_audit_actor on public.audit_logs(actor_id) where actor_id is not null;

-- Historical competition records block accidental parent deletion. Current
-- squad rows may still cascade when an unscored team is explicitly removed.
alter table public.fantasy_teams drop constraint if exists fantasy_teams_league_id_fkey;
alter table public.fantasy_teams add constraint fantasy_teams_league_id_fkey
  foreign key(league_id) references public.fantasy_leagues(id) on delete restrict;
alter table public.transfers drop constraint if exists transfers_fantasy_team_id_fkey;
alter table public.transfers add constraint transfers_fantasy_team_id_fkey
  foreign key(fantasy_team_id) references public.fantasy_teams(id) on delete restrict;
alter table public.fantasy_team_gameweek_points drop constraint if exists fantasy_team_gameweek_points_fantasy_team_id_fkey;
alter table public.fantasy_team_gameweek_points add constraint fantasy_team_gameweek_points_fantasy_team_id_fkey
  foreign key(fantasy_team_id) references public.fantasy_teams(id) on delete restrict;
alter table public.fantasy_team_gameweek_points drop constraint if exists fantasy_team_gameweek_points_gameweek_id_fkey;
alter table public.fantasy_team_gameweek_points add constraint fantasy_team_gameweek_points_gameweek_id_fkey
  foreign key(gameweek_id) references public.gameweeks(id) on delete restrict;
alter table public.fantasy_team_gameweek_players drop constraint if exists fantasy_team_gameweek_players_fantasy_team_id_fkey;
alter table public.fantasy_team_gameweek_players add constraint fantasy_team_gameweek_players_fantasy_team_id_fkey
  foreign key(fantasy_team_id) references public.fantasy_teams(id) on delete restrict;
alter table public.fantasy_team_gameweek_players drop constraint if exists fantasy_team_gameweek_players_gameweek_id_fkey;
alter table public.fantasy_team_gameweek_players add constraint fantasy_team_gameweek_players_gameweek_id_fkey
  foreign key(gameweek_id) references public.gameweeks(id) on delete restrict;

-- Repair only duplicate role flags/orders; player membership itself is retained.
with ranked as (
  select id, row_number() over(partition by fantasy_team_id order by added_at, id) rn
  from public.fantasy_team_players where is_captain
)
update public.fantasy_team_players p set is_captain = false
from ranked r where p.id = r.id and r.rn > 1;
with ranked as (
  select id, row_number() over(partition by fantasy_team_id order by added_at, id) rn
  from public.fantasy_team_players where is_vice_captain
)
update public.fantasy_team_players p set is_vice_captain = false
from ranked r where p.id = r.id and r.rn > 1;
with ranked as (
  select id, row_number() over(partition by fantasy_team_id order by bench_order nulls last, added_at, id) rn
  from public.fantasy_team_players where is_bench
)
update public.fantasy_team_players p set bench_order = r.rn
from ranked r where p.id = r.id and r.rn <= 4;

create unique index if not exists uq_ftplayers_one_captain
  on public.fantasy_team_players(fantasy_team_id) where is_captain;
create unique index if not exists uq_ftplayers_one_vice_captain
  on public.fantasy_team_players(fantasy_team_id) where is_vice_captain;
with ranked as (
  select id,row_number() over(partition by fantasy_team_id,gameweek_id order by created_at,id) rn
  from public.fantasy_team_gameweek_players where is_captain
)
update public.fantasy_team_gameweek_players p set is_captain=false
from ranked r where p.id=r.id and r.rn>1;
with ranked as (
  select id,row_number() over(partition by fantasy_team_id,gameweek_id order by created_at,id) rn
  from public.fantasy_team_gameweek_players where is_vice_captain
)
update public.fantasy_team_gameweek_players p set is_vice_captain=false
from ranked r where p.id=r.id and r.rn>1;
create unique index if not exists uq_snapshots_one_captain
  on public.fantasy_team_gameweek_players(fantasy_team_id, gameweek_id) where is_captain;
create unique index if not exists uq_snapshots_one_vice_captain
  on public.fantasy_team_gameweek_players(fantasy_team_id, gameweek_id) where is_vice_captain;

-- Finalized lineup/point history is immutable to ordinary sessions even if a
-- future policy is accidentally broadened.
create or replace function public.protect_finalized_gameweek_history()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare locked_at timestamptz;
begin
  locked_at := case when tg_op = 'DELETE' then old.finalized_at else coalesce(old.finalized_at, new.finalized_at) end;
  if locked_at is not null and auth.role() <> 'service_role' then
    raise exception 'Finalized gameweek history is immutable' using errcode = '42501';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;
drop trigger if exists trg_protect_finalized_snapshot on public.fantasy_team_gameweek_players;
create trigger trg_protect_finalized_snapshot
before update or delete on public.fantasy_team_gameweek_players
for each row execute function public.protect_finalized_gameweek_history();
drop trigger if exists trg_protect_finalized_points on public.fantasy_team_gameweek_points;
create trigger trg_protect_finalized_points
before update or delete on public.fantasy_team_gameweek_points
for each row execute function public.protect_finalized_gameweek_history();

-- Church admins may draft and submit ads, but cannot approve them or edit live
-- creative without another review.
create or replace function public.protect_advertisement_workflow()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if public.is_super_admin() or auth.role() = 'service_role' then
    return case when tg_op = 'DELETE' then old else new end;
  end if;
  if tg_op = 'INSERT' then
    if new.status <> 'draft' or new.impressions <> 0 or new.clicks <> 0 then
      raise exception 'Church advertisements must start as drafts' using errcode = '42501';
    end if;
  elsif tg_op = 'UPDATE' then
    if new.church_id <> old.church_id
       or new.impressions <> old.impressions or new.clicks <> old.clicks then
      raise exception 'Protected advertisement fields cannot be changed' using errcode = '42501';
    end if;
    if old.status = 'active' and (
      new.title is distinct from old.title or new.description is distinct from old.description
      or new.image_url is distinct from old.image_url or new.target_url is distinct from old.target_url
      or new.placement is distinct from old.placement or new.start_date is distinct from old.start_date
      or new.end_date is distinct from old.end_date or new.budget is distinct from old.budget
    ) then
      raise exception 'Pause and resubmit an active advertisement before editing';
    end if;
    if new.status not in ('draft', 'pending_review', 'paused') then
      raise exception 'Only platform administrators may approve or reject advertisements'
        using errcode = '42501';
    end if;
  elsif tg_op = 'DELETE' and old.status not in ('draft', 'rejected') then
    raise exception 'Only draft or rejected advertisements may be deleted';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;
drop trigger if exists trg_protect_advertisement_workflow on public.advertisements;
create trigger trg_protect_advertisement_workflow
before insert or update or delete on public.advertisements
for each row execute function public.protect_advertisement_workflow();

create or replace function public.review_advertisement(
  target_advertisement_id uuid,
  new_status public.ad_status
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare target_church uuid;
begin
  if not public.is_super_admin() then raise exception 'Super admin only' using errcode = '42501'; end if;
  if new_status not in ('active', 'rejected', 'paused', 'ended') then
    raise exception 'Invalid moderation status';
  end if;
  update public.advertisements set status = new_status
  where id = target_advertisement_id returning church_id into target_church;
  if target_church is null then raise exception 'Advertisement not found'; end if;
  insert into public.audit_logs(actor_id, church_id, action, entity_type, entity_id, metadata)
  values(auth.uid(), target_church, 'advertisement.reviewed', 'advertisement', target_advertisement_id,
         jsonb_build_object('status', new_status));
end;
$$;
revoke all on function public.review_advertisement(uuid, public.ad_status) from public, anon;
grant execute on function public.review_advertisement(uuid, public.ad_status) to authenticated;

-- Updating a notification is deliberately limited to the read flag.
create or replace function public.protect_notification_columns()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.id <> old.id or new.user_id <> old.user_id
     or new.church_id is distinct from old.church_id
     or new.title <> old.title or new.message is distinct from old.message
     or new.type <> old.type or new.created_at <> old.created_at then
    raise exception 'Only notification read state may be changed' using errcode = '42501';
  end if;
  return new;
end;
$$;
drop trigger if exists trg_protect_notification_columns on public.notifications;
create trigger trg_protect_notification_columns
before update on public.notifications
for each row execute function public.protect_notification_columns();
revoke update on public.notifications from anon, authenticated;
grant update (read) on public.notifications to authenticated;

-- Audit history is append-only outside explicit service-role retention work.
create or replace function public.protect_audit_log_history()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.role() <> 'service_role' then
    raise exception 'Audit logs are append-only' using errcode = '42501';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;
drop trigger if exists trg_protect_audit_log_history on public.audit_logs;
create trigger trg_protect_audit_log_history
before update or delete on public.audit_logs
for each row execute function public.protect_audit_log_history();
revoke insert, update, delete on public.audit_logs from anon, authenticated;

-- Lock down trigger/internal functions; table owners and service_role retain the
-- explicit maintenance surface only. Replacing the bodies keeps every relation
-- schema-qualified after moving to an empty search path.
alter function public.set_updated_at() set search_path = '';
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles(id,full_name,avatar_url)
  values(new.id,coalesce(new.raw_user_meta_data->>'full_name',new.email),new.raw_user_meta_data->>'avatar_url');
  return new;
end;
$$;
create or replace function public.handle_new_church()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.church_wallet(church_id,balance) values(new.id,0);
  insert into public.subscriptions(church_id,tier,status,current_period_start)
  values(new.id,'free','active',now());
  insert into public.church_settings(church_id) values(new.id);
  insert into public.church_members(church_id,user_id,role,status)
  values(new.id,new.owner_id,'church_admin','active');
  return new;
end;
$$;
create or replace function public.recompute_team_total_points()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.fantasy_teams set total_points=(
    select coalesce(sum(points),0) from public.fantasy_team_gameweek_points
    where fantasy_team_id=new.fantasy_team_id
  ),updated_at=now() where id=new.fantasy_team_id;
  return new;
end;
$$;
revoke all on function public.set_updated_at() from public, anon, authenticated;
revoke all on function public.handle_new_user() from public, anon, authenticated;
revoke all on function public.handle_new_church() from public, anon, authenticated;
revoke all on function public.recompute_team_total_points() from public, anon, authenticated;
revoke all on function public.score_gameweek_player_stats(uuid) from public, anon, authenticated;
revoke all on function public.roll_up_team_gameweek_points(uuid) from public, anon, authenticated;
revoke all on function public.recompute_league_ranks(uuid) from public, anon, authenticated;
grant execute on function public.score_gameweek_player_stats(uuid) to service_role;
grant execute on function public.roll_up_team_gameweek_points(uuid) to service_role;
grant execute on function public.recompute_league_ranks(uuid) to service_role;

commit;

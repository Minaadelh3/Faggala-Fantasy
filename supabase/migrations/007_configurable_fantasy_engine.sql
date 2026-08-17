-- Configurable Fantasy rules, immutable rule snapshots, price history and
-- concurrency-safe league/team/gameplay operations.

begin;

set local search_path = public, extensions;

-- Migration 005 reflected the current values in physical CHECK constraints.
-- Keep only invariant lower bounds here; the versioned rule snapshot supplies
-- season-specific upper bounds.
alter table public.fantasy_teams drop constraint if exists fantasy_teams_free_transfers_valid;
alter table public.fantasy_teams
  add constraint fantasy_teams_free_transfers_nonnegative check(free_transfers>=0) not valid;
alter table public.fantasy_team_players drop constraint if exists ftp_bench_order_check;
alter table public.fantasy_team_players
  add constraint ftp_bench_order_positive check(
    (is_bench and bench_order>=1) or (not is_bench and bench_order is null)
  ) not valid;
with ranked as (
  select id,row_number() over(
    partition by fantasy_team_id order by bench_order nulls last,added_at,id
  ) rn from public.fantasy_team_players where is_bench
)
update public.fantasy_team_players p set bench_order=ranked.rn
from ranked where p.id=ranked.id;
create unique index if not exists uq_ftplayers_bench_order
  on public.fantasy_team_players(fantasy_team_id,bench_order) where is_bench;
do $$
declare constraint_name text;
begin
  for constraint_name in
    select conname from pg_catalog.pg_constraint
    where conrelid='public.fantasy_team_gameweek_players'::regclass
      and contype='c' and pg_catalog.pg_get_constraintdef(oid) like '%bench_order%4%'
  loop
    execute format('alter table public.fantasy_team_gameweek_players drop constraint %I',constraint_name);
  end loop;
end;
$$;
alter table public.fantasy_team_gameweek_players
  add constraint snapshot_bench_order_positive check(
    (is_bench and bench_order>=1) or (is_starting and bench_order is null)
  ) not valid;
with ranked as (
  select id,row_number() over(
    partition by fantasy_team_id,gameweek_id order by bench_order nulls last,created_at,id
  ) rn from public.fantasy_team_gameweek_players where is_bench
)
update public.fantasy_team_gameweek_players p set bench_order=ranked.rn
from ranked where p.id=ranked.id;
create unique index if not exists uq_snapshots_bench_order
  on public.fantasy_team_gameweek_players(fantasy_team_id,gameweek_id,bench_order) where is_bench;

-- The current product UI explicitly documents these football defaults. They
-- are stored as data so future seasons can change them without rewriting SQL.
alter table public.fantasy_rules
  add column if not exists version integer not null default 1,
  add column if not exists is_active boolean not null default true,
  add column if not exists locked_at timestamptz,
  add column if not exists updated_at timestamptz not null default now();

alter table public.fantasy_rules
  drop constraint if exists fantasy_rules_season_id_church_id_key;

update public.fantasy_rules
set rules = jsonb_build_object(
  'starting_budget', 100.0,
  'squad_size', 15,
  'lineup_size', 11,
  'bench_size', 4,
  'position_counts', jsonb_build_object('GK',2,'DEF',5,'MID',5,'FWD',3),
  'lineup_min', jsonb_build_object('GK',1,'DEF',3,'MID',2,'FWD',1),
  'lineup_max', jsonb_build_object('GK',1,'DEF',5,'MID',5,'FWD',3),
  'max_players_per_club', 3,
  'free_transfers_per_gameweek', 1,
  'max_free_transfers', 2,
  'additional_transfer_cost', 4,
  'captain_multiplier', 2,
  'vice_captain_fallback', true,
  'selling_price_basis', 'current',
  'goal_gk_def', 6,
  'goal_mid', 5,
  'goal_fwd', 4,
  'assist', 3,
  'clean_sheet_gk_def', 4,
  'clean_sheet_mid', 1,
  'yellow_card', -1,
  'red_card', -3,
  'own_goal', -2,
  'penalty_miss', -2,
  'penalty_save', 5,
  'save_every_3', 1,
  'minutes_60_plus', 2,
  'minutes_under_60', 1
) || rules;

create or replace function public.fantasy_rules_are_valid(candidate jsonb)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
declare
  pos text;
  squad_total integer := 0;
begin
  if jsonb_typeof(candidate) <> 'object' then return false; end if;
  if (candidate->>'starting_budget')::numeric <= 0
     or (candidate->>'squad_size')::integer <= 0
     or (candidate->>'lineup_size')::integer <= 0
     or (candidate->>'bench_size')::integer < 0
     or (candidate->>'lineup_size')::integer + (candidate->>'bench_size')::integer
        <> (candidate->>'squad_size')::integer
     or (candidate->>'max_players_per_club')::integer <= 0
     or (candidate->>'free_transfers_per_gameweek')::integer < 0
     or (candidate->>'max_free_transfers')::integer < 0
     or (candidate->>'additional_transfer_cost')::integer < 0
     or (candidate->>'captain_multiplier')::integer not between 1 and 10
     or coalesce(candidate->>'selling_price_basis','') not in ('current','purchase')
     or jsonb_typeof(candidate->'position_counts') <> 'object'
     or jsonb_typeof(candidate->'lineup_min') <> 'object'
     or jsonb_typeof(candidate->'lineup_max') <> 'object' then
    return false;
  end if;

  foreach pos in array array['GK','DEF','MID','FWD'] loop
    if (candidate->'position_counts'->>pos)::integer <= 0
       or (candidate->'lineup_min'->>pos)::integer < 0
       or (candidate->'lineup_max'->>pos)::integer < (candidate->'lineup_min'->>pos)::integer
       or (candidate->'lineup_max'->>pos)::integer > (candidate->'position_counts'->>pos)::integer then
      return false;
    end if;
    squad_total := squad_total + (candidate->'position_counts'->>pos)::integer;
  end loop;
  if squad_total <> (candidate->>'squad_size')::integer then return false; end if;

  -- Required scoring keys. Negative card/penalty values are intentional.
  perform (candidate->>'goal_gk_def')::integer,
          (candidate->>'goal_mid')::integer,
          (candidate->>'goal_fwd')::integer,
          (candidate->>'assist')::integer,
          (candidate->>'clean_sheet_gk_def')::integer,
          (candidate->>'clean_sheet_mid')::integer,
          (candidate->>'yellow_card')::integer,
          (candidate->>'red_card')::integer,
          (candidate->>'own_goal')::integer,
          (candidate->>'penalty_miss')::integer,
          (candidate->>'penalty_save')::integer,
          (candidate->>'save_every_3')::integer,
          (candidate->>'minutes_60_plus')::integer,
          (candidate->>'minutes_under_60')::integer;
  return true;
exception when others then
  return false;
end;
$$;

alter table public.fantasy_rules
  add constraint fantasy_rules_version_positive check(version > 0) not valid,
  add constraint fantasy_rules_json_valid check(public.fantasy_rules_are_valid(rules)) not valid;

with ranked as (
  select id, row_number() over(
    partition by season_id, church_id order by version desc, created_at desc, id
  ) rn
  from public.fantasy_rules where is_active
)
update public.fantasy_rules r set is_active = false
from ranked x where r.id = x.id and x.rn > 1;

create unique index if not exists uq_fantasy_rules_global_active
  on public.fantasy_rules(season_id) where church_id is null and is_active;
create unique index if not exists uq_fantasy_rules_church_active
  on public.fantasy_rules(season_id, church_id) where church_id is not null and is_active;
create unique index if not exists uq_fantasy_rules_scope_version
  on public.fantasy_rules(season_id, coalesce(church_id, '00000000-0000-0000-0000-000000000000'::uuid), version);

drop trigger if exists trg_fantasy_rules_updated_at on public.fantasy_rules;
create trigger trg_fantasy_rules_updated_at before update on public.fantasy_rules
for each row execute function public.set_updated_at();

create or replace function public.protect_locked_fantasy_rules()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.locked_at is not null and auth.role() <> 'service_role' then
    if tg_op='DELETE'
       or new.season_id<>old.season_id
       or new.church_id is distinct from old.church_id
       or new.version<>old.version
       or new.rules<>old.rules
       or new.locked_at is distinct from old.locked_at
       or not (old.is_active and not new.is_active) then
      raise exception 'A locked Fantasy rule version is immutable' using errcode = '42501';
    end if;
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;
drop trigger if exists trg_protect_locked_fantasy_rules on public.fantasy_rules;
create trigger trg_protect_locked_fantasy_rules
before update or delete on public.fantasy_rules
for each row execute function public.protect_locked_fantasy_rules();

revoke insert,update,delete on public.fantasy_rules from anon,authenticated;
create or replace function public.create_fantasy_rule_version(
  p_season_id uuid,
  p_church_id uuid,
  p_rules jsonb
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare new_version integer; new_id uuid;
begin
  if p_church_id is null then
    if not public.is_super_admin() then raise exception 'Super admin only' using errcode='42501'; end if;
  elsif not public.is_church_admin(p_church_id) then
    raise exception 'Church admin only' using errcode='42501';
  end if;
  if not public.fantasy_rules_are_valid(p_rules) then raise exception 'Invalid Fantasy rules'; end if;
  perform 1 from public.seasons where id=p_season_id for update;
  if not found then raise exception 'Season not found'; end if;
  select coalesce(max(version),0)+1 into new_version from public.fantasy_rules
  where season_id=p_season_id and church_id is not distinct from p_church_id;
  update public.fantasy_rules set is_active=false
  where season_id=p_season_id and church_id is not distinct from p_church_id and is_active;
  insert into public.fantasy_rules(season_id,church_id,rules,version,is_active)
  values(p_season_id,p_church_id,p_rules,new_version,true) returning id into new_id;
  insert into public.audit_logs(actor_id,church_id,action,entity_type,entity_id,metadata)
  values(auth.uid(),p_church_id,'fantasy_rules.version_created','fantasy_rules',new_id,
         jsonb_build_object('season_id',p_season_id,'version',new_version));
  return new_id;
end;
$$;
revoke all on function public.create_fantasy_rule_version(uuid,uuid,jsonb) from public,anon;
grant execute on function public.create_fantasy_rule_version(uuid,uuid,jsonb) to authenticated;

create or replace function public.resolve_fantasy_rules(
  target_season_id uuid,
  target_church_id uuid
)
returns table(rule_id uuid, rule_version integer, rules jsonb)
language sql
security definer
stable
set search_path = ''
as $$
  select r.id, r.version, r.rules
  from public.fantasy_rules r
  where r.season_id = target_season_id
    and r.is_active
    and (r.church_id = target_church_id or r.church_id is null)
  order by (r.church_id is not null) desc, r.version desc
  limit 1;
$$;

revoke all on function public.fantasy_rules_are_valid(jsonb) from public, anon, authenticated;
revoke all on function public.resolve_fantasy_rules(uuid, uuid) from public, anon, authenticated;
grant execute on function public.resolve_fantasy_rules(uuid, uuid) to service_role;

create or replace function public.get_league_rules(p_league_id uuid)
returns jsonb
language plpgsql
security definer
stable
set search_path = ''
as $$
declare
  league_row public.fantasy_leagues;
  result jsonb;
begin
  select * into league_row from public.fantasy_leagues where id = p_league_id;
  if league_row.id is null then raise exception 'League not found'; end if;
  if league_row.is_private and league_row.created_by <> auth.uid()
     and not public.is_super_admin()
     and not exists(select 1 from public.fantasy_teams ft where ft.league_id=p_league_id and ft.user_id=auth.uid())
     and not exists(select 1 from public.fantasy_league_join_authorizations a where a.league_id=p_league_id and a.user_id=auth.uid()) then
    raise exception 'League unavailable' using errcode = '42501';
  end if;
  if league_row.church_id is not null and not public.is_church_member(league_row.church_id) then
    raise exception 'Church membership required' using errcode = '42501';
  end if;
  select r.rules into result
  from public.resolve_fantasy_rules(league_row.season_id, league_row.church_id) r;
  if result is null then raise exception 'No active Fantasy rules for this league'; end if;
  return result;
end;
$$;
revoke all on function public.get_league_rules(uuid) from public, anon;
grant execute on function public.get_league_rules(uuid) to authenticated;

-- Store invite secrets separately: RLS is row-level and cannot hide one column
-- of an otherwise visible league row.
create table public.fantasy_league_secrets (
  league_id uuid primary key references public.fantasy_leagues(id) on delete cascade,
  invite_code text not null,
  created_at timestamptz not null default now(),
  rotated_at timestamptz,
  constraint fantasy_league_secrets_code_format check(invite_code ~ '^FAG-[A-F0-9]{10,64}$')
);
create unique index uq_fantasy_league_secrets_code_ci
  on public.fantasy_league_secrets(lower(invite_code));

insert into public.fantasy_league_secrets(league_id, invite_code)
select id,
       case when upper(invite_code) ~ '^FAG-[A-F0-9]{10,64}$' then upper(invite_code)
            else 'FAG-' || upper(encode(extensions.gen_random_bytes(10), 'hex')) end
from public.fantasy_leagues
where is_private and invite_code is not null
on conflict(league_id) do nothing;
update public.fantasy_leagues set invite_code = null where invite_code is not null;

alter table public.fantasy_league_secrets enable row level security;
create policy "league_secrets_owner_select" on public.fantasy_league_secrets
for select using (
  public.is_super_admin() or exists(
    select 1 from public.fantasy_leagues l
    where l.id = league_id and (
      l.created_by = auth.uid()
      or (l.church_id is not null and public.has_church_role(
        l.church_id, array['church_admin','league_admin']::public.church_role[]
      ))
    )
  )
);
revoke insert, update, delete on public.fantasy_league_secrets from anon, authenticated;

create or replace function public.get_league_invite_code(p_league_id uuid)
returns text
language plpgsql
security definer
stable
set search_path = ''
as $$
declare result text;
begin
  if not exists(
    select 1 from public.fantasy_leagues l where l.id=p_league_id and (
      l.created_by=auth.uid() or public.is_super_admin()
      or (l.church_id is not null and public.has_church_role(
        l.church_id,array['church_admin','league_admin']::public.church_role[]
      ))
    )
  ) then raise exception 'Forbidden' using errcode='42501'; end if;
  select invite_code into result from public.fantasy_league_secrets where league_id=p_league_id;
  return result;
end;
$$;
revoke all on function public.get_league_invite_code(uuid) from public, anon;
grant execute on function public.get_league_invite_code(uuid) to authenticated;

create or replace function public.create_fantasy_league(
  p_name text,
  p_church_id uuid,
  p_is_private boolean default true,
  p_max_members integer default 100
)
returns public.fantasy_leagues
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_season uuid;
  new_league public.fantasy_leagues;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if length(btrim(p_name)) not between 3 and 60 then raise exception 'League name must be 3-60 characters'; end if;
  if p_max_members not between 2 and 1000 then raise exception 'max_members must be between 2 and 1000'; end if;
  if p_church_id is not null and not public.is_church_member(p_church_id) then
    raise exception 'Join the church first' using errcode='42501';
  end if;
  select id into current_season from public.seasons where is_current limit 1;
  if current_season is null then raise exception 'No current season'; end if;
  if not exists(select 1 from public.resolve_fantasy_rules(current_season,p_church_id)) then
    raise exception 'No active Fantasy rules for current season';
  end if;

  insert into public.fantasy_leagues(
    church_id,season_id,created_by,name,is_private,invite_code,max_members,status
  ) values(
    p_church_id,current_season,auth.uid(),btrim(p_name),p_is_private,null,p_max_members,'active'
  ) returning * into new_league;

  if p_is_private then
    insert into public.fantasy_league_secrets(league_id,invite_code)
    values(new_league.id,'FAG-'||upper(encode(extensions.gen_random_bytes(10),'hex')));
  end if;
  insert into public.audit_logs(actor_id,church_id,action,entity_type,entity_id)
  values(auth.uid(),p_church_id,'fantasy_league.created','fantasy_league',new_league.id);
  return new_league;
end;
$$;

create or replace function public.join_fantasy_league(p_invite_code text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare league_row public.fantasy_leagues;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select l.* into league_row
  from public.fantasy_league_secrets s
  join public.fantasy_leagues l on l.id=s.league_id
  where lower(s.invite_code)=lower(btrim(p_invite_code))
  for update of l;
  if league_row.id is null or league_row.status <> 'active' then raise exception 'League not found or inactive'; end if;
  if league_row.church_id is not null and not public.is_church_member(league_row.church_id) then
    raise exception 'Church membership required' using errcode='42501';
  end if;
  if exists(select 1 from public.fantasy_teams where league_id=league_row.id and user_id=auth.uid()) then
    raise exception 'Already participating';
  end if;
  if (select count(*) from public.fantasy_teams where league_id=league_row.id) >= league_row.max_members then
    raise exception 'League is full';
  end if;
  insert into public.fantasy_league_join_authorizations(league_id,user_id)
  values(league_row.id,auth.uid()) on conflict do nothing;
  return league_row.id;
end;
$$;

-- Historical market data. Existing player.price remains the current price for
-- compatibility; each subsequent price change is captured automatically.
create table public.player_price_history (
  id uuid primary key default uuid_generate_v4(),
  player_id uuid not null references public.players(id) on delete restrict,
  gameweek_id uuid references public.gameweeks(id) on delete restrict,
  price numeric(6,2) not null check(price >= 0),
  effective_at timestamptz not null default now(),
  changed_by uuid references public.profiles(id) on delete set null,
  reason text
);
create index idx_player_price_history_lookup
  on public.player_price_history(player_id,effective_at desc,id desc);
insert into public.player_price_history(player_id,price,effective_at,reason)
select id,price,created_at,'migration baseline' from public.players;
alter table public.player_price_history enable row level security;
create policy "player_price_history_select" on public.player_price_history for select using(true);
create policy "player_price_history_admin" on public.player_price_history for all
using(public.is_super_admin()) with check(public.is_super_admin());

create or replace function public.capture_player_price_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.price is distinct from old.price then
    insert into public.player_price_history(player_id,price,effective_at,changed_by,reason)
    values(new.id,new.price,clock_timestamp(),auth.uid(),'player price update');
  end if;
  return new;
end;
$$;
drop trigger if exists trg_capture_player_price_change on public.players;
create trigger trg_capture_player_price_change after update of price on public.players
for each row execute function public.capture_player_price_change();
revoke all on function public.capture_player_price_change() from public, anon, authenticated;

alter table public.fantasy_team_gameweek_players
  add column if not exists rule_id uuid references public.fantasy_rules(id) on delete restrict,
  add column if not exists rule_version integer,
  add column if not exists rules_snapshot jsonb;

update public.fantasy_team_gameweek_players s
set rule_id = rr.rule_id, rule_version = rr.rule_version, rules_snapshot = rr.rules
from public.fantasy_teams ft
join public.fantasy_leagues fl on fl.id=ft.league_id
join lateral public.resolve_fantasy_rules(fl.season_id,fl.church_id) rr on true
where ft.id=s.fantasy_team_id and s.rules_snapshot is null;

alter table public.fantasy_team_gameweek_players
  drop constraint if exists fantasy_team_gameweek_players_multiplier_check;
alter table public.fantasy_team_gameweek_players
  add constraint fantasy_team_gameweek_players_multiplier_check check(multiplier between 0 and 10) not valid,
  add constraint fantasy_team_gameweek_players_rules_valid
    check(rules_snapshot is null or public.fantasy_rules_are_valid(rules_snapshot)) not valid;

alter table public.transfers
  add column if not exists transfer_number integer,
  add column if not exists rules_snapshot jsonb;
alter table public.transfers
  add constraint transfers_prices_nonnegative check(
    (player_out_price is null or player_out_price >= 0)
    and (player_in_price is null or player_in_price >= 0)
    and point_penalty >= 0
  ) not valid;

create or replace function public.assert_squad_valid(target_team_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  rule jsonb;
  player_count integer;
  starting_count integer;
  captain_count integer;
  vice_count integer;
  position_name text;
  actual integer;
begin
  select rr.rules into rule
  from public.fantasy_teams ft
  join public.fantasy_leagues fl on fl.id=ft.league_id
  join lateral public.resolve_fantasy_rules(fl.season_id,fl.church_id) rr on true
  where ft.id=target_team_id;
  if rule is null then raise exception 'No active Fantasy rules for team'; end if;

  select count(*),count(*) filter(where not is_bench),count(*) filter(where is_captain),count(*) filter(where is_vice_captain)
  into player_count,starting_count,captain_count,vice_count
  from public.fantasy_team_players where fantasy_team_id=target_team_id;
  if player_count <> (rule->>'squad_size')::integer then raise exception 'Invalid squad size'; end if;
  if starting_count <> (rule->>'lineup_size')::integer then raise exception 'Invalid starting lineup size'; end if;

  foreach position_name in array array['GK','DEF','MID','FWD'] loop
    select count(*) into actual
    from public.fantasy_team_players ftp join public.players p on p.id=ftp.player_id
    where ftp.fantasy_team_id=target_team_id and p.position::text=position_name;
    if actual <> (rule->'position_counts'->>position_name)::integer then
      raise exception 'Invalid % squad count', position_name;
    end if;
    select count(*) into actual
    from public.fantasy_team_players ftp join public.players p on p.id=ftp.player_id
    where ftp.fantasy_team_id=target_team_id and not ftp.is_bench and p.position::text=position_name;
    if actual not between (rule->'lineup_min'->>position_name)::integer
                          and (rule->'lineup_max'->>position_name)::integer then
      raise exception 'Invalid starting % count', position_name;
    end if;
  end loop;

  if exists(
    select 1 from public.fantasy_team_players ftp join public.players p on p.id=ftp.player_id
    where ftp.fantasy_team_id=target_team_id and p.team_id is not null
    group by p.team_id having count(*) > (rule->>'max_players_per_club')::integer
  ) then raise exception 'Maximum players from one real team exceeded'; end if;
  if (select bank from public.fantasy_teams where id=target_team_id) < 0 then raise exception 'Squad exceeds budget'; end if;
  if (select count(*) from public.fantasy_team_players where fantasy_team_id=target_team_id and is_bench)
     <> (rule->>'bench_size')::integer then raise exception 'Invalid bench size'; end if;
  if captain_count <> 1 or vice_count <> 1 then raise exception 'Choose exactly one captain and vice-captain'; end if;
  if exists(select 1 from public.fantasy_team_players where fantasy_team_id=target_team_id and is_captain and is_vice_captain)
     or exists(select 1 from public.fantasy_team_players where fantasy_team_id=target_team_id and is_bench and (is_captain or is_vice_captain)) then
    raise exception 'Captain and vice-captain must be distinct starters';
  end if;
  if (select count(*) from public.fantasy_team_players where fantasy_team_id=target_team_id and is_bench and bench_order is not null)
       <> (rule->>'bench_size')::integer
     or (select count(distinct bench_order) from public.fantasy_team_players where fantasy_team_id=target_team_id and is_bench)
       <> (rule->>'bench_size')::integer then raise exception 'Bench order must be unique and complete'; end if;
end;
$$;

create or replace function public.create_fantasy_team_with_squad(
  p_league_id uuid,
  p_name text,
  p_players jsonb
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  league_row public.fantasy_leagues;
  rule jsonb;
  created_team_id uuid;
  deadline timestamptz;
  squad_cost numeric;
  expected_size integer;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if length(btrim(p_name)) not between 3 and 40 then raise exception 'Team name must be 3-40 characters'; end if;
  if jsonb_typeof(p_players) <> 'array' then raise exception 'Players must be an array'; end if;

  select * into league_row from public.fantasy_leagues where id=p_league_id for update;
  if league_row.id is null or league_row.status <> 'active' then raise exception 'League unavailable'; end if;
  if league_row.church_id is not null and not public.is_church_member(league_row.church_id) then
    raise exception 'Church membership required' using errcode='42501';
  end if;
  if league_row.is_private and league_row.created_by <> auth.uid()
     and not exists(select 1 from public.fantasy_league_join_authorizations where league_id=p_league_id and user_id=auth.uid()) then
    raise exception 'Private league invitation required' using errcode='42501';
  end if;
  if exists(select 1 from public.fantasy_teams where league_id=p_league_id and user_id=auth.uid()) then
    raise exception 'A team already exists in this league';
  end if;
  if (select count(*) from public.fantasy_teams where league_id=p_league_id) >= league_row.max_members then
    raise exception 'League is full';
  end if;

  select rr.rules into rule from public.resolve_fantasy_rules(league_row.season_id,league_row.church_id) rr;
  if rule is null then raise exception 'No active Fantasy rules for league'; end if;
  expected_size := (rule->>'squad_size')::integer;
  if jsonb_array_length(p_players) <> expected_size then raise exception 'Incorrect squad size'; end if;
  if (select count(distinct (x->>'player_id')::uuid) from jsonb_array_elements(p_players) x) <> expected_size then
    raise exception 'Duplicate players are not allowed';
  end if;
  if exists(
    select 1 from jsonb_array_elements(p_players) x
    left join public.players p on p.id=(x->>'player_id')::uuid where p.id is null
  ) then raise exception 'Unknown player'; end if;
  select sum(p.price) into squad_cost
  from jsonb_array_elements(p_players) x join public.players p on p.id=(x->>'player_id')::uuid;
  if squad_cost > (rule->>'starting_budget')::numeric then raise exception 'Squad exceeds budget'; end if;
  select transfer_deadline into deadline from public.gameweeks
  where season_id=league_row.season_id and status='upcoming' order by number limit 1;
  if deadline is not null and now() >= deadline then raise exception 'Gameweek deadline passed'; end if;

  insert into public.fantasy_teams(league_id,user_id,name,budget,starting_budget,bank,free_transfers)
  values(p_league_id,auth.uid(),btrim(p_name),(rule->>'starting_budget')::numeric,
         (rule->>'starting_budget')::numeric,(rule->>'starting_budget')::numeric-squad_cost,0)
  returning id into created_team_id;
  insert into public.fantasy_team_players(
    fantasy_team_id,player_id,purchase_price,is_bench,bench_order,is_captain,is_vice_captain
  )
  select created_team_id,(x->>'player_id')::uuid,p.price,coalesce((x->>'is_bench')::boolean,false),
         nullif(x->>'bench_order','')::integer,coalesce((x->>'is_captain')::boolean,false),
         coalesce((x->>'is_vice_captain')::boolean,false)
  from jsonb_array_elements(p_players) x join public.players p on p.id=(x->>'player_id')::uuid;
  perform public.assert_squad_valid(created_team_id);
  return created_team_id;
end;
$$;

create or replace function public.save_lineup(p_team_id uuid,p_lineup jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare v_season_id uuid; deadline timestamptz; expected_size integer;
begin
  if not public.owns_fantasy_team(p_team_id) then raise exception 'Forbidden' using errcode='42501'; end if;
  select fl.season_id,(rr.rules->>'squad_size')::integer into v_season_id,expected_size
  from public.fantasy_teams ft join public.fantasy_leagues fl on fl.id=ft.league_id
  join lateral public.resolve_fantasy_rules(fl.season_id,fl.church_id) rr on true
  where ft.id=p_team_id;
  select transfer_deadline into deadline from public.gameweeks
  where gameweeks.season_id=v_season_id and status='upcoming' order by number limit 1;
  if deadline is null or now()>=deadline then raise exception 'Lineup is locked'; end if;
  if jsonb_typeof(p_lineup)<>'array' or jsonb_array_length(p_lineup)<>expected_size
     or (select count(distinct (x->>'player_id')::uuid) from jsonb_array_elements(p_lineup)x)<>expected_size then
    raise exception 'Complete unique lineup required';
  end if;
  if exists(
    select 1 from jsonb_array_elements(p_lineup)x where not exists(
      select 1 from public.fantasy_team_players ftp
      where ftp.fantasy_team_id=p_team_id and ftp.player_id=(x->>'player_id')::uuid
    )
  ) then raise exception 'Lineup contains a player outside this squad'; end if;
  update public.fantasy_team_players ftp
  set is_bench=(x->>'is_bench')::boolean,bench_order=nullif(x->>'bench_order','')::integer,
      is_captain=coalesce((x->>'is_captain')::boolean,false),
      is_vice_captain=coalesce((x->>'is_vice_captain')::boolean,false)
  from jsonb_array_elements(p_lineup)x
  where ftp.fantasy_team_id=p_team_id and ftp.player_id=(x->>'player_id')::uuid;
  perform public.assert_squad_valid(p_team_id);
end;
$$;

create or replace function public.execute_transfer(
  p_team_id uuid,p_player_out uuid,p_player_in uuid,p_gameweek_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  outgoing public.fantasy_team_players;
  incoming public.players;
  outgoing_player public.players;
  team_row public.fantasy_teams;
  week_row public.gameweeks;
  league_row public.fantasy_leagues;
  rule jsonb;
  penalty integer;
  sale_price numeric;
  new_bank numeric;
  transfer_no integer;
begin
  if not public.owns_fantasy_team(p_team_id) then raise exception 'Forbidden' using errcode='42501'; end if;
  select * into team_row from public.fantasy_teams where id=p_team_id for update;
  select * into league_row from public.fantasy_leagues where id=team_row.league_id;
  select * into week_row from public.gameweeks where id=p_gameweek_id for update;
  if week_row.id is null or week_row.status<>'upcoming' or now()>=week_row.transfer_deadline then
    raise exception 'Transfer deadline passed';
  end if;
  if league_row.season_id<>week_row.season_id then raise exception 'Wrong gameweek'; end if;
  select rr.rules into rule from public.resolve_fantasy_rules(league_row.season_id,league_row.church_id) rr;
  if rule is null then raise exception 'No active Fantasy rules'; end if;
  select * into outgoing from public.fantasy_team_players
  where fantasy_team_id=p_team_id and player_id=p_player_out;
  select * into outgoing_player from public.players where id=p_player_out;
  select * into incoming from public.players where id=p_player_in;
  if outgoing.id is null or incoming.id is null then raise exception 'Player not found'; end if;
  if p_player_out=p_player_in then raise exception 'Incoming and outgoing player must differ'; end if;
  if outgoing_player.position<>incoming.position then raise exception 'Replacement must have the same position'; end if;
  if exists(select 1 from public.fantasy_team_players where fantasy_team_id=p_team_id and player_id=p_player_in) then
    raise exception 'Incoming player already owned';
  end if;
  sale_price := case rule->>'selling_price_basis' when 'purchase' then outgoing.purchase_price else outgoing_player.price end;
  new_bank := team_row.bank + sale_price - incoming.price;
  if new_bank<0 then raise exception 'Insufficient bank'; end if;
  penalty := case when team_row.free_transfers>0 then 0 else (rule->>'additional_transfer_cost')::integer end;
  select coalesce(max(transfer_number),0)+1 into transfer_no from public.transfers
  where fantasy_team_id=p_team_id and gameweek_id=p_gameweek_id;

  delete from public.fantasy_team_players where id=outgoing.id;
  insert into public.fantasy_team_players(
    fantasy_team_id,player_id,purchase_price,is_captain,is_vice_captain,is_bench,bench_order
  ) values(
    p_team_id,p_player_in,incoming.price,outgoing.is_captain,outgoing.is_vice_captain,outgoing.is_bench,outgoing.bench_order
  );
  update public.fantasy_teams set bank=new_bank,free_transfers=greatest(0,free_transfers-1) where id=p_team_id;
  perform public.assert_squad_valid(p_team_id);
  insert into public.transfers(
    fantasy_team_id,gameweek_id,player_out_id,player_in_id,cost,player_out_price,
    player_in_price,point_penalty,transfer_number,rules_snapshot
  ) values(
    p_team_id,p_gameweek_id,p_player_out,p_player_in,incoming.price-sale_price,sale_price,
    incoming.price,penalty,transfer_no,rule
  );
  return jsonb_build_object('bank',new_bank,'point_penalty',penalty,
    'free_transfers',(select free_transfers from public.fantasy_teams where id=p_team_id));
end;
$$;

create or replace function public.lock_gameweek(target_gameweek_id uuid,p_admin_override boolean default false)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare week_row public.gameweeks; inserted_count integer; first_lock boolean; team record;
begin
  select * into week_row from public.gameweeks where id=target_gameweek_id for update;
  if week_row.id is null then raise exception 'Gameweek not found'; end if;
  if p_admin_override and not (public.is_super_admin() or auth.role()='service_role') then
    raise exception 'Admin override forbidden' using errcode='42501';
  end if;
  if now()<week_row.transfer_deadline and not p_admin_override then raise exception 'Deadline has not passed'; end if;
  first_lock := week_row.status='upcoming';
  if week_row.status not in ('upcoming','locked') then raise exception 'Gameweek cannot be locked from current status'; end if;

  for team in
    select ft.id,rr.rule_id,rr.rule_version,rr.rules
    from public.fantasy_teams ft join public.fantasy_leagues fl on fl.id=ft.league_id
    join lateral public.resolve_fantasy_rules(fl.season_id,fl.church_id) rr on true
    where fl.season_id=week_row.season_id
      and (select count(*) from public.fantasy_team_players x where x.fantasy_team_id=ft.id)=(rr.rules->>'squad_size')::integer
    order by ft.id for update of ft
  loop
    perform public.assert_squad_valid(team.id);
    insert into public.fantasy_team_gameweek_players(
      fantasy_team_id,gameweek_id,player_id,position_at_lock,player_price_at_lock,purchase_price,
      is_starting,is_bench,bench_order,is_captain,is_vice_captain,rule_id,rule_version,rules_snapshot
    )
    select ftp.fantasy_team_id,week_row.id,ftp.player_id,p.position,p.price,ftp.purchase_price,
           not ftp.is_bench,ftp.is_bench,ftp.bench_order,ftp.is_captain,ftp.is_vice_captain,
           team.rule_id,team.rule_version,team.rules
    from public.fantasy_team_players ftp join public.players p on p.id=ftp.player_id
    where ftp.fantasy_team_id=team.id
    on conflict(fantasy_team_id,gameweek_id,player_id) do nothing;
    if first_lock then
      update public.fantasy_teams set has_locked_gameweek=true,
        free_transfers=least((team.rules->>'max_free_transfers')::integer,
          case when has_locked_gameweek then free_transfers+(team.rules->>'free_transfers_per_gameweek')::integer
               else (team.rules->>'free_transfers_per_gameweek')::integer end)
      where id=team.id;
    end if;
  end loop;
  get diagnostics inserted_count=row_count;
  select count(*) into inserted_count from public.fantasy_team_gameweek_players where gameweek_id=week_row.id;
  update public.fantasy_rules r set locked_at=coalesce(locked_at,now())
  where exists(select 1 from public.fantasy_team_gameweek_players s where s.gameweek_id=week_row.id and s.rule_id=r.id);
  update public.gameweeks set status='locked' where id=week_row.id and status='upcoming';
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
  values(auth.uid(),'gameweek.lock','gameweek',week_row.id,
         jsonb_build_object('snapshot_rows',inserted_count,'admin_override',p_admin_override));
  return inserted_count;
end;
$$;

-- Revoke every old/default execute grant before exposing the intended API.
revoke all on function public.create_fantasy_league(text,uuid,boolean,integer) from public,anon;
revoke all on function public.join_fantasy_league(text) from public,anon;
revoke all on function public.create_fantasy_team_with_squad(uuid,text,jsonb) from public,anon;
revoke all on function public.save_lineup(uuid,jsonb) from public,anon;
revoke all on function public.execute_transfer(uuid,uuid,uuid,uuid) from public,anon;
revoke all on function public.assert_squad_valid(uuid) from public,anon,authenticated;
revoke all on function public.lock_gameweek(uuid,boolean) from public,anon,authenticated;
grant execute on function public.create_fantasy_league(text,uuid,boolean,integer) to authenticated;
grant execute on function public.join_fantasy_league(text) to authenticated;
grant execute on function public.create_fantasy_team_with_squad(uuid,text,jsonb) to authenticated;
grant execute on function public.save_lineup(uuid,jsonb) to authenticated;
grant execute on function public.execute_transfer(uuid,uuid,uuid,uuid) to authenticated;
grant execute on function public.lock_gameweek(uuid,boolean) to service_role;

commit;

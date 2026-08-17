-- Fagalla Fantasy production gameplay integrity
-- Forward-only migration. Existing migrations remain untouched.

begin;

alter table gameweeks drop constraint if exists gameweeks_status_check;
alter table gameweeks add constraint gameweeks_status_check
  check (status in ('upcoming', 'locked', 'active', 'finished'));

alter table fantasy_teams
  add column if not exists starting_budget numeric(6,2) not null default 100.00,
  add column if not exists bank numeric(6,2) not null default 100.00,
  add column if not exists free_transfers integer not null default 0,
  add column if not exists has_locked_gameweek boolean not null default false;

update fantasy_teams ft set bank = greatest(0, ft.budget - coalesce((
  select sum(p.price) from fantasy_team_players ftp join players p on p.id = ftp.player_id
  where ftp.fantasy_team_id = ft.id
), 0));

alter table fantasy_teams
  add constraint fantasy_teams_budget_positive check (starting_budget > 0 and bank >= 0) not valid,
  add constraint fantasy_teams_free_transfers_valid check (free_transfers between 0 and 2) not valid;

alter table fantasy_team_players
  add column if not exists purchase_price numeric(6,2);
update fantasy_team_players ftp set purchase_price = p.price
from players p where p.id = ftp.player_id and ftp.purchase_price is null;
alter table fantasy_team_players alter column purchase_price set not null;
alter table fantasy_team_players
  add constraint ftp_bench_order_check check (
    (is_bench and bench_order between 1 and 4) or (not is_bench and bench_order is null)
  ) not valid,
  add constraint ftp_captain_not_bench check (not is_bench or (not is_captain and not is_vice_captain)) not valid,
  add constraint ftp_distinct_roles check (not (is_captain and is_vice_captain)) not valid;

alter table transfers
  add column if not exists player_out_price numeric(6,2),
  add column if not exists player_in_price numeric(6,2),
  add column if not exists point_penalty integer not null default 0;

alter table fantasy_team_gameweek_points
  add column if not exists gross_points integer not null default 0,
  add column if not exists transfer_penalty integer not null default 0,
  add column if not exists overall_rank integer,
  add column if not exists finalized_at timestamptz,
  add constraint ftgwp_values_check check (transfer_penalty >= 0 and points = gross_points - transfer_penalty) not valid;

create table if not exists fantasy_league_join_authorizations (
  league_id uuid not null references fantasy_leagues(id) on delete cascade,
  user_id uuid not null references profiles(id) on delete cascade,
  authorized_at timestamptz not null default now(),
  primary key(league_id,user_id)
);
alter table fantasy_league_join_authorizations enable row level security;
create policy "league_authorizations_own_select" on fantasy_league_join_authorizations for select using(user_id=auth.uid());

drop policy if exists "leagues_select" on fantasy_leagues;
create policy "leagues_select_secure" on fantasy_leagues for select using (
  not is_private or created_by=auth.uid() or is_super_admin()
  or exists(select 1 from fantasy_teams ft where ft.league_id=fantasy_leagues.id and ft.user_id=auth.uid())
  or exists(select 1 from fantasy_league_join_authorizations a where a.league_id=fantasy_leagues.id and a.user_id=auth.uid())
  or (church_id is not null and has_church_role(church_id,array['church_admin','league_admin']::church_role[]))
);

create table if not exists fantasy_team_gameweek_players (
  id uuid primary key default uuid_generate_v4(),
  fantasy_team_id uuid not null references fantasy_teams(id) on delete cascade,
  gameweek_id uuid not null references gameweeks(id) on delete cascade,
  player_id uuid not null references players(id),
  position_at_lock player_position not null,
  player_price_at_lock numeric(6,2) not null,
  purchase_price numeric(6,2) not null,
  is_starting boolean not null,
  is_bench boolean not null,
  bench_order integer,
  is_captain boolean not null default false,
  is_vice_captain boolean not null default false,
  played_minutes integer not null default 0,
  base_points integer not null default 0,
  multiplier integer not null default 1,
  counted_points integer not null default 0,
  was_auto_subbed_in boolean not null default false,
  was_auto_subbed_out boolean not null default false,
  created_at timestamptz not null default now(),
  finalized_at timestamptz,
  unique(fantasy_team_id, gameweek_id, player_id),
  check (is_starting <> is_bench),
  check ((is_bench and bench_order between 1 and 4) or (is_starting and bench_order is null)),
  check (not (is_captain and is_vice_captain)),
  check (not is_bench or (not is_captain and not is_vice_captain)),
  check (played_minutes >= 0),
  check (multiplier between 0 and 2)
);

create index if not exists idx_ftgwp_team_week on fantasy_team_gameweek_players(fantasy_team_id, gameweek_id);
create index if not exists idx_ftgwp_week_player on fantasy_team_gameweek_players(gameweek_id, player_id);
create index if not exists idx_transfers_team_week on transfers(fantasy_team_id, gameweek_id, created_at);
create index if not exists idx_matches_week_status on matches(gameweek_id, status);
create index if not exists idx_players_filter on players(position, team_id, status, price);

alter table fantasy_team_gameweek_players enable row level security;
create policy "snapshots_select_members" on fantasy_team_gameweek_players for select using (
  owns_fantasy_team(fantasy_team_id) or is_super_admin() or exists (
    select 1 from fantasy_teams visible_team
    join fantasy_teams viewer_team on viewer_team.league_id = visible_team.league_id
    where visible_team.id = fantasy_team_gameweek_players.fantasy_team_id
      and viewer_team.user_id = auth.uid()
  )
);

-- All security-sensitive writes go through the RPCs below.
drop policy if exists "ftplayers_manage_own" on fantasy_team_players;
drop policy if exists "transfers_insert_own" on transfers;
drop policy if exists "church_members_insert_self_or_admin" on church_members;
drop policy if exists "fteams_insert_self" on fantasy_teams;
drop policy if exists "fteams_update_own_or_admin" on fantasy_teams;
drop policy if exists "fteams_delete_own_or_admin" on fantasy_teams;
create policy "fteams_admin_write" on fantasy_teams for all using (is_super_admin()) with check (is_super_admin());
create policy "church_members_insert_admin" on church_members for insert
  with check (is_super_admin() or is_church_admin(church_id));
revoke update on profiles from authenticated;
grant update(full_name,avatar_url,phone) on profiles to authenticated;
revoke update on notifications from authenticated;
revoke insert, update, delete on fantasy_team_players from authenticated;
revoke insert, update, delete on fantasy_team_gameweek_players from authenticated;
revoke insert, update, delete on transfers from authenticated;
revoke insert, update, delete on fantasy_team_gameweek_points from authenticated;

create or replace function assert_squad_valid(target_team_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_count int; v_cost numeric; v_bank numeric; v_starting int; v_captains int; v_vice int;
begin
  select count(*), coalesce(sum(p.price),0), count(*) filter(where not ftp.is_bench),
    count(*) filter(where ftp.is_captain), count(*) filter(where ftp.is_vice_captain)
  into v_count, v_cost, v_starting, v_captains, v_vice
  from fantasy_team_players ftp join players p on p.id=ftp.player_id where ftp.fantasy_team_id=target_team_id;
  if v_count <> 15 then raise exception 'Squad must contain exactly 15 players'; end if;
  if exists(select 1 from (select p.position,count(*) n from fantasy_team_players ftp join players p on p.id=ftp.player_id where ftp.fantasy_team_id=target_team_id group by p.position) q where (position='GK' and n<>2) or (position='DEF' and n<>5) or (position='MID' and n<>5) or (position='FWD' and n<>3))
    or (select count(distinct p.position) from fantasy_team_players ftp join players p on p.id=ftp.player_id where ftp.fantasy_team_id=target_team_id) <> 4
  then raise exception 'Squad composition must be 2 GK, 5 DEF, 5 MID, 3 FWD'; end if;
  if exists(select 1 from fantasy_team_players ftp join players p on p.id=ftp.player_id where ftp.fantasy_team_id=target_team_id group by p.team_id having count(*)>3) then raise exception 'Maximum 3 players from one real team'; end if;
  select bank into v_bank from fantasy_teams where id=target_team_id;
  if v_bank < 0 then raise exception 'Squad exceeds budget'; end if;
  if v_starting <> 11 then raise exception 'Starting XI must contain 11 players'; end if;
  if (select count(*) from fantasy_team_players where fantasy_team_id=target_team_id and is_bench) <> 4
    or (select count(*) from fantasy_team_players ftp join players p on p.id=ftp.player_id where ftp.fantasy_team_id=target_team_id and ftp.is_bench and p.position='GK') <> 1
  then raise exception 'Bench must contain 1 goalkeeper and 3 outfield players'; end if;
  if exists(select 1 from (select p.position,count(*) n from fantasy_team_players ftp join players p on p.id=ftp.player_id where ftp.fantasy_team_id=target_team_id and not ftp.is_bench group by p.position) q where (position='GK' and n<>1) or (position='DEF' and n not between 3 and 5) or (position='MID' and n not between 2 and 5) or (position='FWD' and n not between 1 and 3)) then raise exception 'Invalid starting formation'; end if;
  if v_captains<>1 or v_vice<>1 then raise exception 'Choose exactly one captain and one vice-captain'; end if;
  if (select count(*) from fantasy_team_players where fantasy_team_id=target_team_id and is_bench and bench_order is not null)<>4
    or (select count(distinct bench_order) from fantasy_team_players where fantasy_team_id=target_team_id and is_bench)<>4
  then raise exception 'Bench order must contain 1 through 4 exactly once'; end if;
end $$;

create or replace function join_church(target_church_id uuid)
returns void language plpgsql security definer set search_path=public as $$
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if not exists(select 1 from churches where id=target_church_id and status='active') then raise exception 'Church is not active'; end if;
  insert into church_members(church_id,user_id,role,status) values(target_church_id,auth.uid(),'member','active')
  on conflict(church_id,user_id) do update set status='active';
end $$;

create or replace function mark_notifications_read(p_notification_id uuid default null)
returns integer language plpgsql security definer set search_path=public as $$
declare v_count integer;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  update notifications set read=true where user_id=auth.uid() and not read and (p_notification_id is null or id=p_notification_id);
  get diagnostics v_count=row_count;
  return v_count;
end $$;

create or replace function create_fantasy_league(p_name text,p_church_id uuid,p_is_private boolean default true,p_max_members int default 100)
returns fantasy_leagues language plpgsql security definer set search_path=public as $$
declare v_season uuid; v_league fantasy_leagues;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if length(trim(p_name)) not between 3 and 60 then raise exception 'League name must be 3-60 characters'; end if;
  if p_church_id is not null and not is_church_member(p_church_id) then raise exception 'Join the church first'; end if;
  select id into v_season from seasons where is_current limit 1;
  if v_season is null then raise exception 'No current season'; end if;
  insert into fantasy_leagues(church_id,season_id,created_by,name,is_private,invite_code,max_members,status)
  values(p_church_id,v_season,auth.uid(),trim(p_name),p_is_private,
    case when p_is_private then 'FAG-'||upper(substr(encode(gen_random_bytes(5),'hex'),1,5)) end,
    greatest(2,least(p_max_members,1000)),'active') returning * into v_league;
  return v_league;
end $$;

create or replace function join_fantasy_league(p_invite_code text)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_league fantasy_leagues;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select * into v_league from fantasy_leagues where upper(invite_code)=upper(trim(p_invite_code)) and status='active' for update;
  if v_league.id is null then raise exception 'League not found or inactive'; end if;
  if v_league.church_id is not null and not is_church_member(v_league.church_id) then raise exception 'Church membership required'; end if;
  if (select count(*) from fantasy_teams where league_id=v_league.id)>=v_league.max_members then raise exception 'League is full'; end if;
  if exists(select 1 from fantasy_teams where league_id=v_league.id and user_id=auth.uid()) then raise exception 'Already participating'; end if;
  insert into fantasy_league_join_authorizations(league_id,user_id) values(v_league.id,auth.uid()) on conflict do nothing;
  return v_league.id;
end $$;

create or replace function create_fantasy_team_with_squad(p_league_id uuid,p_name text,p_players jsonb)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_team uuid; v_season uuid; v_deadline timestamptz; v_cost numeric; v_league fantasy_leagues;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if jsonb_typeof(p_players)<>'array' or jsonb_array_length(p_players)<>15 then raise exception 'Submit exactly 15 players'; end if;
  if length(trim(p_name)) not between 3 and 40 then raise exception 'Team name must be 3-40 characters'; end if;
  select * into v_league from fantasy_leagues where id=p_league_id and status='active'
    and (church_id is null or is_church_member(church_id))
    and (not is_private or created_by=auth.uid() or exists(select 1 from fantasy_league_join_authorizations a where a.league_id=p_league_id and a.user_id=auth.uid())) for update;
  v_season := v_league.season_id;
  if v_season is null then raise exception 'League unavailable'; end if;
  if (select count(*) from fantasy_teams where league_id=p_league_id)>=v_league.max_members then raise exception 'League is full'; end if;
  select transfer_deadline into v_deadline from gameweeks where season_id=v_season and status='upcoming' order by number limit 1;
  if v_deadline is not null and now()>=v_deadline then raise exception 'Gameweek deadline passed'; end if;
  if exists(select 1 from fantasy_teams where league_id=p_league_id and user_id=auth.uid()) then raise exception 'A team already exists in this league'; end if;
  if (select count(distinct (x->>'player_id')::uuid) from jsonb_array_elements(p_players)x)<>15 then raise exception 'Duplicate players are not allowed'; end if;
  if exists(select 1 from jsonb_array_elements(p_players)x left join players p on p.id=(x->>'player_id')::uuid where p.id is null) then raise exception 'Unknown player'; end if;
  select sum(p.price) into v_cost from jsonb_array_elements(p_players)x join players p on p.id=(x->>'player_id')::uuid;
  if v_cost>100 then raise exception 'Squad exceeds 100.0 budget'; end if;
  insert into fantasy_teams(league_id,user_id,name,budget,starting_budget,bank) values(p_league_id,auth.uid(),trim(p_name),100,100,100-v_cost) returning id into v_team;
  insert into fantasy_team_players(fantasy_team_id,player_id,purchase_price,is_bench,bench_order,is_captain,is_vice_captain)
  select v_team,(x->>'player_id')::uuid,p.price,coalesce((x->>'is_bench')::boolean,false),nullif(x->>'bench_order','')::int,
    coalesce((x->>'is_captain')::boolean,false),coalesce((x->>'is_vice_captain')::boolean,false)
  from jsonb_array_elements(p_players)x join players p on p.id=(x->>'player_id')::uuid;
  perform assert_squad_valid(v_team);
  return v_team;
end $$;

create or replace function save_lineup(p_team_id uuid,p_lineup jsonb)
returns void language plpgsql security definer set search_path=public as $$
declare v_season uuid; v_deadline timestamptz;
begin
  if not owns_fantasy_team(p_team_id) then raise exception 'Forbidden'; end if;
  select fl.season_id into v_season from fantasy_teams ft join fantasy_leagues fl on fl.id=ft.league_id where ft.id=p_team_id;
  select transfer_deadline into v_deadline from gameweeks where season_id=v_season and status='upcoming' order by number limit 1;
  if v_deadline is null or now()>=v_deadline then raise exception 'Lineup is locked'; end if;
  if jsonb_array_length(p_lineup)<>15 or (select count(distinct (x->>'player_id')::uuid) from jsonb_array_elements(p_lineup)x)<>15 then raise exception 'Complete lineup required'; end if;
  if exists(select 1 from jsonb_array_elements(p_lineup)x where not exists(select 1 from fantasy_team_players ftp where ftp.fantasy_team_id=p_team_id and ftp.player_id=(x->>'player_id')::uuid)) then raise exception 'Lineup contains a player outside this squad'; end if;
  update fantasy_team_players ftp set is_bench=(x->>'is_bench')::boolean, bench_order=nullif(x->>'bench_order','')::int,
    is_captain=coalesce((x->>'is_captain')::boolean,false), is_vice_captain=coalesce((x->>'is_vice_captain')::boolean,false)
  from jsonb_array_elements(p_lineup)x where ftp.fantasy_team_id=p_team_id and ftp.player_id=(x->>'player_id')::uuid;
  perform assert_squad_valid(p_team_id);
end $$;

create or replace function lock_gameweek(target_gameweek_id uuid,p_admin_override boolean default false)
returns integer language plpgsql security definer set search_path=public as $$
declare v_gw gameweeks; v_count int; v_first_lock boolean;
begin
  select * into v_gw from gameweeks where id=target_gameweek_id for update;
  if v_gw.id is null then raise exception 'Gameweek not found'; end if;
  if p_admin_override and not is_super_admin() and auth.role()<>'service_role' then raise exception 'Admin override forbidden'; end if;
  if now()<v_gw.transfer_deadline and not p_admin_override then raise exception 'Deadline has not passed'; end if;
  v_first_lock := v_gw.status='upcoming';
  insert into fantasy_team_gameweek_players(fantasy_team_id,gameweek_id,player_id,position_at_lock,player_price_at_lock,purchase_price,is_starting,is_bench,bench_order,is_captain,is_vice_captain)
  select ftp.fantasy_team_id,v_gw.id,ftp.player_id,p.position,p.price,ftp.purchase_price,not ftp.is_bench,ftp.is_bench,ftp.bench_order,ftp.is_captain,ftp.is_vice_captain
  from fantasy_team_players ftp join fantasy_teams ft on ft.id=ftp.fantasy_team_id join fantasy_leagues fl on fl.id=ft.league_id join players p on p.id=ftp.player_id
  where fl.season_id=v_gw.season_id and (select count(*) from fantasy_team_players z where z.fantasy_team_id=ft.id)=15
  on conflict(fantasy_team_id,gameweek_id,player_id) do nothing;
  get diagnostics v_count=row_count;
  update gameweeks set status=case when status='upcoming' then 'locked' else status end where id=v_gw.id;
  update fantasy_teams ft set has_locked_gameweek=true,free_transfers=least(2,case when ft.has_locked_gameweek then ft.free_transfers+1 else 1 end)
  where v_first_lock and exists(select 1 from fantasy_team_gameweek_players s where s.gameweek_id=v_gw.id and s.fantasy_team_id=ft.id);
  insert into audit_logs(actor_id,action,entity_type,entity_id,metadata) values(auth.uid(),'gameweek.lock','gameweek',v_gw.id,jsonb_build_object('snapshot_rows',v_count,'admin_override',p_admin_override));
  return v_count;
end $$;

create or replace function execute_transfer(p_team_id uuid,p_player_out uuid,p_player_in uuid,p_gameweek_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_out fantasy_team_players; v_in players; v_out_player players; v_ft fantasy_teams; v_gw gameweeks; v_penalty int; v_new_bank numeric;
begin
  if not owns_fantasy_team(p_team_id) then raise exception 'Forbidden'; end if;
  select * into v_gw from gameweeks where id=p_gameweek_id and status='upcoming' for update;
  if v_gw.id is null or now()>=v_gw.transfer_deadline then raise exception 'Transfer deadline passed'; end if;
  select * into v_ft from fantasy_teams where id=p_team_id for update;
  if not exists(select 1 from fantasy_leagues where id=v_ft.league_id and season_id=v_gw.season_id) then raise exception 'Wrong gameweek'; end if;
  select * into v_out from fantasy_team_players where fantasy_team_id=p_team_id and player_id=p_player_out;
  select * into v_out_player from players where id=p_player_out;
  select * into v_in from players where id=p_player_in;
  if v_out.id is null or v_in.id is null then raise exception 'Player not found'; end if;
  if v_out_player.position<>v_in.position then raise exception 'Replacement must have the same position'; end if;
  if exists(select 1 from fantasy_team_players where fantasy_team_id=p_team_id and player_id=p_player_in) then raise exception 'Incoming player already owned'; end if;
  v_new_bank:=v_ft.bank+v_out_player.price-v_in.price;
  if v_new_bank<0 then raise exception 'Insufficient bank'; end if;
  v_penalty:=case when v_ft.free_transfers>0 then 0 else 4 end;
  delete from fantasy_team_players where id=v_out.id;
  insert into fantasy_team_players(fantasy_team_id,player_id,purchase_price,is_captain,is_vice_captain,is_bench,bench_order)
  values(p_team_id,p_player_in,v_in.price,v_out.is_captain,v_out.is_vice_captain,v_out.is_bench,v_out.bench_order);
  update fantasy_teams set bank=v_new_bank,free_transfers=greatest(0,free_transfers-1) where id=p_team_id;
  perform assert_squad_valid(p_team_id);
  insert into transfers(fantasy_team_id,gameweek_id,player_out_id,player_in_id,cost,player_out_price,player_in_price,point_penalty)
  values(p_team_id,p_gameweek_id,p_player_out,p_player_in,v_in.price-v_out_player.price,v_out_player.price,v_in.price,v_penalty);
  return jsonb_build_object('bank',v_new_bank,'point_penalty',v_penalty,'free_transfers',(select free_transfers from fantasy_teams where id=p_team_id));
end $$;

create or replace function formation_is_valid(p_gk int,p_def int,p_mid int,p_fwd int)
returns boolean language sql immutable as $$ select p_gk=1 and p_def between 3 and 5 and p_mid between 2 and 5 and p_fwd between 1 and 3 and p_gk+p_def+p_mid+p_fwd=11 $$;

create or replace function finalize_gameweek(target_gameweek_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare v_gw gameweeks; v_team record; v_missing record; v_bench record; v_counts record; v_multiplier_player uuid; v_gross int; v_penalty int;
begin
  if not is_super_admin() and auth.role()<>'service_role' then raise exception 'Super admin only'; end if;
  select * into v_gw from gameweeks where id=target_gameweek_id for update;
  if v_gw.id is null then raise exception 'Gameweek not found'; end if;
  if v_gw.status not in ('locked','active','finished') then raise exception 'Gameweek must be locked first'; end if;
  if exists(select 1 from matches where gameweek_id=v_gw.id and status in ('scheduled','live')) then raise exception 'Unresolved matches remain'; end if;
  perform score_gameweek_player_stats(v_gw.id);
  update fantasy_team_gameweek_players s set
    played_minutes=coalesce(x.minutes,0), base_points=coalesce(x.points,0), multiplier=case when s.is_starting then 1 else 0 end,
    counted_points=case when s.is_starting then coalesce(x.points,0) else 0 end,was_auto_subbed_in=false,was_auto_subbed_out=false,finalized_at=null
  from (select p.id player_id,coalesce(sum(mps.minutes_played),0)::int minutes,coalesce(sum(mps.fantasy_points),0)::int points from players p left join match_player_stats mps on mps.player_id=p.id and mps.match_id in(select id from matches where gameweek_id=v_gw.id) group by p.id)x
  where s.gameweek_id=v_gw.id and s.player_id=x.player_id;
  for v_team in select distinct fantasy_team_id from fantasy_team_gameweek_players where gameweek_id=v_gw.id loop
    -- Goalkeeper substitution.
    select * into v_missing from fantasy_team_gameweek_players where fantasy_team_id=v_team.fantasy_team_id and gameweek_id=v_gw.id and is_starting and position_at_lock='GK' and played_minutes=0;
    if v_missing.id is not null then
      select * into v_bench from fantasy_team_gameweek_players where fantasy_team_id=v_team.fantasy_team_id and gameweek_id=v_gw.id and is_bench and position_at_lock='GK' and played_minutes>0;
      if v_bench.id is not null then
        update fantasy_team_gameweek_players set multiplier=0,counted_points=0,was_auto_subbed_out=true where id=v_missing.id;
        update fantasy_team_gameweek_players set multiplier=1,counted_points=base_points,was_auto_subbed_in=true where id=v_bench.id;
      end if;
    end if;
    -- Each absent outfield starter gets the first legal unused playing bench option.
    for v_missing in select * from fantasy_team_gameweek_players where fantasy_team_id=v_team.fantasy_team_id and gameweek_id=v_gw.id and is_starting and position_at_lock<>'GK' and played_minutes=0 order by player_id loop
      for v_bench in select * from fantasy_team_gameweek_players where fantasy_team_id=v_team.fantasy_team_id and gameweek_id=v_gw.id and is_bench and position_at_lock<>'GK' and played_minutes>0 and not was_auto_subbed_in order by bench_order loop
        select count(*) filter(where position_at_lock='GK') as gk,count(*) filter(where position_at_lock='DEF') as def,count(*) filter(where position_at_lock='MID') as mid,count(*) filter(where position_at_lock='FWD') as fwd into v_counts
        from fantasy_team_gameweek_players where fantasy_team_id=v_team.fantasy_team_id and gameweek_id=v_gw.id and ((is_starting and not was_auto_subbed_out and id<>v_missing.id) or was_auto_subbed_in or id=v_bench.id);
        if formation_is_valid(v_counts.gk,v_counts.def,v_counts.mid,v_counts.fwd) then
          update fantasy_team_gameweek_players set multiplier=0,counted_points=0,was_auto_subbed_out=true where id=v_missing.id;
          update fantasy_team_gameweek_players set multiplier=1,counted_points=base_points,was_auto_subbed_in=true where id=v_bench.id;
          exit;
        end if;
      end loop;
    end loop;
    select player_id into v_multiplier_player from fantasy_team_gameweek_players where fantasy_team_id=v_team.fantasy_team_id and gameweek_id=v_gw.id and is_captain and played_minutes>0;
    if v_multiplier_player is null then select player_id into v_multiplier_player from fantasy_team_gameweek_players where fantasy_team_id=v_team.fantasy_team_id and gameweek_id=v_gw.id and is_vice_captain and played_minutes>0; end if;
    if v_multiplier_player is not null then update fantasy_team_gameweek_players set multiplier=2,counted_points=base_points*2 where fantasy_team_id=v_team.fantasy_team_id and gameweek_id=v_gw.id and player_id=v_multiplier_player and (is_starting and not was_auto_subbed_out or was_auto_subbed_in); end if;
    select coalesce(sum(counted_points),0) into v_gross from fantasy_team_gameweek_players where fantasy_team_id=v_team.fantasy_team_id and gameweek_id=v_gw.id;
    select coalesce(sum(point_penalty),0) into v_penalty from transfers where fantasy_team_id=v_team.fantasy_team_id and gameweek_id=v_gw.id;
    insert into fantasy_team_gameweek_points(fantasy_team_id,gameweek_id,gross_points,transfer_penalty,points,finalized_at)
    values(v_team.fantasy_team_id,v_gw.id,v_gross,v_penalty,v_gross-v_penalty,now()) on conflict(fantasy_team_id,gameweek_id) do update set gross_points=excluded.gross_points,transfer_penalty=excluded.transfer_penalty,points=excluded.points,finalized_at=excluded.finalized_at;
    update fantasy_team_gameweek_players set finalized_at=now() where fantasy_team_id=v_team.fantasy_team_id and gameweek_id=v_gw.id;
  end loop;
  with r as (select id,dense_rank()over(partition by gameweek_id order by points desc)::int gw_rank from fantasy_team_gameweek_points where gameweek_id=v_gw.id) update fantasy_team_gameweek_points p set rank=r.gw_rank from r where p.id=r.id;
  with r as (select ft.id,dense_rank()over(partition by ft.league_id order by ft.total_points desc)::int overall_rank from fantasy_teams ft join fantasy_leagues fl on fl.id=ft.league_id where fl.season_id=v_gw.season_id) update fantasy_teams ft set overall_rank=r.overall_rank from r where ft.id=r.id;
  update fantasy_team_gameweek_points p set overall_rank=ft.overall_rank from fantasy_teams ft where p.fantasy_team_id=ft.id and p.gameweek_id=v_gw.id;
  insert into notifications(user_id,title,message,type) select ft.user_id,'Gameweek finalized',coalesce(v_gw.name,'Gameweek '||v_gw.number)||' points are final.','results' from fantasy_teams ft where exists(select 1 from fantasy_team_gameweek_points p where p.fantasy_team_id=ft.id and p.gameweek_id=v_gw.id) and not exists(select 1 from notifications n where n.user_id=ft.user_id and n.type='results' and n.message=coalesce(v_gw.name,'Gameweek '||v_gw.number)||' points are final.');
  update gameweeks set status='finished' where id=v_gw.id;
  insert into audit_logs(actor_id,action,entity_type,entity_id) values(auth.uid(),'gameweek.finalize','gameweek',v_gw.id);
end $$;

revoke execute on function score_gameweek_player_stats(uuid),roll_up_team_gameweek_points(uuid),recompute_league_ranks(uuid) from public,anon,authenticated;
revoke execute on function join_church(uuid),mark_notifications_read(uuid),create_fantasy_league(text,uuid,boolean,int),join_fantasy_league(text),create_fantasy_team_with_squad(uuid,text,jsonb),save_lineup(uuid,jsonb),execute_transfer(uuid,uuid,uuid,uuid) from public,anon;
grant execute on function join_church(uuid),mark_notifications_read(uuid),create_fantasy_league(text,uuid,boolean,int),join_fantasy_league(text),create_fantasy_team_with_squad(uuid,text,jsonb),save_lineup(uuid,jsonb),execute_transfer(uuid,uuid,uuid,uuid) to authenticated;
revoke execute on function lock_gameweek(uuid,boolean),finalize_gameweek(uuid),assert_squad_valid(uuid) from public,anon,authenticated;
grant execute on function lock_gameweek(uuid,boolean),finalize_gameweek(uuid) to service_role;

commit;

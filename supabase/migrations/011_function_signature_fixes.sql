-- Fix two function-resolution issues found by `supabase db lint` after 001-010.
-- Forward-only and data-preserving.
begin;

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
     and not exists(
       select 1 from public.fantasy_league_join_authorizations
       where league_id=p_league_id and user_id=auth.uid()
     ) then
    raise exception 'Private league invitation required' using errcode='42501';
  end if;
  if exists(select 1 from public.fantasy_teams where league_id=p_league_id and user_id=auth.uid()) then
    raise exception 'A team already exists in this league';
  end if;
  if (select count(*) from public.fantasy_teams where league_id=p_league_id) >= league_row.max_members then
    raise exception 'League is full';
  end if;

  select rr.rules into rule
  from public.resolve_fantasy_rules(league_row.season_id,league_row.church_id) rr;
  if rule is null then raise exception 'No active Fantasy rules for league'; end if;
  expected_size := (rule->>'squad_size')::integer;
  if jsonb_array_length(p_players) <> expected_size then raise exception 'Incorrect squad size'; end if;
  if (
    select count(distinct (x->>'player_id')::uuid) from jsonb_array_elements(p_players) x
  ) <> expected_size then
    raise exception 'Duplicate players are not allowed';
  end if;
  if exists(
    select 1 from jsonb_array_elements(p_players) x
    left join public.players p on p.id=(x->>'player_id')::uuid
    where p.id is null
  ) then raise exception 'Unknown player'; end if;
  select sum(p.price) into squad_cost
  from jsonb_array_elements(p_players) x
  join public.players p on p.id=(x->>'player_id')::uuid;
  if squad_cost > (rule->>'starting_budget')::numeric then raise exception 'Squad exceeds budget'; end if;
  select transfer_deadline into deadline from public.gameweeks
  where season_id=league_row.season_id and status='upcoming' order by number limit 1;
  if deadline is not null and now() >= deadline then raise exception 'Gameweek deadline passed'; end if;

  insert into public.fantasy_teams(league_id,user_id,name,budget,starting_budget,bank,free_transfers)
  values(
    p_league_id,auth.uid(),btrim(p_name),(rule->>'starting_budget')::numeric,
    (rule->>'starting_budget')::numeric,(rule->>'starting_budget')::numeric-squad_cost,0
  ) returning id into created_team_id;

  insert into public.fantasy_team_players(
    fantasy_team_id,player_id,purchase_price,is_bench,bench_order,is_captain,is_vice_captain
  )
  select created_team_id,(x->>'player_id')::uuid,p.price,
         coalesce((x->>'is_bench')::boolean,false),nullif(x->>'bench_order','')::integer,
         coalesce((x->>'is_captain')::boolean,false),
         coalesce((x->>'is_vice_captain')::boolean,false)
  from jsonb_array_elements(p_players) x
  join public.players p on p.id=(x->>'player_id')::uuid;

  perform public.assert_squad_valid(created_team_id);
  return created_team_id;
end;
$$;

-- count(*) returns bigint. This private overload safely delegates to the
-- canonical integer implementation used by finalized gameweek scoring.
create or replace function public.formation_is_valid_for_rules(
  p_gk bigint,p_def bigint,p_mid bigint,p_fwd bigint,p_rules jsonb
)
returns boolean
language sql
immutable
strict
set search_path = ''
as $$
  select public.formation_is_valid_for_rules(
    p_gk::integer,p_def::integer,p_mid::integer,p_fwd::integer,p_rules
  );
$$;

revoke all on function public.create_fantasy_team_with_squad(uuid,text,jsonb) from public,anon;
grant execute on function public.create_fantasy_team_with_squad(uuid,text,jsonb) to authenticated;
revoke all on function public.formation_is_valid_for_rules(bigint,bigint,bigint,bigint,jsonb)
  from public,anon,authenticated;
grant execute on function public.formation_is_valid_for_rules(bigint,bigint,bigint,bigint,jsonb)
  to service_role;

commit;

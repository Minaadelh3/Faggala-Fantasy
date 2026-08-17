-- Deterministic scoring from immutable per-gameweek rule and lineup snapshots.

begin;

create or replace function public.calculate_match_fantasy_points(
  p_position public.player_position,
  p_minutes integer,
  p_goals integer,
  p_assists integer,
  p_clean_sheet boolean,
  p_yellow_cards integer,
  p_red_cards integer,
  p_own_goals integer,
  p_penalties_missed integer,
  p_penalties_saved integer,
  p_saves integer,
  p_bonus integer,
  p_rules jsonb
)
returns integer
language sql
immutable
strict
set search_path = ''
as $$
  select
    case when p_minutes >= 60 then (p_rules->>'minutes_60_plus')::integer
         when p_minutes > 0 then (p_rules->>'minutes_under_60')::integer else 0 end
    + p_goals * case p_position
        when 'GK' then (p_rules->>'goal_gk_def')::integer
        when 'DEF' then (p_rules->>'goal_gk_def')::integer
        when 'MID' then (p_rules->>'goal_mid')::integer
        else (p_rules->>'goal_fwd')::integer end
    + p_assists * (p_rules->>'assist')::integer
    + case when p_clean_sheet and p_position in ('GK','DEF') then (p_rules->>'clean_sheet_gk_def')::integer
           when p_clean_sheet and p_position='MID' then (p_rules->>'clean_sheet_mid')::integer else 0 end
    + p_yellow_cards * (p_rules->>'yellow_card')::integer
    + p_red_cards * (p_rules->>'red_card')::integer
    + p_own_goals * (p_rules->>'own_goal')::integer
    + p_penalties_missed * (p_rules->>'penalty_miss')::integer
    + p_penalties_saved * (p_rules->>'penalty_save')::integer
    + floor(p_saves / 3.0)::integer * (p_rules->>'save_every_3')::integer
    + p_bonus;
$$;

create or replace function public.score_gameweek_player_stats(target_gameweek_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare v_season_id uuid; rule jsonb;
begin
  select gw.season_id into v_season_id from public.gameweeks gw where gw.id=target_gameweek_id;
  select rr.rules into rule from public.resolve_fantasy_rules(v_season_id,null) rr;
  if rule is null then raise exception 'No active platform Fantasy rules for season %',v_season_id; end if;
  update public.match_player_stats mps set fantasy_points=public.calculate_match_fantasy_points(
    p.position,mps.minutes_played,mps.goals,mps.assists,mps.clean_sheet,mps.yellow_cards,
    mps.red_cards,mps.own_goals,mps.penalties_missed,mps.penalties_saved,mps.saves,mps.bonus,rule
  )
  from public.players p,public.matches m
  where mps.player_id=p.id and mps.match_id=m.id and m.gameweek_id=target_gameweek_id;
end;
$$;

create or replace function public.formation_is_valid_for_rules(
  p_gk integer,p_def integer,p_mid integer,p_fwd integer,p_rules jsonb
)
returns boolean
language sql
immutable
strict
set search_path = ''
as $$
  select p_gk between (p_rules->'lineup_min'->>'GK')::integer and (p_rules->'lineup_max'->>'GK')::integer
     and p_def between (p_rules->'lineup_min'->>'DEF')::integer and (p_rules->'lineup_max'->>'DEF')::integer
     and p_mid between (p_rules->'lineup_min'->>'MID')::integer and (p_rules->'lineup_max'->>'MID')::integer
     and p_fwd between (p_rules->'lineup_min'->>'FWD')::integer and (p_rules->'lineup_max'->>'FWD')::integer
     and p_gk+p_def+p_mid+p_fwd=(p_rules->>'lineup_size')::integer;
$$;

create or replace function public.finalize_gameweek(target_gameweek_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  week_row public.gameweeks;
  team record;
  missing record;
  bench_player record;
  counts record;
  multiplier_player uuid;
  gross integer;
  penalty integer;
  captain_multiplier integer;
begin
  if not public.is_super_admin() and auth.role()<>'service_role' then
    raise exception 'Super admin only' using errcode='42501';
  end if;
  select * into week_row from public.gameweeks where id=target_gameweek_id for update;
  if week_row.id is null then raise exception 'Gameweek not found'; end if;
  if week_row.status not in ('locked','active','finished') then raise exception 'Gameweek must be locked first'; end if;
  if exists(select 1 from public.matches where gameweek_id=week_row.id and status in ('scheduled','live')) then
    raise exception 'Unresolved matches remain';
  end if;
  if exists(select 1 from public.fantasy_team_gameweek_players where gameweek_id=week_row.id and rules_snapshot is null) then
    raise exception 'A historical lineup is missing its rule snapshot';
  end if;

  -- Maintain the canonical platform score for public player statistics. Tenant
  -- teams below are independently scored with their own frozen rules.
  perform public.score_gameweek_player_stats(week_row.id);

  update public.fantasy_team_gameweek_players s set
    played_minutes=x.minutes,
    base_points=x.points,
    multiplier=case when s.is_starting then 1 else 0 end,
    counted_points=case when s.is_starting then x.points else 0 end,
    was_auto_subbed_in=false,
    was_auto_subbed_out=false,
    finalized_at=null
  from (
    select s2.id,
      coalesce(sum(coalesce(mps.minutes_played,0)),0)::integer minutes,
      coalesce(sum(public.calculate_match_fantasy_points(
        s2.position_at_lock,
        coalesce(mps.minutes_played,0),coalesce(mps.goals,0),coalesce(mps.assists,0),
        coalesce(mps.clean_sheet,false),coalesce(mps.yellow_cards,0),coalesce(mps.red_cards,0),
        coalesce(mps.own_goals,0),coalesce(mps.penalties_missed,0),coalesce(mps.penalties_saved,0),
        coalesce(mps.saves,0),coalesce(mps.bonus,0),s2.rules_snapshot
      )),0)::integer points
    from public.fantasy_team_gameweek_players s2
    left join public.matches m on m.gameweek_id=s2.gameweek_id
    left join public.match_player_stats mps on mps.match_id=m.id and mps.player_id=s2.player_id
    where s2.gameweek_id=week_row.id
    group by s2.id
  ) x
  where s.id=x.id;

  for team in
    select fantasy_team_id,(array_agg(rules_snapshot order by id))[1] rules
    from public.fantasy_team_gameweek_players where gameweek_id=week_row.id
    group by fantasy_team_id order by fantasy_team_id
  loop
    -- Goalkeeper substitution is position-for-position.
    select * into missing from public.fantasy_team_gameweek_players
    where fantasy_team_id=team.fantasy_team_id and gameweek_id=week_row.id
      and is_starting and position_at_lock='GK' and played_minutes=0 limit 1;
    if missing.id is not null then
      select * into bench_player from public.fantasy_team_gameweek_players
      where fantasy_team_id=team.fantasy_team_id and gameweek_id=week_row.id
        and is_bench and position_at_lock='GK' and played_minutes>0
      order by bench_order limit 1;
      if bench_player.id is not null then
        update public.fantasy_team_gameweek_players
        set multiplier=0,counted_points=0,was_auto_subbed_out=true where id=missing.id;
        update public.fantasy_team_gameweek_players
        set multiplier=1,counted_points=base_points,was_auto_subbed_in=true where id=bench_player.id;
      end if;
    end if;

    -- Outfield bench priority is deterministic and every substitution must
    -- preserve a formation allowed by the frozen rule version.
    for missing in
      select * from public.fantasy_team_gameweek_players
      where fantasy_team_id=team.fantasy_team_id and gameweek_id=week_row.id
        and is_starting and position_at_lock<>'GK' and played_minutes=0
      order by id
    loop
      for bench_player in
        select * from public.fantasy_team_gameweek_players
        where fantasy_team_id=team.fantasy_team_id and gameweek_id=week_row.id
          and is_bench and position_at_lock<>'GK' and played_minutes>0 and not was_auto_subbed_in
        order by bench_order
      loop
        select count(*) filter(where position_at_lock='GK') gk,
               count(*) filter(where position_at_lock='DEF') def,
               count(*) filter(where position_at_lock='MID') mid,
               count(*) filter(where position_at_lock='FWD') fwd
        into counts
        from public.fantasy_team_gameweek_players
        where fantasy_team_id=team.fantasy_team_id and gameweek_id=week_row.id
          and ((is_starting and not was_auto_subbed_out and id<>missing.id)
               or was_auto_subbed_in or id=bench_player.id);
        if public.formation_is_valid_for_rules(
          counts.gk::integer,counts.def::integer,counts.mid::integer,counts.fwd::integer,team.rules
        ) then
          update public.fantasy_team_gameweek_players
          set multiplier=0,counted_points=0,was_auto_subbed_out=true where id=missing.id;
          update public.fantasy_team_gameweek_players
          set multiplier=1,counted_points=base_points,was_auto_subbed_in=true where id=bench_player.id;
          exit;
        end if;
      end loop;
    end loop;

    select player_id into multiplier_player from public.fantasy_team_gameweek_players
    where fantasy_team_id=team.fantasy_team_id and gameweek_id=week_row.id
      and is_captain and played_minutes>0 and (is_starting and not was_auto_subbed_out or was_auto_subbed_in);
    if multiplier_player is null and coalesce((team.rules->>'vice_captain_fallback')::boolean,true) then
      select player_id into multiplier_player from public.fantasy_team_gameweek_players
      where fantasy_team_id=team.fantasy_team_id and gameweek_id=week_row.id
        and is_vice_captain and played_minutes>0 and (is_starting and not was_auto_subbed_out or was_auto_subbed_in);
    end if;
    captain_multiplier := (team.rules->>'captain_multiplier')::integer;
    if multiplier_player is not null then
      update public.fantasy_team_gameweek_players
      set multiplier=captain_multiplier,counted_points=base_points*captain_multiplier
      where fantasy_team_id=team.fantasy_team_id and gameweek_id=week_row.id and player_id=multiplier_player;
    end if;

    select coalesce(sum(counted_points),0) into gross
    from public.fantasy_team_gameweek_players
    where fantasy_team_id=team.fantasy_team_id and gameweek_id=week_row.id;
    select coalesce(sum(point_penalty),0) into penalty from public.transfers
    where fantasy_team_id=team.fantasy_team_id and gameweek_id=week_row.id;
    insert into public.fantasy_team_gameweek_points(
      fantasy_team_id,gameweek_id,gross_points,transfer_penalty,points,finalized_at
    ) values(team.fantasy_team_id,week_row.id,gross,penalty,gross-penalty,now())
    on conflict(fantasy_team_id,gameweek_id) do update set
      gross_points=excluded.gross_points,transfer_penalty=excluded.transfer_penalty,
      points=excluded.points,finalized_at=excluded.finalized_at;
    update public.fantasy_team_gameweek_players set finalized_at=now()
    where fantasy_team_id=team.fantasy_team_id and gameweek_id=week_row.id;
  end loop;

  with ranked as (
    select id,dense_rank() over(partition by gameweek_id order by points desc)::integer gw_rank
    from public.fantasy_team_gameweek_points where gameweek_id=week_row.id
  ) update public.fantasy_team_gameweek_points p set rank=ranked.gw_rank
    from ranked where p.id=ranked.id;
  with ranked as (
    select ft.id,dense_rank() over(partition by ft.league_id order by ft.total_points desc)::integer overall_rank
    from public.fantasy_teams ft join public.fantasy_leagues fl on fl.id=ft.league_id
    where fl.season_id=week_row.season_id
  ) update public.fantasy_teams ft set overall_rank=ranked.overall_rank
    from ranked where ft.id=ranked.id;
  update public.fantasy_team_gameweek_points p set overall_rank=ft.overall_rank
  from public.fantasy_teams ft where p.fantasy_team_id=ft.id and p.gameweek_id=week_row.id;
  insert into public.notifications(user_id,title,message,type)
  select ft.user_id,'Gameweek finalized',coalesce(week_row.name,'Gameweek '||week_row.number)||' points are final.','results'
  from public.fantasy_teams ft
  where exists(select 1 from public.fantasy_team_gameweek_points p where p.fantasy_team_id=ft.id and p.gameweek_id=week_row.id)
    and not exists(select 1 from public.notifications n where n.user_id=ft.user_id and n.type='results'
      and n.message=coalesce(week_row.name,'Gameweek '||week_row.number)||' points are final.');
  update public.gameweeks set status='finished' where id=week_row.id;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id)
  values(auth.uid(),'gameweek.finalize','gameweek',week_row.id);
end;
$$;

revoke all on function public.calculate_match_fantasy_points(
  public.player_position,integer,integer,integer,boolean,integer,integer,integer,
  integer,integer,integer,integer,jsonb
) from public,anon,authenticated;
revoke all on function public.formation_is_valid_for_rules(integer,integer,integer,integer,jsonb)
  from public,anon,authenticated;
revoke all on function public.score_gameweek_player_stats(uuid) from public,anon,authenticated;
revoke all on function public.finalize_gameweek(uuid) from public,anon,authenticated;
revoke all on function public.roll_up_team_gameweek_points(uuid) from public,anon,authenticated,service_role;
revoke all on function public.recompute_league_ranks(uuid) from public,anon,authenticated,service_role;
revoke all on function public.formation_is_valid(integer,integer,integer,integer) from public,anon,authenticated;
grant execute on function public.calculate_match_fantasy_points(
  public.player_position,integer,integer,integer,boolean,integer,integer,integer,
  integer,integer,integer,integer,jsonb
) to service_role;
grant execute on function public.formation_is_valid_for_rules(integer,integer,integer,integer,jsonb) to service_role;
grant execute on function public.score_gameweek_player_stats(uuid) to service_role;
grant execute on function public.finalize_gameweek(uuid) to service_role;

commit;

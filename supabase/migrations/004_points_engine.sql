-- ============================================================
-- FANTASY CHURCH PLATFORM — FANTASY POINTS ENGINE
-- Migration: 004_points_engine.sql
-- Depends on: 001_schema.sql, 002_rls_policies.sql, 003_triggers.sql
-- ============================================================

-- ------------------------------------------------------------
-- STEP 1: Score every match_player_stats row for a gameweek
--
-- Uses the platform default rule set for the match's season
-- (fantasy_rules where church_id is null). match_player_stats.
-- fantasy_points is a single shared value per player per match —
-- church-level rule overrides are reserved for a future per-church
-- scoring layer and are not applied here.
-- ------------------------------------------------------------
create or replace function score_gameweek_player_stats(target_gameweek_id uuid)
returns void
language plpgsql
security definer
as $$
declare
  v_season_id uuid;
  v_rules jsonb;
begin
  select season_id into v_season_id from gameweeks where id = target_gameweek_id;

  select rules into v_rules
  from fantasy_rules
  where season_id = v_season_id and church_id is null
  limit 1;

  if v_rules is null then
    raise exception 'No default fantasy_rules found for season %', v_season_id;
  end if;

  update match_player_stats mps
  set fantasy_points = (
    -- minutes played
    case
      when mps.minutes_played >= 60 then (v_rules ->> 'minutes_60_plus')::int
      when mps.minutes_played > 0 then (v_rules ->> 'minutes_under_60')::int
      else 0
    end
    -- goals, position-weighted
    + mps.goals * (
        case p.position
          when 'GK' then (v_rules ->> 'goal_gk_def')::int
          when 'DEF' then (v_rules ->> 'goal_gk_def')::int
          when 'MID' then (v_rules ->> 'goal_mid')::int
          else (v_rules ->> 'goal_fwd')::int
        end
      )
    + mps.assists * (v_rules ->> 'assist')::int
    -- clean sheet, position-weighted (forwards get none)
    + case
        when mps.clean_sheet and p.position in ('GK', 'DEF') then (v_rules ->> 'clean_sheet_gk_def')::int
        when mps.clean_sheet and p.position = 'MID' then (v_rules ->> 'clean_sheet_mid')::int
        else 0
      end
    + mps.yellow_cards * (v_rules ->> 'yellow_card')::int
    + mps.red_cards * (v_rules ->> 'red_card')::int
    + mps.own_goals * (v_rules ->> 'own_goal')::int
    + mps.penalties_missed * (v_rules ->> 'penalty_miss')::int
    + mps.penalties_saved * (v_rules ->> 'penalty_save')::int
    + floor(mps.saves / 3) * (v_rules ->> 'save_every_3')::int
    + mps.bonus
  )
  from players p, matches m
  where mps.player_id = p.id
    and mps.match_id = m.id
    and m.gameweek_id = target_gameweek_id;
end;
$$;

-- ------------------------------------------------------------
-- STEP 2: Roll player scores up into each fantasy_team's
-- gameweek total (starting XI only, captain counts double)
-- and upsert into fantasy_team_gameweek_points.
--
-- The existing trg_recompute_total_points trigger (003) keeps
-- fantasy_teams.total_points in sync automatically on upsert.
-- ------------------------------------------------------------
create or replace function roll_up_team_gameweek_points(target_gameweek_id uuid)
returns void
language plpgsql
security definer
as $$
declare
  v_season_id uuid;
begin
  select season_id into v_season_id from gameweeks where id = target_gameweek_id;

  insert into fantasy_team_gameweek_points (fantasy_team_id, gameweek_id, points)
  select
    ftp.fantasy_team_id,
    target_gameweek_id,
    coalesce(sum(mps.fantasy_points * case when ftp.is_captain then 2 else 1 end), 0)
  from fantasy_team_players ftp
  join fantasy_teams ft on ft.id = ftp.fantasy_team_id
  join fantasy_leagues fl on fl.id = ft.league_id
  left join match_player_stats mps
    on mps.player_id = ftp.player_id
   and mps.match_id in (select id from matches where gameweek_id = target_gameweek_id)
  where ftp.is_bench = false
    and fl.season_id = v_season_id
  group by ftp.fantasy_team_id
  on conflict (fantasy_team_id, gameweek_id)
  do update set points = excluded.points;
end;
$$;

-- ------------------------------------------------------------
-- STEP 3: Recompute overall_rank within each league, ordered by
-- total_points descending (ties keep insertion order stable via id).
-- ------------------------------------------------------------
create or replace function recompute_league_ranks(target_season_id uuid)
returns void
language plpgsql
security definer
as $$
begin
  with ranked as (
    select
      ft.id,
      row_number() over (partition by ft.league_id order by ft.total_points desc, ft.id) as rnk
    from fantasy_teams ft
    join fantasy_leagues fl on fl.id = ft.league_id
    where fl.season_id = target_season_id
  )
  update fantasy_teams ft
  set overall_rank = ranked.rnk
  from ranked
  where ranked.id = ft.id;
end;
$$;

-- ------------------------------------------------------------
-- ORCHESTRATOR: run the full pipeline for a gameweek and mark
-- it finished. This is the single entry point the admin UI /
-- edge function should call once all match results are in.
-- ------------------------------------------------------------
create or replace function finalize_gameweek(target_gameweek_id uuid)
returns void
language plpgsql
security definer
as $$
declare
  v_season_id uuid;
begin
  select season_id into v_season_id from gameweeks where id = target_gameweek_id;

  if v_season_id is null then
    raise exception 'Gameweek % not found', target_gameweek_id;
  end if;

  perform score_gameweek_player_stats(target_gameweek_id);
  perform roll_up_team_gameweek_points(target_gameweek_id);
  perform recompute_league_ranks(v_season_id);

  update gameweeks set status = 'finished' where id = target_gameweek_id;
end;
$$;

-- Only super_admin (or a service-role edge function) should trigger scoring.
revoke execute on function finalize_gameweek(uuid) from public;
grant execute on function finalize_gameweek(uuid) to service_role;

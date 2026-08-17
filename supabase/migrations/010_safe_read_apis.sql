-- Safe application read models and narrow notification operations.

begin;

create or replace function public.is_fantasy_league_participant(target_league_id uuid)
returns boolean
language sql
security definer
stable
set search_path = ''
as $$
  select exists(
    select 1 from public.fantasy_teams
    where league_id=target_league_id and user_id=auth.uid()
  );
$$;
revoke all on function public.is_fantasy_league_participant(uuid) from public;
grant execute on function public.is_fantasy_league_participant(uuid) to authenticated,service_role;

drop policy if exists "fteams_select" on public.fantasy_teams;
create policy "fteams_select_own_or_super_admin" on public.fantasy_teams for select
using(user_id=auth.uid() or public.is_super_admin());

drop policy if exists "ftplayers_select" on public.fantasy_team_players;
create policy "ftplayers_select_owner_or_super_admin" on public.fantasy_team_players for select
using(public.owns_fantasy_team(fantasy_team_id) or public.is_super_admin());

drop policy if exists "leagues_select_secure" on public.fantasy_leagues;
create policy "leagues_select_secure" on public.fantasy_leagues for select using(
  not is_private or created_by=auth.uid() or public.is_super_admin()
  or public.is_fantasy_league_participant(id)
  or exists(select 1 from public.fantasy_league_join_authorizations a where a.league_id=id and a.user_id=auth.uid())
  or (church_id is not null and public.has_church_role(
    church_id,array['church_admin','league_admin']::public.church_role[]
  ))
);

drop policy if exists "snapshots_select_members" on public.fantasy_team_gameweek_players;
create policy "snapshots_select_after_lock" on public.fantasy_team_gameweek_players for select using(
  public.owns_fantasy_team(fantasy_team_id) or public.is_super_admin() or exists(
    select 1
    from public.fantasy_teams target_team
    join public.gameweeks gw on gw.id=fantasy_team_gameweek_players.gameweek_id
    where target_team.id=fantasy_team_gameweek_players.fantasy_team_id
      and gw.status in ('locked','active','finished')
      and public.is_fantasy_league_participant(target_team.league_id)
  )
);

drop policy if exists "ftgw_points_select" on public.fantasy_team_gameweek_points;
create policy "ftgw_points_select_participants" on public.fantasy_team_gameweek_points for select using(
  public.owns_fantasy_team(fantasy_team_id) or public.is_super_admin() or exists(
    select 1 from public.fantasy_teams target_team
    where target_team.id=fantasy_team_gameweek_points.fantasy_team_id
      and public.is_fantasy_league_participant(target_team.league_id)
  )
);

-- SECURITY DEFINER view exposes only standings fields, never profile phone,
-- email, bank, invite secrets, or mutable lineup state.
drop view if exists public.fantasy_leaderboard;
create view public.fantasy_leaderboard
with (security_barrier=true,security_invoker=false)
as
select ft.id,ft.league_id,ft.name,ft.total_points,ft.overall_rank,
       p.full_name manager_name,l.name league_name,l.season_id
from public.fantasy_teams ft
join public.profiles p on p.id=ft.user_id
join public.fantasy_leagues l on l.id=ft.league_id
where public.is_super_admin() or public.is_fantasy_league_participant(ft.league_id);
revoke all on public.fantasy_leaderboard from public,anon;
grant select on public.fantasy_leaderboard to authenticated,service_role;

create or replace function public.get_fantasy_team_rules(p_team_id uuid)
returns jsonb
language plpgsql
security definer
stable
set search_path = ''
as $$
declare result jsonb;
begin
  if not public.owns_fantasy_team(p_team_id) and not public.is_super_admin() then
    raise exception 'Forbidden' using errcode='42501';
  end if;
  select rr.rules into result
  from public.fantasy_teams ft join public.fantasy_leagues fl on fl.id=ft.league_id
  join lateral public.resolve_fantasy_rules(fl.season_id,fl.church_id) rr on true
  where ft.id=p_team_id;
  if result is null then raise exception 'No active Fantasy rules for team'; end if;
  return result;
end;
$$;
revoke all on function public.get_fantasy_team_rules(uuid) from public,anon;
grant execute on function public.get_fantasy_team_rules(uuid) to authenticated;

create or replace function public.mark_notifications_read(p_notification_id uuid default null)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare changed integer;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  update public.notifications set read=true
  where user_id=auth.uid() and not read and (p_notification_id is null or id=p_notification_id);
  get diagnostics changed=row_count;
  return changed;
end;
$$;
revoke all on function public.mark_notifications_read(uuid) from public,anon;
grant execute on function public.mark_notifications_read(uuid) to authenticated;

commit;

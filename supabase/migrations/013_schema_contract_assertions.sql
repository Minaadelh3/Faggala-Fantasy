-- Deployment-time contract checks. This migration is read-only apart from its
-- migration-history entry and fails atomically if the deployed schema drifts.
do $$
declare
  relation_name text;
  trigger_name text;
  routine_signature text;
  policy_name text;
begin
  foreach relation_name in array array[
    'profiles','churches','church_settings','church_members','seasons','gameweeks',
    'teams','players','matches','match_player_stats','fantasy_rules','fantasy_leagues',
    'fantasy_teams','fantasy_team_players','transfers','fantasy_team_gameweek_points',
    'advertisements','subscriptions','payments','invoices','church_wallet',
    'church_wallet_transactions','notifications','announcements','audit_logs',
    'fantasy_league_join_authorizations','fantasy_team_gameweek_players',
    'fantasy_league_secrets','player_price_history','payment_events'
  ] loop
    if to_regclass('public.'||relation_name) is null then
      raise exception 'Missing required relation public.%', relation_name;
    end if;
    if not exists(
      select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
      where n.nspname='public' and c.relname=relation_name and c.relrowsecurity
    ) then
      raise exception 'RLS is not enabled on public.%', relation_name;
    end if;
  end loop;

  if to_regclass('public.fantasy_leaderboard') is null then
    raise exception 'Missing required view public.fantasy_leaderboard';
  end if;

  foreach trigger_name in array array[
    'trg_profiles_updated_at','trg_churches_updated_at','trg_matches_updated_at',
    'trg_leagues_updated_at','trg_fteams_updated_at','trg_ads_updated_at',
    'trg_subscriptions_updated_at','trg_on_auth_user_created','trg_on_church_created',
    'trg_recompute_total_points','trg_protect_profile_privileged_columns',
    'trg_validate_match_gameweek_season','trg_protect_finalized_snapshot',
    'trg_protect_finalized_points','trg_protect_advertisement_workflow',
    'trg_protect_notification_columns','trg_protect_audit_log_history',
    'trg_fantasy_rules_updated_at','trg_protect_locked_fantasy_rules',
    'trg_capture_player_price_change','trg_validate_payment_subscription_scope',
    'trg_validate_invoice_payment_scope','trg_apply_wallet_transaction',
    'trg_protect_wallet_ledger'
  ] loop
    if not exists(select 1 from pg_trigger where tgname=trigger_name and not tgisinternal) then
      raise exception 'Missing required trigger %', trigger_name;
    end if;
  end loop;

  foreach routine_signature in array array[
    'public.join_church(uuid)',
    'public.manage_church_member(uuid,uuid,public.church_role,text)',
    'public.create_church(text,text,text)',
    'public.update_church_profile(uuid,text,text)',
    'public.set_church_status(uuid,public.church_status)',
    'public.set_platform_role(uuid,public.platform_role)',
    'public.create_fantasy_rule_version(uuid,uuid,jsonb)',
    'public.get_league_rules(uuid)',
    'public.get_league_invite_code(uuid)',
    'public.create_fantasy_league(text,uuid,boolean,integer)',
    'public.join_fantasy_league(text)',
    'public.create_fantasy_team_with_squad(uuid,text,jsonb)',
    'public.save_lineup(uuid,jsonb)',
    'public.execute_transfer(uuid,uuid,uuid,uuid)',
    'public.get_fantasy_team_rules(uuid)',
    'public.mark_notifications_read(uuid)',
    'public.lock_gameweek(uuid,boolean)',
    'public.finalize_gameweek(uuid)',
    'public.record_payment_event(text,text,text,text,uuid,uuid,numeric,text,text,public.payment_status)',
    'public.post_wallet_transaction(uuid,public.wallet_tx_type,numeric,text,uuid,text)'
  ] loop
    if to_regprocedure(routine_signature) is null then
      raise exception 'Missing required routine %', routine_signature;
    end if;
  end loop;

  foreach policy_name in array array[
    'profiles_select_own_or_admin','profiles_update_own',
    'churches_select_active_or_member_or_admin','churches_delete_super_admin',
    'church_members_select','seasons_select_all','gameweeks_select_all','teams_select_all',
    'players_select_all','matches_select_all','mps_select_all','fantasy_rules_select',
    'leagues_select_secure','fteams_select_own_or_super_admin',
    'ftplayers_select_owner_or_super_admin','snapshots_select_after_lock',
    'ftgw_points_select_participants','notifications_select_own','announcements_select',
    'audit_logs_select_admin','payment_events_super_admin_select'
  ] loop
    if not exists(select 1 from pg_policies where schemaname='public' and policyname=policy_name) then
      raise exception 'Missing required RLS policy %', policy_name;
    end if;
  end loop;

  if (
    select count(distinct conname) from pg_constraint
    where conname in (
      'players_team_id_fkey','matches_gameweek_id_fkey','matches_home_team_id_fkey',
      'matches_away_team_id_fkey','fantasy_teams_league_id_fkey',
      'fantasy_team_players_player_id_fkey',
      'fantasy_team_gameweek_points_gameweek_id_fkey'
    )
  ) <> 7 then
    raise exception 'One or more frontend relationship foreign keys are missing';
  end if;

  if exists(
    select 1 from auth.users users
    left join public.profiles profiles on profiles.id=users.id
    where profiles.id is null
  ) then
    raise exception 'One or more Auth users are missing profiles';
  end if;

  if not has_function_privilege(
    'authenticated','public.create_fantasy_team_with_squad(uuid,text,jsonb)','EXECUTE'
  ) or not has_function_privilege(
    'authenticated','public.save_lineup(uuid,jsonb)','EXECUTE'
  ) or not has_function_privilege(
    'authenticated','public.execute_transfer(uuid,uuid,uuid,uuid)','EXECUTE'
  ) then
    raise exception 'Authenticated gameplay RPC grants are incomplete';
  end if;

  if exists(
    select required.id from (values('avatars'),('church-media'),('player-media'),('ad-media')) required(id)
    left join storage.buckets buckets on buckets.id=required.id
    where buckets.id is null
  ) then
    raise exception 'One or more required storage buckets are missing';
  end if;
end;
$$;

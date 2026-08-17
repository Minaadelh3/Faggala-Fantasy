-- ============================================================
-- FANTASY CHURCH PLATFORM — CORE SCHEMA
-- Migration: 001_schema.sql
-- Target: PostgreSQL 15+ (Supabase)
-- ============================================================

-- ------------------------------------------------------------
-- EXTENSIONS
-- ------------------------------------------------------------
create extension if not exists "uuid-ossp";
create extension if not exists "pgcrypto";

-- ------------------------------------------------------------
-- ENUM TYPES
-- ------------------------------------------------------------
create type platform_role as enum ('super_admin', 'user');
create type church_role as enum ('church_admin', 'league_admin', 'member');
create type church_status as enum ('pending', 'active', 'suspended');

create type player_position as enum ('GK', 'DEF', 'MID', 'FWD');
create type player_status as enum ('available', 'injured', 'suspended', 'doubtful');

create type match_status as enum ('scheduled', 'live', 'finished', 'postponed', 'cancelled');

create type league_status as enum ('draft', 'active', 'closed', 'archived');

create type ad_placement as enum (
  'home_banner', 'fantasy_banner', 'church_dashboard', 'leaderboard', 'sponsored_post', 'popup'
);
create type ad_status as enum ('draft', 'pending_review', 'active', 'paused', 'ended', 'rejected');

create type subscription_tier as enum ('free', 'pro', 'premium');
create type subscription_status as enum ('trialing', 'active', 'past_due', 'canceled', 'expired');

create type payment_status as enum ('pending', 'succeeded', 'failed', 'refunded');

create type notification_type as enum (
  'gameweek_start', 'gameweek_end', 'results', 'transfer_deadline', 'church_announcement', 'promotion', 'system'
);

create type wallet_tx_type as enum ('credit', 'debit');

-- ------------------------------------------------------------
-- USERS / PROFILES
-- profiles extends auth.users (Supabase managed table)
-- ------------------------------------------------------------
create table profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  full_name text,
  avatar_url text,
  phone text,
  platform_role platform_role not null default 'user',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ------------------------------------------------------------
-- CHURCHES (TENANTS)
-- ------------------------------------------------------------
create table churches (
  id uuid primary key default uuid_generate_v4(),
  owner_id uuid not null references profiles (id),
  name text not null,
  slug text not null unique,
  description text,
  status church_status not null default 'pending',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table church_settings (
  church_id uuid primary key references churches (id) on delete cascade,
  logo_url text,
  cover_url text,
  primary_color text default '#1E40AF',
  secondary_color text default '#F59E0B',
  contact_email text,
  contact_phone text,
  address text,
  social_links jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

create table church_members (
  id uuid primary key default uuid_generate_v4(),
  church_id uuid not null references churches (id) on delete cascade,
  user_id uuid not null references profiles (id) on delete cascade,
  role church_role not null default 'member',
  status text not null default 'active', -- active | invited | removed
  joined_at timestamptz not null default now(),
  unique (church_id, user_id)
);

create index idx_church_members_church on church_members (church_id);
create index idx_church_members_user on church_members (user_id);

-- ------------------------------------------------------------
-- SEASONS / GAMEWEEKS (global, shared across all churches)
-- ------------------------------------------------------------
create table seasons (
  id uuid primary key default uuid_generate_v4(),
  name text not null,
  start_date date not null,
  end_date date not null,
  is_current boolean not null default false,
  created_at timestamptz not null default now()
);

create table gameweeks (
  id uuid primary key default uuid_generate_v4(),
  season_id uuid not null references seasons (id) on delete cascade,
  number int not null,
  name text,
  start_date timestamptz not null,
  end_date timestamptz not null,
  transfer_deadline timestamptz not null,
  status text not null default 'upcoming', -- upcoming | active | finished
  unique (season_id, number)
);

-- ------------------------------------------------------------
-- REAL-WORLD TEAMS / PLAYERS / MATCHES (global reference data)
-- ------------------------------------------------------------
create table teams (
  id uuid primary key default uuid_generate_v4(),
  name text not null,
  short_name text,
  logo_url text,
  league_name text,
  country text
);

create table players (
  id uuid primary key default uuid_generate_v4(),
  team_id uuid references teams (id) on delete set null,
  name text not null,
  photo_url text,
  position player_position not null,
  price numeric(6, 2) not null default 4.0,
  status player_status not null default 'available',
  created_at timestamptz not null default now()
);

create index idx_players_team on players (team_id);

create table matches (
  id uuid primary key default uuid_generate_v4(),
  season_id uuid not null references seasons (id) on delete cascade,
  gameweek_id uuid not null references gameweeks (id) on delete cascade,
  home_team_id uuid not null references teams (id),
  away_team_id uuid not null references teams (id),
  match_date timestamptz not null,
  status match_status not null default 'scheduled',
  home_score int,
  away_score int,
  venue text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index idx_matches_gameweek on matches (gameweek_id);

create table match_player_stats (
  id uuid primary key default uuid_generate_v4(),
  match_id uuid not null references matches (id) on delete cascade,
  player_id uuid not null references players (id) on delete cascade,

  minutes_played int not null default 0,
  goals int not null default 0,
  assists int not null default 0,
  shots int not null default 0,
  shots_on_target int not null default 0,
  passes int not null default 0,
  tackles int not null default 0,
  interceptions int not null default 0,
  saves int not null default 0,

  clean_sheet boolean not null default false,
  yellow_cards int not null default 0,
  red_cards int not null default 0,
  own_goals int not null default 0,

  penalties_saved int not null default 0,
  penalties_missed int not null default 0,

  bonus int not null default 0,
  fantasy_points int not null default 0,

  unique (match_id, player_id)
);

create index idx_mps_player on match_player_stats (player_id);

-- ------------------------------------------------------------
-- FANTASY RULES (scoring config, can be overridden per season)
-- ------------------------------------------------------------
create table fantasy_rules (
  id uuid primary key default uuid_generate_v4(),
  season_id uuid not null references seasons (id) on delete cascade,
  church_id uuid references churches (id) on delete cascade, -- null = platform default
  rules jsonb not null default '{
    "goal_gk_def": 6, "goal_mid": 5, "goal_fwd": 4,
    "assist": 3, "clean_sheet_gk_def": 4, "clean_sheet_mid": 1,
    "yellow_card": -1, "red_card": -3, "own_goal": -2,
    "penalty_miss": -2, "penalty_save": 5, "save_every_3": 1,
    "minutes_60_plus": 2, "minutes_under_60": 1
  }'::jsonb,
  created_at timestamptz not null default now(),
  unique (season_id, church_id)
);

-- ------------------------------------------------------------
-- FANTASY LEAGUES (tenant-scoped, church_id nullable = cross-church league)
-- ------------------------------------------------------------
create table fantasy_leagues (
  id uuid primary key default uuid_generate_v4(),
  church_id uuid references churches (id) on delete cascade, -- null = platform-wide league
  season_id uuid not null references seasons (id) on delete cascade,
  created_by uuid not null references profiles (id),

  name text not null,
  description text,
  is_private boolean not null default true,
  invite_code text unique,
  max_members int not null default 100,
  status league_status not null default 'draft',

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index idx_leagues_church on fantasy_leagues (church_id);

-- ------------------------------------------------------------
-- FANTASY TEAMS (a user's squad within one league)
-- ------------------------------------------------------------
create table fantasy_teams (
  id uuid primary key default uuid_generate_v4(),
  league_id uuid not null references fantasy_leagues (id) on delete cascade,
  user_id uuid not null references profiles (id) on delete cascade,

  name text not null,
  budget numeric(6, 2) not null default 100.0,
  total_points int not null default 0,
  overall_rank int,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (league_id, user_id)
);

create index idx_fteams_league on fantasy_teams (league_id);
create index idx_fteams_user on fantasy_teams (user_id);

create table fantasy_team_players (
  id uuid primary key default uuid_generate_v4(),
  fantasy_team_id uuid not null references fantasy_teams (id) on delete cascade,
  player_id uuid not null references players (id),

  is_captain boolean not null default false,
  is_vice_captain boolean not null default false,
  is_bench boolean not null default false,
  bench_order int,

  added_at timestamptz not null default now(),
  unique (fantasy_team_id, player_id)
);

create table transfers (
  id uuid primary key default uuid_generate_v4(),
  fantasy_team_id uuid not null references fantasy_teams (id) on delete cascade,
  gameweek_id uuid not null references gameweeks (id),
  player_out_id uuid references players (id),
  player_in_id uuid not null references players (id),
  cost numeric(6, 2) not null default 0, -- points penalty or price diff
  created_at timestamptz not null default now()
);

create table fantasy_team_gameweek_points (
  id uuid primary key default uuid_generate_v4(),
  fantasy_team_id uuid not null references fantasy_teams (id) on delete cascade,
  gameweek_id uuid not null references gameweeks (id) on delete cascade,
  points int not null default 0,
  rank int,
  unique (fantasy_team_id, gameweek_id)
);

-- ------------------------------------------------------------
-- ADVERTISEMENTS
-- ------------------------------------------------------------
create table advertisements (
  id uuid primary key default uuid_generate_v4(),
  church_id uuid not null references churches (id) on delete cascade,

  title text not null,
  description text,
  image_url text,
  target_url text,

  placement ad_placement not null,
  start_date timestamptz not null,
  end_date timestamptz not null,
  status ad_status not null default 'draft',

  budget numeric(10, 2) default 0,
  impressions bigint not null default 0,
  clicks bigint not null default 0,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index idx_ads_church on advertisements (church_id);
create index idx_ads_placement_status on advertisements (placement, status);

-- ------------------------------------------------------------
-- SUBSCRIPTIONS / PAYMENTS / INVOICES / WALLET
-- ------------------------------------------------------------
create table subscriptions (
  id uuid primary key default uuid_generate_v4(),
  church_id uuid not null references churches (id) on delete cascade,
  tier subscription_tier not null default 'free',
  status subscription_status not null default 'active',
  current_period_start timestamptz not null default now(),
  current_period_end timestamptz,
  cancel_at_period_end boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table payments (
  id uuid primary key default uuid_generate_v4(),
  church_id uuid not null references churches (id) on delete cascade,
  subscription_id uuid references subscriptions (id),

  amount numeric(10, 2) not null,
  currency text not null default 'EGP',
  status payment_status not null default 'pending',
  provider text, -- e.g. stripe, paymob, fawry
  provider_payment_id text,

  created_at timestamptz not null default now()
);

create table invoices (
  id uuid primary key default uuid_generate_v4(),
  church_id uuid not null references churches (id) on delete cascade,
  payment_id uuid references payments (id),
  invoice_number text not null unique,
  amount numeric(10, 2) not null,
  status text not null default 'issued',
  issued_at timestamptz not null default now(),
  due_at timestamptz
);

create table church_wallet (
  church_id uuid primary key references churches (id) on delete cascade,
  balance numeric(10, 2) not null default 0,
  currency text not null default 'EGP',
  updated_at timestamptz not null default now()
);

create table church_wallet_transactions (
  id uuid primary key default uuid_generate_v4(),
  church_id uuid not null references churches (id) on delete cascade,
  type wallet_tx_type not null,
  amount numeric(10, 2) not null,
  reason text, -- e.g. 'ad_purchase', 'topup', 'refund'
  reference_id uuid, -- e.g. advertisement id or payment id
  created_at timestamptz not null default now()
);

-- ------------------------------------------------------------
-- NOTIFICATIONS / ANNOUNCEMENTS / AUDIT LOGS
-- ------------------------------------------------------------
create table notifications (
  id uuid primary key default uuid_generate_v4(),
  user_id uuid not null references profiles (id) on delete cascade,
  church_id uuid references churches (id) on delete cascade,

  title text not null,
  message text,
  type notification_type not null default 'system',
  read boolean not null default false,

  created_at timestamptz not null default now()
);

create index idx_notifications_user on notifications (user_id, read);

create table announcements (
  id uuid primary key default uuid_generate_v4(),
  church_id uuid not null references churches (id) on delete cascade,
  created_by uuid not null references profiles (id),
  title text not null,
  content text not null,
  published_at timestamptz not null default now()
);

create table audit_logs (
  id uuid primary key default uuid_generate_v4(),
  actor_id uuid references profiles (id),
  church_id uuid references churches (id),
  action text not null,
  entity_type text not null,
  entity_id uuid,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index idx_audit_church on audit_logs (church_id);

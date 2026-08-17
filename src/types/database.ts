// Mirrors 001_schema.sql — kept intentionally close to the migration
// so query results can be typed directly against these shapes.

export type PlayerPosition = 'GK' | 'DEF' | 'MID' | 'FWD';
export type PlayerStatus = 'available' | 'injured' | 'suspended' | 'doubtful';
export type MatchStatus = 'scheduled' | 'live' | 'finished' | 'postponed' | 'cancelled';
export type LeagueStatus = 'draft' | 'active' | 'closed' | 'archived';
export type ChurchRole = 'church_admin' | 'league_admin' | 'member';

export interface Profile {
  id: string;
  full_name: string | null;
  avatar_url: string | null;
  platform_role: 'super_admin' | 'user';
}

export interface Church {
  id: string;
  name: string;
  slug: string;
  status: 'pending' | 'active' | 'suspended';
}

export interface Team {
  id: string;
  name: string;
  short_name: string | null;
  logo_url: string | null;
}

export interface Player {
  id: string;
  team_id: string | null;
  name: string;
  photo_url: string | null;
  position: PlayerPosition;
  price: number;
  status: PlayerStatus;
}

export interface Match {
  id: string;
  gameweek_id: string;
  home_team_id: string;
  away_team_id: string;
  match_date: string;
  status: MatchStatus;
  home_score: number | null;
  away_score: number | null;
}

export interface FantasyLeague {
  id: string;
  church_id: string | null;
  season_id: string;
  name: string;
  is_private: boolean;
  invite_code: string | null;
  status: LeagueStatus;
}

export interface FantasyTeam {
  id: string;
  league_id: string;
  user_id: string;
  name: string;
  budget: number;
  total_points: number;
  overall_rank: number | null;
}

export interface FantasyTeamPlayer {
  fantasy_team_id: string;
  player_id: string;
  is_captain: boolean;
  is_vice_captain: boolean;
  is_bench: boolean;
  bench_order: number | null;
}

export interface FantasyTeamGameweekPoints {
  fantasy_team_id: string;
  gameweek_id: string;
  points: number;
  rank: number | null;
}

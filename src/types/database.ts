export type PlayerPosition = 'GK' | 'DEF' | 'MID' | 'FWD';
export type PlayerStatus = 'available' | 'injured' | 'suspended' | 'doubtful';
export type MatchStatus = 'scheduled' | 'live' | 'finished' | 'postponed' | 'cancelled';
export type GameweekStatus = 'upcoming' | 'locked' | 'active' | 'finished';
export interface FantasyRules { starting_budget:number; squad_size:number; lineup_size:number; bench_size:number; position_counts:Record<PlayerPosition,number>; lineup_min:Record<PlayerPosition,number>; lineup_max:Record<PlayerPosition,number>; max_players_per_club:number; free_transfers_per_gameweek:number; max_free_transfers:number; additional_transfer_cost:number; captain_multiplier:number; vice_captain_fallback:boolean; selling_price_basis:'current'|'purchase' }
export interface Profile { id:string; full_name:string|null; avatar_url:string|null; phone?:string|null; platform_role:'super_admin'|'user' }
export interface Church { id:string; name:string; slug:string; status:'pending'|'active'|'suspended'; description?:string|null }
export interface Season { id:string; name:string; start_date:string; end_date:string; is_current:boolean }
export interface Gameweek { id:string; season_id:string; number:number; name:string|null; start_date:string; end_date:string; transfer_deadline:string; status:GameweekStatus }
export interface RealTeam { id:string; name:string; short_name:string|null; logo_url:string|null }
export interface Player { id:string; team_id:string|null; name:string; photo_url:string|null; position:PlayerPosition; price:number; status:PlayerStatus; teams?:RealTeam|null; total_points?:number; form?:number }
export interface Match { id:string; gameweek_id:string; match_date:string; status:MatchStatus; home_score:number|null; away_score:number|null; venue:string|null; home_team?:RealTeam; away_team?:RealTeam }
export interface FantasyLeague { id:string; church_id:string|null; season_id:string; name:string; description:string|null; is_private:boolean; invite_code:string|null; max_members:number; status:'draft'|'active'|'closed'|'archived' }
export interface FantasyTeam { id:string; league_id:string; user_id:string; name:string; starting_budget:number; bank:number; total_points:number; overall_rank:number|null; free_transfers:number; fantasy_leagues?:Pick<FantasyLeague,'name'|'season_id'> }
export interface SquadPlayer { id:string; fantasy_team_id:string; player_id:string; purchase_price:number; is_captain:boolean; is_vice_captain:boolean; is_bench:boolean; bench_order:number|null; players:Player }
export interface Notification { id:string; title:string; message:string|null; type:string; read:boolean; created_at:string }
export interface GameweekPoints { gameweek_id:string; points:number; gross_points:number; transfer_penalty:number; rank:number|null; overall_rank:number|null; finalized_at:string|null; gameweeks?:Gameweek }
export interface FantasyLeaderboardRow { id:string; league_id:string; name:string; total_points:number; overall_rank:number|null; manager_name:string|null; league_name:string; season_id:string }

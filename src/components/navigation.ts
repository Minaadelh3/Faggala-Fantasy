import { BarChart3, CalendarDays, History, LayoutGrid, Repeat2, Shield, Trophy, UserRoundSearch, Users } from 'lucide-react';
export const NAV = [
  ['Home', LayoutGrid, '/app'], ['My Team', Shield, '/app/team'], ['Points', BarChart3, '/app/points'],
  ['Transfers', Repeat2, '/app/transfers'], ['Fixtures', CalendarDays, '/app/fixtures'],
  ['Players', UserRoundSearch, '/app/players'], ['Leagues', Users, '/app/leagues'],
  ['Leaderboard', Trophy, '/app/leaderboards'], ['History', History, '/app/history'],
] as const;
export const MOBILE_NAV = NAV.slice(0,5);

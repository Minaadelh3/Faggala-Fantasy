import { useEffect, useState, type FormEvent } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { Copy, Plus, Users } from 'lucide-react';
import { EmptyState, ErrorNotice, LoadingScreen, PageHeader } from '../components/ui';
import { supabase } from '../lib/supabase';
import type { FantasyLeague, FantasyTeam } from '../types/database';

export default function Leagues() {
  const [leagues, setLeagues] = useState<FantasyLeague[]>([]);
  const [teams, setTeams] = useState<FantasyTeam[]>([]);
  const [code, setCode] = useState('');
  const [name, setName] = useState('');
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(true);
  const navigate = useNavigate();

  const load = async () => {
    const [leagueResult, teamResult] = await Promise.all([
      supabase.from('fantasy_leagues').select('*').eq('status', 'active').order('created_at'),
      supabase.from('fantasy_teams').select('*,fantasy_leagues(name,season_id)').order('created_at'),
    ]);
    const visibleLeagues = (leagueResult.data ?? []) as FantasyLeague[];
    const inviteEntries = await Promise.all(visibleLeagues.filter((league) => league.is_private).map(async (league) => {
      const { data } = await supabase.rpc('get_league_invite_code', { p_league_id: league.id });
      return [league.id, data as string | null] as const;
    }));
    const inviteCodes = new Map(inviteEntries);
    setLeagues(visibleLeagues.map((league) => ({ ...league, invite_code: inviteCodes.get(league.id) ?? null })));
    setTeams((teamResult.data ?? []) as FantasyTeam[]);
    setError(leagueResult.error?.message ?? teamResult.error?.message ?? '');
    setLoading(false);
  };
  useEffect(() => { void load(); }, []);

  const join = async (event: FormEvent) => {
    event.preventDefault();
    const { data, error: joinError } = await supabase.rpc('join_fantasy_league', { p_invite_code: code });
    if (joinError) setError(joinError.message);
    else navigate(`/app/leagues/${String(data)}/build`);
  };
  const create = async (event: FormEvent) => {
    event.preventDefault();
    const { data, error: createError } = await supabase.rpc('create_fantasy_league', {
      p_name: name,
      p_church_id: null,
      p_is_private: true,
      p_max_members: 100,
    });
    if (createError) setError(createError.message);
    else navigate(`/app/leagues/${String((data as { id: string }).id)}/build`);
  };
  if (loading) return <LoadingScreen />;

  return <>
    <PageHeader eyebrow="Community competition" title="My Leagues" />
    {error && <div className="mb-4"><ErrorNotice message={error} /></div>}
    <section className="grid md:grid-cols-2 gap-4 mb-7">
      {teams.map((team) => <article key={team.id} className="panel">
        <p className="eyebrow">{team.fantasy_leagues?.name}</p><h2 className="font-display text-xl font-bold">{team.name}</h2>
        <div className="flex gap-5 text-sm mt-4"><span><strong>{team.total_points}</strong><br />points</span><span><strong>{team.overall_rank ? `#${team.overall_rank}` : '—'}</strong><br />rank</span></div>
        <Link to="/app/leaderboards" className="text-link mt-4 inline-block">View leaderboard</Link>
      </article>)}
      {!teams.length && <EmptyState title="You have no league team yet" message="Join with an invite code, create a private league, or choose an active public league below." />}
    </section>
    <div className="grid md:grid-cols-2 gap-5 mb-7">
      <form className="panel" onSubmit={join}><h2 className="font-display font-bold text-lg">Join a private league</h2>
        <p className="text-sm text-midnight-600 mb-4">Enter the code shared by its creator.</p><div className="flex gap-2">
          <input className="input uppercase" required value={code} onChange={(event) => setCode(event.target.value)} placeholder="FAG-A1B2C3D4E5" />
          <button className="btn-primary">Join</button>
        </div></form>
      <form className="panel" onSubmit={create}><h2 className="font-display font-bold text-lg">Create a league</h2>
        <p className="text-sm text-midnight-600 mb-4">A private invite code is generated securely.</p><div className="flex gap-2">
          <input className="input" required minLength={3} value={name} onChange={(event) => setName(event.target.value)} placeholder="League name" />
          <button className="btn-primary"><Plus size={16} />Create</button>
        </div></form>
    </div>
    <h2 className="font-display font-bold text-xl mb-3">Active leagues</h2>
    <div className="grid sm:grid-cols-2 lg:grid-cols-3 gap-3">{leagues.map((league) => <article className="panel" key={league.id}>
      <Users className="text-gold mb-3" /><h3 className="font-semibold">{league.name}</h3>
      <p className="text-xs text-midnight-600 mt-1">{league.is_private ? 'Private league' : 'Open league'} · up to {league.max_members}</p>
      {league.invite_code && <button title="Copy code" onClick={() => void navigator.clipboard.writeText(league.invite_code!)} className="text-link mt-3 inline-flex gap-1"><Copy size={13} />{league.invite_code}</button>}
      <Link className="btn-secondary w-full mt-4" to={`/app/leagues/${league.id}/build`}>Build team</Link>
    </article>)}</div>
  </>;
}

import { useEffect, useMemo, useState } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import { Check, Search } from 'lucide-react';
import { ErrorNotice, LoadingScreen, PageHeader } from '../components/ui';
import { supabase } from '../lib/supabase';
import { initials, money } from '../lib/format';
import type { FantasyRules, Player, PlayerPosition } from '../types/database';

export default function SquadBuilder() {
  const { leagueId } = useParams();
  const navigate = useNavigate();
  const [players, setPlayers] = useState<Player[]>([]);
  const [rules, setRules] = useState<FantasyRules | null>(null);
  const [selected, setSelected] = useState<string[]>([]);
  const [filter, setFilter] = useState<'ALL' | PlayerPosition>('ALL');
  const [search, setSearch] = useState('');
  const [name, setName] = useState('');
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    void Promise.all([
      supabase.from('players').select('*,teams(*)').order('name'),
      supabase.rpc('get_league_rules', { p_league_id: leagueId }),
    ]).then(([playerResult, ruleResult]) => {
      setPlayers((playerResult.data ?? []) as Player[]);
      setRules(ruleResult.data as FantasyRules | null);
      setError(playerResult.error?.message ?? ruleResult.error?.message ?? '');
      setLoading(false);
    });
  }, [leagueId]);

  const picked = players.filter((player) => selected.includes(player.id));
  const spent = picked.reduce((total, player) => total + Number(player.price), 0);
  const counts = Object.fromEntries(
    (['GK', 'DEF', 'MID', 'FWD'] as PlayerPosition[]).map((position) => [
      position,
      picked.filter((player) => player.position === position).length,
    ]),
  ) as Record<PlayerPosition, number>;
  const visible = useMemo(
    () => players.filter((player) =>
      (filter === 'ALL' || player.position === filter)
      && player.name.toLowerCase().includes(search.toLowerCase())),
    [players, filter, search],
  );

  if (loading) return <LoadingScreen />;
  if (!rules) return <ErrorNotice message={error || 'Fantasy rules are unavailable for this league.'} />;

  const toggle = (player: Player) => {
    if (selected.includes(player.id)) {
      setSelected((current) => current.filter((id) => id !== player.id));
      return;
    }
    if (selected.length >= rules.squad_size) return setError(`Your squad already has ${rules.squad_size} players.`);
    if (counts[player.position] >= rules.position_counts[player.position]) {
      return setError(`You already have ${rules.position_counts[player.position]} ${player.position} players.`);
    }
    if (player.team_id && picked.filter((entry) => entry.team_id === player.team_id).length >= rules.max_players_per_club) {
      return setError(`Maximum ${rules.max_players_per_club} players from ${player.teams?.name ?? 'one club'} reached.`);
    }
    if (spent + Number(player.price) > rules.starting_budget) return setError('Insufficient budget.');
    setError('');
    setSelected((current) => [...current, player.id]);
  };

  const submit = async () => {
    if (selected.length !== rules.squad_size) return setError(`Select all ${rules.squad_size} players first.`);
    if (name.trim().length < 3) return setError('Enter a fantasy team name.');
    setBusy(true);
    setError('');

    const byPosition = (position: PlayerPosition) => picked.filter((player) => player.position === position);
    const starters: Player[] = [];
    for (const position of ['GK', 'DEF', 'MID', 'FWD'] as PlayerPosition[]) {
      starters.push(...byPosition(position).slice(0, rules.lineup_min[position]));
    }
    for (const position of ['DEF', 'MID', 'FWD'] as PlayerPosition[]) {
      for (const player of byPosition(position).slice(rules.lineup_min[position])) {
        if (starters.length < rules.lineup_size) starters.push(player);
      }
    }
    const starterIds = new Set(starters.map((player) => player.id));
    const bench = picked.filter((player) => !starterIds.has(player.id));
    const orderedBench = [
      ...bench.filter((player) => player.position === 'GK'),
      ...bench.filter((player) => player.position !== 'GK'),
    ];
    const payload = picked.map((player) => ({
      player_id: player.id,
      is_bench: !starterIds.has(player.id),
      bench_order: orderedBench.findIndex((entry) => entry.id === player.id) + 1 || null,
      is_captain: player.id === starters[0]?.id,
      is_vice_captain: player.id === starters[1]?.id,
    }));
    const { error: submitError } = await supabase.rpc('create_fantasy_team_with_squad', {
      p_league_id: leagueId,
      p_name: name.trim(),
      p_players: payload,
    });
    if (submitError) {
      setError(submitError.message);
      setBusy(false);
    } else {
      navigate('/app/team');
    }
  };

  return <>
    <PageHeader eyebrow={`${rules.squad_size}-player squad`} title="Build your team">
      <button onClick={() => void submit()} disabled={busy || selected.length !== rules.squad_size} className="btn-primary">
        <Check size={16} />{busy ? 'Creating…' : 'Confirm squad'}
      </button>
    </PageHeader>
    {error && <div className="mb-4"><ErrorNotice message={error} /></div>}
    <div className="sticky top-16 lg:top-0 z-20 bg-midnight-900 text-white rounded-xl p-4 mb-5 shadow-lg">
      <div className="grid grid-cols-3 md:grid-cols-7 gap-3 text-center">
        <div><strong>{selected.length}/{rules.squad_size}</strong><small>Players</small></div>
        {(['GK', 'DEF', 'MID', 'FWD'] as PlayerPosition[]).map((position) =>
          <div key={position}><strong>{counts[position]}/{rules.position_counts[position]}</strong><small>{position}</small></div>)}
        <div><strong>{money(rules.starting_budget - spent)}</strong><small>Remaining</small></div>
        <label className="col-span-3 md:col-span-1"><span className="sr-only">Team name</span>
          <input className="input text-midnight-900" placeholder="Team name" value={name} onChange={(event) => setName(event.target.value)} />
        </label>
      </div>
    </div>
    <div className="flex flex-wrap gap-2 mb-4">
      {(['ALL', 'GK', 'DEF', 'MID', 'FWD'] as const).map((position) =>
        <button className={filter === position ? 'filter-active' : 'filter'} key={position} onClick={() => setFilter(position)}>{position}</button>)}
      <label className="search-box"><Search size={15} />
        <input placeholder="Search players" value={search} onChange={(event) => setSearch(event.target.value)} />
      </label>
    </div>
    <div className="grid sm:grid-cols-2 lg:grid-cols-3 gap-3">
      {visible.map((player) => {
        const active = selected.includes(player.id);
        return <button onClick={() => toggle(player)} key={player.id} className={`player-row text-left ${active ? 'border-gold bg-gold/5' : ''}`}>
          <span className="player-avatar-sm">{player.photo_url ? <img src={player.photo_url} alt="" /> : initials(player.name)}</span>
          <span className="min-w-0 flex-1"><strong className="block truncate">{player.name}</strong><small>{player.teams?.name ?? 'Free agent'} · {player.status}</small></span>
          <span className="text-right"><strong>{money(player.price)}</strong><small className="block">{player.position}</small></span>
        </button>;
      })}
    </div>
  </>;
}

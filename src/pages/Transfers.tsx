import { useEffect, useMemo, useState } from 'react';
import { ArrowRight, Repeat2 } from 'lucide-react';
import { EmptyState, ErrorNotice, LoadingScreen, PageHeader } from '../components/ui';
import { supabase } from '../lib/supabase';
import { cairoDate, deadlineOpen, money } from '../lib/format';
import type { FantasyRules, FantasyTeam, Gameweek, Player, SquadPlayer } from '../types/database';

export default function Transfers() {
  const [team, setTeam] = useState<FantasyTeam | null>(null);
  const [gameweek, setGameweek] = useState<Gameweek | null>(null);
  const [rules, setRules] = useState<FantasyRules | null>(null);
  const [squad, setSquad] = useState<SquadPlayer[]>([]);
  const [players, setPlayers] = useState<Player[]>([]);
  const [outgoing, setOutgoing] = useState<SquadPlayer | null>(null);
  const [incoming, setIncoming] = useState<Player | null>(null);
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(true);

  const load = async () => {
    const teamResult = await supabase.from('fantasy_teams')
      .select('*,fantasy_leagues(name,season_id)').order('created_at').limit(1).maybeSingle();
    const fantasyTeam = teamResult.data as FantasyTeam | null;
    setTeam(fantasyTeam);
    if (fantasyTeam) {
      const [squadResult, playerResult, weekResult, ruleResult] = await Promise.all([
        supabase.from('fantasy_team_players').select('*,players(*,teams(*))').eq('fantasy_team_id', fantasyTeam.id),
        supabase.from('players').select('*,teams(*)').order('name'),
        supabase.from('gameweeks').select('*').eq('season_id', fantasyTeam.fantasy_leagues!.season_id)
          .eq('status', 'upcoming').order('number').limit(1).maybeSingle(),
        supabase.rpc('get_fantasy_team_rules', { p_team_id: fantasyTeam.id }),
      ]);
      setSquad((squadResult.data ?? []) as SquadPlayer[]);
      setPlayers((playerResult.data ?? []) as Player[]);
      setGameweek(weekResult.data as Gameweek | null);
      setRules(ruleResult.data as FantasyRules | null);
      setError(squadResult.error?.message ?? playerResult.error?.message
        ?? weekResult.error?.message ?? ruleResult.error?.message ?? '');
    }
    setLoading(false);
  };
  useEffect(() => { void load(); }, []);

  const valid = useMemo(() => players.filter((player) => outgoing
    && player.position === outgoing.players.position
    && !squad.some((entry) => entry.player_id === player.id)
    && Number(player.price) <= Number(team?.bank ?? 0) + Number(outgoing.players.price)),
  [players, outgoing, squad, team]);

  if (loading) return <LoadingScreen />;
  if (!team) return <><PageHeader title="Transfers" /><EmptyState title="Build a team first" message="Transfers become available after your first squad is created." /></>;
  const penalty = team.free_transfers > 0 ? 0 : (rules?.additional_transfer_cost ?? 0);
  const execute = async () => {
    if (!outgoing || !incoming || !gameweek) return;
    const summary = `${outgoing.players.name} OUT\n${incoming.name} IN\n\nPoints cost: ${penalty}`;
    if (!window.confirm(`Confirm transfer?\n\n${summary}`)) return;
    const { error: transferError } = await supabase.rpc('execute_transfer', {
      p_team_id: team.id,
      p_player_out: outgoing.player_id,
      p_player_in: incoming.id,
      p_gameweek_id: gameweek.id,
    });
    if (transferError) setError(transferError.message);
    else {
      setOutgoing(null);
      setIncoming(null);
      setLoading(true);
      await load();
    }
  };

  return <>
    <PageHeader eyebrow={`${team.free_transfers} free transfer${team.free_transfers === 1 ? '' : 's'} · Bank ${money(team.bank)}`} title="Transfers" />
    {gameweek && <p className="text-sm text-midnight-600 mb-5">Deadline: {cairoDate(gameweek.transfer_deadline)}</p>}
    {!deadlineOpen(gameweek?.transfer_deadline) && <div className="locked-banner">Transfers are locked for this gameweek.</div>}
    {error && <div className="mb-4"><ErrorNotice message={error} /></div>}
    <div className="grid lg:grid-cols-[1fr_auto_1fr] gap-4 items-start">
      <section className="panel"><h2 className="font-display font-bold mb-3">1. Player out</h2><div className="space-y-2">
        {squad.map((entry) => <button disabled={!deadlineOpen(gameweek?.transfer_deadline)} key={entry.id}
          onClick={() => { setOutgoing(entry); setIncoming(null); }}
          className={`player-row w-full text-left ${outgoing?.id === entry.id ? 'border-red-400 bg-red-50' : ''}`}>
          <span className="position-tag">{entry.players.position}</span><span className="flex-1">{entry.players.name}</span><strong>{money(entry.players.price)}</strong>
        </button>)}
      </div></section>
      <ArrowRight className="hidden lg:block text-gold mt-28" />
      <section className="panel"><h2 className="font-display font-bold mb-3">2. Replacement</h2>
        {outgoing ? <div className="space-y-2 max-h-[580px] overflow-y-auto">{valid.map((player) =>
          <button key={player.id} onClick={() => setIncoming(player)} className={`player-row w-full text-left ${incoming?.id === player.id ? 'border-green-500 bg-green-50' : ''}`}>
            <span className="position-tag">{player.position}</span><span className="flex-1"><strong>{player.name}</strong><small className="block text-midnight-600">{player.teams?.name} · {player.status}</small></span><strong>{money(player.price)}</strong>
          </button>)}</div> : <p className="empty-copy">Choose a player from your squad to see valid same-position replacements.</p>}
      </section>
    </div>
    {outgoing && incoming && <div className="sticky bottom-4 mt-5 bg-midnight-900 text-white rounded-xl p-4 flex flex-wrap items-center justify-between gap-3 shadow-xl">
      <div className="flex items-center gap-3"><Repeat2 className="text-gold" /><div>
        <strong>{outgoing.players.name} OUT · {incoming.name} IN</strong>
        <p className="text-xs text-mist/60">New bank: {money(Number(team.bank) + Number(rules?.selling_price_basis === 'purchase' ? outgoing.purchase_price : outgoing.players.price) - Number(incoming.price))} · Points cost: {penalty}</p>
      </div></div><button onClick={() => void execute()} className="btn-primary">Confirm transfer</button>
    </div>}
  </>;
}

type LiveMatchRowProps = {
  league: string;
  home: string;
  away: string;
  homeScore: number;
  awayScore: number;
  status: string;
  yourPoints: number;
};

export default function LiveMatchRow({
  league,
  home,
  away,
  homeScore,
  awayScore,
  status,
  yourPoints,
}: LiveMatchRowProps) {
  const isLive = status !== 'FT';
  return (
    <div className="flex items-center justify-between py-3 border-b border-mist last:border-0">
      <div>
        <p className="text-[11px] uppercase tracking-wide text-midnight-600/50">{league}</p>
        <p className="text-sm font-medium text-midnight-900">
          {home} <span className="font-display font-bold">{homeScore}</span> – {away}{' '}
          <span className="font-display font-bold">{awayScore}</span>
        </p>
      </div>
      <div className="text-right">
        <span
          className={`text-xs font-semibold ${isLive ? 'text-gold-dim' : 'text-midnight-600/60'}`}
        >
          {status}
        </span>
        <p className="text-xs text-midnight-600/60">{yourPoints} pts</p>
      </div>
    </div>
  );
}

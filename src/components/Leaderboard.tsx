import { Trophy } from 'lucide-react';
import { leaderboard } from '../data/mock';

export default function Leaderboard() {
  return (
    <div className="rounded-xl border border-mist bg-white p-4">
      <div className="flex items-center justify-between mb-3">
        <h3 className="font-display font-semibold text-midnight-900">Leaderboard</h3>
        <span className="text-xs text-midnight-600/60">This week</span>
      </div>
      <ul className="divide-y divide-mist">
        {leaderboard.map((row) => (
          <li key={row.rank} className="flex items-center justify-between py-2">
            <div className="flex items-center gap-3">
              <span
                className={`flex h-6 w-6 items-center justify-center rounded-full text-xs font-bold ${
                  row.rank === 1 ? 'bg-gold text-midnight-900' : 'bg-paper text-midnight-600'
                }`}
              >
                {row.rank}
              </span>
              <span className="text-sm font-medium text-midnight-900">{row.name}</span>
              {row.rank === 1 && <Trophy size={14} className="text-gold" />}
            </div>
            <span className="text-sm font-display font-semibold text-midnight-900">
              {row.points.toLocaleString()}
            </span>
          </li>
        ))}
      </ul>
    </div>
  );
}

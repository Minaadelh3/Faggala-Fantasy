import { AreaChart, Area, XAxis, ResponsiveContainer, Tooltip } from 'recharts';
import { pointsTrend } from '../data/mock';

export default function PointsChart() {
  return (
    <div className="rounded-xl border border-mist bg-white p-4">
      <div className="flex items-center justify-between mb-2">
        <h3 className="font-display font-semibold text-midnight-900">Points trend</h3>
        <span className="text-xs text-midnight-600/60">This week</span>
      </div>
      <ResponsiveContainer width="100%" height={160}>
        <AreaChart data={pointsTrend} margin={{ top: 8, right: 8, left: 0, bottom: 0 }}>
          <defs>
            <linearGradient id="goldFill" x1="0" y1="0" x2="0" y2="1">
              <stop offset="0%" stopColor="#DAA520" stopOpacity={0.35} />
              <stop offset="100%" stopColor="#DAA520" stopOpacity={0} />
            </linearGradient>
          </defs>
          <XAxis
            dataKey="day"
            tick={{ fontSize: 11, fill: '#0D2737', fillOpacity: 0.5 }}
            axisLine={false}
            tickLine={false}
          />
          <Tooltip
            contentStyle={{
              background: '#0D2737',
              border: 'none',
              borderRadius: 8,
              color: '#fff',
              fontSize: 12,
            }}
          />
          <Area type="monotone" dataKey="points" stroke="#DAA520" strokeWidth={2} fill="url(#goldFill)" />
        </AreaChart>
      </ResponsiveContainer>
    </div>
  );
}

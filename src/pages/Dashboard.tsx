import { Trophy, TrendingUp, Wallet, Swords, Bell } from 'lucide-react';
import Sidebar from '../components/Sidebar';
import StatCard from '../components/StatCard';
import PointsChart from '../components/PointsChart';
import Leaderboard from '../components/Leaderboard';
import LiveMatchRow from '../components/LiveMatchRow';
import ArcDivider from '../components/ArcDivider';
import { currentUser, liveMatches, myTeam, nextMatch } from '../data/mock';

export default function Dashboard() {
  return (
    <div className="min-h-screen flex bg-paper">
      <Sidebar />

      <main className="flex-1 p-5 md:p-8 max-w-7xl mx-auto w-full">
        <header className="flex items-start justify-between mb-6">
          <div>
            <p className="text-xs uppercase tracking-wide text-gold-dim font-semibold">
              {currentUser.church}
            </p>
            <h1 className="font-display text-2xl font-bold text-midnight-900 mt-0.5">
              Welcome back, {currentUser.name}
            </h1>
            <ArcDivider className="mt-2" />
          </div>
          <button className="relative rounded-full border border-mist bg-white p-2">
            <Bell size={18} className="text-midnight-700" />
            <span className="absolute -top-1 -right-1 h-2.5 w-2.5 rounded-full bg-gold" />
          </button>
        </header>

        <section className="grid grid-cols-2 md:grid-cols-4 gap-3 mb-6">
          <StatCard
            label="Total points"
            value={currentUser.totalPoints.toLocaleString()}
            sublabel={`+${currentUser.weeklyChangePct}% vs last week`}
            icon={TrendingUp}
            accent
          />
          <StatCard label="Rank" value={`#${currentUser.rank.toLocaleString()}`} sublabel="Top 3%" icon={Trophy} />
          <StatCard
            label="Winnings"
            value={`E£${currentUser.winnings.toLocaleString()}`}
            sublabel="Total"
            icon={Wallet}
          />
          <StatCard
            label="Contests"
            value={String(currentUser.activeContests)}
            sublabel="Active"
            icon={Swords}
          />
        </section>

        <section className="grid grid-cols-1 lg:grid-cols-3 gap-5">
          <div className="lg:col-span-2 space-y-5">
            <PointsChart />

            <div className="rounded-xl border border-mist bg-white p-4">
              <div className="flex items-center justify-between mb-2">
                <h3 className="font-display font-semibold text-midnight-900">Live now</h3>
                <button className="text-xs font-medium text-gold-dim hover:underline">View all</button>
              </div>
              {liveMatches.map((m) => (
                <LiveMatchRow key={`${m.home}-${m.away}`} {...m} />
              ))}
            </div>

            <div className="rounded-xl border border-mist bg-white p-4">
              <h3 className="font-display font-semibold text-midnight-900 mb-3">My top players</h3>
              <div className="grid grid-cols-2 sm:grid-cols-4 gap-3">
                {myTeam.map((p) => (
                  <div
                    key={p.name}
                    className="rounded-lg border border-mist p-3 text-center bg-paper"
                  >
                    <div className="mx-auto mb-2 h-10 w-10 rounded-full bg-midnight-800 flex items-center justify-center text-gold font-display font-bold text-sm">
                      {p.name.split(' ').map((n) => n[0]).join('')}
                    </div>
                    <p className="text-xs font-medium text-midnight-900">{p.name}</p>
                    <p className="text-[10px] text-midnight-600/60">{p.position}</p>
                    <p className="text-xs font-display font-bold text-gold-dim mt-1">{p.points} pts</p>
                  </div>
                ))}
              </div>
            </div>
          </div>

          <div className="space-y-5">
            <div className="rounded-xl bg-midnight-900 text-white p-4 relative overflow-hidden">
              <p className="text-xs uppercase tracking-wide text-gold-light font-semibold">Next match</p>
              <p className="font-display font-bold mt-1">
                {nextMatch.home} vs {nextMatch.away}
              </p>
              <p className="text-xs text-mist/70 mt-1">{nextMatch.kickoff}</p>
              <ArcDivider className="mt-3" />
            </div>
            <Leaderboard />
          </div>
        </section>
      </main>
    </div>
  );
}

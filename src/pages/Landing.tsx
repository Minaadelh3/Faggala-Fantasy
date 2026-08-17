import { Link } from 'react-router-dom';
import Logo from '../components/Logo';
import ArcDivider from '../components/ArcDivider';

export default function Landing() {
  return (
    <div className="min-h-screen bg-midnight-900 text-white relative overflow-hidden flex flex-col">
      {/* ambient gateway glow */}
      <div className="absolute inset-0 bg-gateway-glow pointer-events-none" />
      <div className="absolute -top-24 -left-24 h-72 w-72 rounded-full bg-gold/10 blur-3xl" />
      <div className="absolute -bottom-24 -right-24 h-72 w-72 rounded-full bg-gold/10 blur-3xl" />

      <header className="relative z-10 flex items-center justify-between px-6 md:px-12 py-6">
        <div className="flex items-center gap-2">
          <Logo variant="mark" className="w-9 h-9" />
          <span className="font-display italic font-extrabold text-lg">Fantasy</span>
        </div>
        <Link
          to="/dashboard"
          className="rounded-full border border-gold/50 px-4 py-1.5 text-sm font-medium text-gold-light hover:bg-gold hover:text-midnight-900 transition-colors"
        >
          Enter the gateway
        </Link>
      </header>

      <main className="relative z-10 flex-1 flex flex-col items-center justify-center text-center px-6 py-16">
        <Logo variant="mark" className="w-32 h-32 mb-6 drop-shadow-[0_0_30px_rgba(218,165,32,0.35)]" />
        <p className="font-arabic text-gold-light text-sm mb-2" dir="rtl">
          كل لعبة طريق للمحبة
        </p>
        <h1 className="font-display italic font-extrabold text-4xl md:text-6xl leading-tight max-w-3xl">
          Every game is a path to belonging.
        </h1>
        <ArcDivider className="my-6" />
        <p className="text-mist/70 max-w-xl mb-8">
          Fantasy brings your church community together through the game — build your
          dream team, follow your league live, and climb the leaderboard, all under one
          gateway.
        </p>
        <div className="flex flex-col sm:flex-row gap-3">
          <Link
            to="/dashboard"
            className="rounded-lg bg-gold text-midnight-900 font-display font-bold px-6 py-3 hover:bg-gold-light transition-colors"
          >
            Pick. Compete. Win.
          </Link>
          <a
            href="#how-it-works"
            className="rounded-lg border border-mist/30 px-6 py-3 font-medium text-mist hover:border-gold hover:text-gold-light transition-colors"
          >
            How it works
          </a>
        </div>
      </main>

      <footer id="how-it-works" className="relative z-10 grid grid-cols-2 md:grid-cols-4 gap-px bg-midnight-700">
        {[
          { label: 'Build your team', desc: 'Pick players within budget' },
          { label: 'Follow live', desc: 'Real-time scores and points' },
          { label: 'Compete in league', desc: 'Your church, your community' },
          { label: 'Climb the board', desc: 'Weekly and season rankings' },
        ].map((s) => (
          <div key={s.label} className="bg-midnight-900 p-6 text-left">
            <p className="text-xs uppercase tracking-wide text-gold-dim font-semibold mb-1">
              {s.label}
            </p>
            <p className="text-sm text-mist/70">{s.desc}</p>
          </div>
        ))}
      </footer>
    </div>
  );
}

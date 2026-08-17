import {
  LayoutGrid,
  Swords,
  Users,
  BarChart3,
  Trophy,
  ListOrdered,
  Settings,
  LifeBuoy,
  LogOut,
} from 'lucide-react';
import Logo from './Logo';

const NAV = [
  { label: 'Overview', icon: LayoutGrid, active: true },
  { label: 'My Contests', icon: Swords },
  { label: 'My Teams', icon: Users },
  { label: 'Live Scores', icon: BarChart3 },
  { label: 'Standings', icon: ListOrdered },
  { label: 'Leaderboards', icon: Trophy },
];

export default function Sidebar() {
  return (
    <aside className="hidden md:flex md:w-60 md:flex-col bg-midnight-900 text-mist px-4 py-6 shrink-0">
      <div className="flex items-center gap-2 px-2 mb-8">
        <Logo variant="mark" className="w-8 h-8" />
        <span className="font-display italic font-extrabold text-lg text-white">Fantasy</span>
      </div>

      <nav className="flex-1 space-y-1">
        {NAV.map(({ label, icon: Icon, active }) => (
          <button
            key={label}
            className={`w-full flex items-center gap-3 rounded-lg px-3 py-2 text-sm transition-colors ${
              active
                ? 'bg-midnight-700 text-white border-l-2 border-gold'
                : 'text-mist/70 hover:bg-midnight-800 hover:text-white'
            }`}
          >
            <Icon size={16} strokeWidth={2} />
            {label}
          </button>
        ))}
      </nav>

      <div className="space-y-1 border-t border-midnight-700 pt-3">
        <button className="w-full flex items-center gap-3 rounded-lg px-3 py-2 text-sm text-mist/70 hover:bg-midnight-800 hover:text-white">
          <Settings size={16} /> Settings
        </button>
        <button className="w-full flex items-center gap-3 rounded-lg px-3 py-2 text-sm text-mist/70 hover:bg-midnight-800 hover:text-white">
          <LifeBuoy size={16} /> Help &amp; Support
        </button>
        <button className="w-full flex items-center gap-3 rounded-lg px-3 py-2 text-sm text-mist/70 hover:bg-midnight-800 hover:text-white">
          <LogOut size={16} /> Log Out
        </button>
      </div>
    </aside>
  );
}

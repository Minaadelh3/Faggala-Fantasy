import { LifeBuoy, LogOut, Settings, Shield } from 'lucide-react';
import { NavLink } from 'react-router-dom';
import Logo from './Logo';
import { useAuth } from '../contexts/AuthContext';
import { NAV } from './navigation';

export default function Sidebar() {
  const { profile, signOut } = useAuth();
  return <aside className="sidebar-shell">
    <NavLink to="/app" className="brand-lockup" aria-label="Faggala Fantasy home"><Logo className="h-16 w-44" /></NavLink>
    <p className="sidebar-label">Game</p>
    <nav className="flex-1 space-y-1 overflow-y-auto" aria-label="Primary navigation">
      {NAV.map(([label, Icon, to]) => <NavLink key={to} end={to === '/app'} to={to} className={({ isActive }) => `nav-link ${isActive ? 'nav-active' : ''}`}><Icon size={18} aria-hidden="true" />{label}</NavLink>)}
      {profile?.platform_role === 'super_admin' && <NavLink to="/admin" className={({ isActive }) => `nav-link ${isActive ? 'nav-active' : ''}`}><Shield size={18} />Competition Control</NavLink>}
    </nav>
    <div className="space-y-1 border-t border-white/10 pt-3">
      <NavLink className="nav-link" to="/app/settings"><Settings size={17} />Settings</NavLink>
      <NavLink className="nav-link" to="/app/help"><LifeBuoy size={17} />Rules & help</NavLink>
      <button className="nav-link w-full" onClick={() => void signOut()}><LogOut size={17} />Log out</button>
    </div>
  </aside>;
}

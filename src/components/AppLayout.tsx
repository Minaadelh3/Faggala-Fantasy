import { useEffect, useState } from 'react';
import { Bell, Menu, Settings, X } from 'lucide-react';
import { NavLink, Outlet } from 'react-router-dom';
import Sidebar from './Sidebar';
import { MOBILE_NAV, NAV } from './navigation';
import Logo from './Logo';
import { useAuth } from '../contexts/AuthContext';
import { supabase } from '../lib/supabase';

export default function AppLayout() {
  const { user, profile } = useAuth();
  const [open, setOpen] = useState(false);
  const [unread, setUnread] = useState(0);
  useEffect(() => {
    if (!user) return;
    const load = async () => { const { count } = await supabase.from('notifications').select('*', { count: 'exact', head: true }).eq('read', false); setUnread(count ?? 0); };
    void load();
    const channel = supabase.channel(`notifications:${user.id}`).on('postgres_changes', { event: '*', schema: 'public', table: 'notifications', filter: `user_id=eq.${user.id}` }, load).subscribe();
    return () => { void supabase.removeChannel(channel); };
  }, [user]);
  return <div className="app-frame"><Sidebar /><div className="min-w-0 flex-1">
    <header className="mobile-header"><NavLink to="/app" aria-label="Home"><Logo className="h-11 w-28" /></NavLink><div className="flex items-center gap-1"><NavLink to="/app/notifications" aria-label={`${unread} unread notifications`} className="header-icon"><Bell size={20} />{unread > 0 && <span className="badge-dot">{Math.min(unread, 9)}</span>}</NavLink><button aria-label={open ? 'Close menu' : 'Open menu'} onClick={() => setOpen(!open)} className="header-icon">{open ? <X /> : <Menu />}</button></div></header>
    {open && <nav className="mobile-drawer" aria-label="More navigation"><p className="px-3 pb-3 text-sm text-white/50">Signed in as {profile?.full_name ?? 'Manager'}</p>{NAV.slice(5).map(([label, Icon, to]) => <NavLink onClick={() => setOpen(false)} key={to} to={to} className={({ isActive }) => `nav-link ${isActive ? 'nav-active' : ''}`}><Icon size={18} />{label}</NavLink>)}<NavLink onClick={() => setOpen(false)} className="nav-link" to="/app/notifications"><Bell size={18} />Notifications</NavLink><NavLink onClick={() => setOpen(false)} className="nav-link" to="/app/settings"><Settings size={18} />Settings & help</NavLink></nav>}
    <main className="page-shell"><Outlet /></main>
    <nav className="bottom-nav" aria-label="Mobile primary navigation">{MOBILE_NAV.map(([label, Icon, to]) => <NavLink key={to} end={to === '/app'} to={to} className={({ isActive }) => `bottom-nav-link ${isActive ? 'is-active' : ''}`}><Icon size={20} /><span>{label === 'My Team' ? 'Team' : label}</span></NavLink>)}</nav>
  </div></div>;
}

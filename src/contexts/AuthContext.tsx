/* oxlint-disable react/only-export-components */
import {createContext,useContext,useEffect,useMemo,useState,type ReactNode} from 'react';
import type {Session,User} from '@supabase/supabase-js';
import {isSupabaseConfigured,supabase} from '../lib/supabase';
import type {Profile} from '../types/database';
interface AuthState{user:User|null;session:Session|null;profile:Profile|null;loading:boolean;refreshProfile:()=>Promise<void>;signOut:()=>Promise<void>}
const AuthContext=createContext<AuthState|null>(null);
export function AuthProvider({children}:{children:ReactNode}){
 const[session,setSession]=useState<Session|null>(null);const[profile,setProfile]=useState<Profile|null>(null);const[loading,setLoading]=useState(true);
 const loadProfile=async(user:User|null)=>{if(!user){setProfile(null);return}const{data}=await supabase.from('profiles').select('id,full_name,avatar_url,phone,platform_role').eq('id',user.id).maybeSingle();setProfile(data as Profile|null)};
 useEffect(()=>{if(!isSupabaseConfigured){setLoading(false);return}void supabase.auth.getSession().then(async({data})=>{setSession(data.session);await loadProfile(data.session?.user??null);setLoading(false)});const{data:listener}=supabase.auth.onAuthStateChange((_event,next)=>{setSession(next);void loadProfile(next?.user??null);setLoading(false)});return()=>listener.subscription.unsubscribe()},[]);
 const value=useMemo<AuthState>(()=>({user:session?.user??null,session,profile,loading,refreshProfile:async()=>loadProfile(session?.user??null),signOut:async()=>{await supabase.auth.signOut()}}),[session,profile,loading]);
 return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>
}
export function useAuth(){const value=useContext(AuthContext);if(!value)throw new Error('useAuth must be inside AuthProvider');return value}

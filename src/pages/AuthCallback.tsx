import{useEffect}from'react';import{useNavigate}from'react-router-dom';import{supabase}from'../lib/supabase';import{LoadingScreen}from'../components/ui';
export default function AuthCallback(){const nav=useNavigate();useEffect(()=>{void supabase.auth.getSession().then(()=>nav('/app',{replace:true}))},[nav]);return <LoadingScreen label="Confirming your account…"/>}

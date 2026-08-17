import{Navigate,Outlet,useLocation}from'react-router-dom';import{useAuth}from'../contexts/AuthContext';import{LoadingScreen}from'./ui';
export function ProtectedRoute(){const{user,loading}=useAuth();const location=useLocation();if(loading)return <LoadingScreen/>;return user?<Outlet/>:<Navigate to="/login" state={{from:location}} replace/>}
export function AdminRoute(){const{profile,loading}=useAuth();if(loading)return <LoadingScreen/>;return profile?.platform_role==='super_admin'?<Outlet/>:<Navigate to="/app" replace/>}

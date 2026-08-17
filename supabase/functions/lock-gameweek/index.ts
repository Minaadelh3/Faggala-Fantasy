import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
const cors={ 'Access-Control-Allow-Origin':'*','Access-Control-Allow-Headers':'authorization, x-client-info, apikey, content-type','Content-Type':'application/json' };
const response=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:cors});
Deno.serve(async(req)=>{
 if(req.method==='OPTIONS')return new Response('ok',{headers:cors});
 if(req.method!=='POST')return response({error:'Method not allowed'},405);
 const token=req.headers.get('Authorization');if(!token)return response({error:'Missing authorization'},401);
 const url=Deno.env.get('SUPABASE_URL')!;const key=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
 const caller=createClient(url,key,{global:{headers:{Authorization:token}}});const{data:{user}}=await caller.auth.getUser();if(!user)return response({error:'Invalid session'},401);
 const{data:profile}=await caller.from('profiles').select('platform_role').eq('id',user.id).single();if(profile?.platform_role!=='super_admin')return response({error:'Forbidden'},403);
 const{gameweek_id,admin_override=true}=await req.json().catch(()=>({}));if(!gameweek_id)return response({error:'gameweek_id is required'},400);
 const admin=createClient(url,key);const{data,error}=await admin.rpc('lock_gameweek',{target_gameweek_id:gameweek_id,p_admin_override:admin_override});
 return error?response({error:error.message},400):response({ok:true,snapshot_rows:data});
});

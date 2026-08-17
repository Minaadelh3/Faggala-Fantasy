// supabase/functions/finalize-gameweek/index.ts
//
// Called by a church/platform admin once all match results and
// match_player_stats for a gameweek have been entered. Runs the
// points engine (score players -> roll up team totals -> rank
// leagues) and marks the gameweek as finished.
//
// Deploy:   supabase functions deploy finalize-gameweek
// Invoke:   POST /functions/v1/finalize-gameweek  { "gameweek_id": "<uuid>" }
// Auth:     requires a super_admin's access token (checked below)

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

Deno.serve(async (req) => {
  const corsHeaders = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    'Content-Type': 'application/json',
  };
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (req.method !== 'POST') {
    return new Response(JSON.stringify({ error: 'Method not allowed' }), { status: 405, headers: corsHeaders });
  }

  const authHeader = req.headers.get('Authorization');
  if (!authHeader) {
    return new Response(JSON.stringify({ error: 'Missing Authorization header' }), {
      status: 401, headers: corsHeaders,
    });
  }

  const { gameweek_id } = await req.json().catch(() => ({}));
  if (!gameweek_id) {
    return new Response(JSON.stringify({ error: 'gameweek_id is required' }), { status: 400, headers: corsHeaders });
  }

  // Verify the caller is a signed-in super_admin using their own token
  const callerClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    global: { headers: { Authorization: authHeader } },
  });
  const {
    data: { user },
  } = await callerClient.auth.getUser();

  if (!user) {
    return new Response(JSON.stringify({ error: 'Invalid session' }), { status: 401, headers: corsHeaders });
  }

  const { data: profile } = await callerClient
    .from('profiles')
    .select('platform_role')
    .eq('id', user.id)
    .single();

  if (profile?.platform_role !== 'super_admin') {
    return new Response(JSON.stringify({ error: 'Forbidden — super_admin only' }), {
      status: 403, headers: corsHeaders,
    });
  }

  // Run the pipeline with the service role (bypasses RLS by design —
  // finalize_gameweek() itself is locked to the service_role grantee)
  const adminClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
  const { error } = await adminClient.rpc('finalize_gameweek', {
    target_gameweek_id: gameweek_id,
  });

  if (error) {
    return new Response(JSON.stringify({ error: error.message }), { status: 500, headers: corsHeaders });
  }

  return new Response(JSON.stringify({ ok: true, gameweek_id }), {
    status: 200,
    headers: corsHeaders,
  });
});

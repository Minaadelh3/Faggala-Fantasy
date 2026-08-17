import { createClient } from '@supabase/supabase-js';

const supabaseUrl = import.meta.env.VITE_SUPABASE_URL as string | undefined;
const supabaseAnonKey = import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined;

if (!supabaseUrl || !supabaseAnonKey) {
  // eslint-disable-next-line no-console
  console.warn(
    'Missing VITE_SUPABASE_URL / VITE_SUPABASE_ANON_KEY — set them in .env.local. ' +
      'The UI falls back to mock data (src/data/mock.ts) until then.'
  );
}

export const supabase = createClient(supabaseUrl ?? '', supabaseAnonKey ?? '');

// finalize-gameweek calls the edge function defined in
// supabase/functions/finalize-gameweek/index.ts (super_admin only).
export async function finalizeGameweek(gameweekId: string) {
  const { data, error } = await supabase.functions.invoke('finalize-gameweek', {
    body: { gameweek_id: gameweekId },
  });
  if (error) throw error;
  return data;
}

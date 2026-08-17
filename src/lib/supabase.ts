import { createClient } from '@supabase/supabase-js';

const supabaseUrl = import.meta.env.VITE_SUPABASE_URL as string | undefined;
const supabaseAnonKey = import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined;
export const isSupabaseConfigured = Boolean(supabaseUrl && supabaseAnonKey);
export const supabase = createClient(
  supabaseUrl ?? 'http://127.0.0.1:54321',
  supabaseAnonKey ?? 'missing-anon-key',
  { auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true } },
);

export async function finalizeGameweek(gameweekId: string) {
  const { data, error } = await supabase.functions.invoke('finalize-gameweek', { body: { gameweek_id: gameweekId } });
  if (error) throw error;
  return data;
}
export function messageFromError(error: unknown) { return error instanceof Error ? error.message : 'Something went wrong. Please try again.'; }

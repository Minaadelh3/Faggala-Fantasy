import { createClient } from '@supabase/supabase-js';

const supabaseUrl = (import.meta.env.VITE_SUPABASE_URL as string | undefined)?.trim();
const supabaseAnonKey = (import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined)?.trim();

function validateConfiguration() {
  if (!supabaseUrl || !supabaseAnonKey) {
    return 'Missing Supabase environment variables: VITE_SUPABASE_URL and/or VITE_SUPABASE_ANON_KEY.';
  }
  if (/YOUR_|PLACEHOLDER/i.test(supabaseUrl) || /YOUR_|PLACEHOLDER/i.test(supabaseAnonKey)) {
    return 'Supabase environment variables still contain placeholder values.';
  }
  try {
    const url = new URL(supabaseUrl);
    const isLocal = url.hostname === 'localhost' || url.hostname === '127.0.0.1';
    if ((url.protocol !== 'https:' && !isLocal) || url.username || url.password) {
      return 'VITE_SUPABASE_URL must be a valid HTTPS Supabase project URL.';
    }
  } catch {
    return 'VITE_SUPABASE_URL is not a valid URL.';
  }
  if (/\s/.test(supabaseAnonKey) || supabaseAnonKey.length < 20) {
    return 'VITE_SUPABASE_ANON_KEY is malformed.';
  }
  return null;
}

const configurationError = validateConfiguration();
export const isSupabaseConfigured = configurationError === null;
export const supabaseConfigurationError = import.meta.env.DEV
  ? configurationError
  : configurationError && 'Authentication is temporarily unavailable because the application is not configured.';

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

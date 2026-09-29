import { createClient } from '@supabase/supabase-js'

const configuredUrl = import.meta.env.VITE_SUPABASE_URL
const configuredAnonKey = import.meta.env.VITE_SUPABASE_ANON_KEY
const allowLocalFallback = import.meta.env.DEV || import.meta.env.VITE_ALLOW_LOCAL_SUPABASE === 'true'

if ((!configuredUrl || !configuredAnonKey) && !allowLocalFallback) {
  throw new Error('FieldOne requires VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY in production')
}

export const supabaseUrl = configuredUrl || 'http://127.0.0.1:54321'
export const supabaseAnonKey = configuredAnonKey || 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0'

export const supabase = createClient(supabaseUrl, supabaseAnonKey, {
  auth: {
    persistSession: true,
    autoRefreshToken: true,
    detectSessionInUrl: true,
  },
})

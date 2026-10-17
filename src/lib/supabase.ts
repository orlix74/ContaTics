import { createClient } from '@supabase/supabase-js'

const url = (import.meta.env.VITE_SUPABASE_URL || '').trim()
const key = (import.meta.env.VITE_SUPABASE_ANON_KEY || '').trim()

export const isConfigured =
  url.startsWith('http') && !url.includes('TU-PROYECTO') && key.length > 20 && !key.includes('TU_CLAVE')

export const supabase = createClient(isConfigured ? url : 'https://placeholder.supabase.co', isConfigured ? key : 'placeholder-key', {
  auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true },
})

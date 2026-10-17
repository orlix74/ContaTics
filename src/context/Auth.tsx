import { createContext, useCallback, useContext, useEffect, useMemo, useState, ReactNode } from 'react'
import type { Session } from '@supabase/supabase-js'
import { supabase, isConfigured } from '../lib/supabase'
import { Row, rpc } from '../lib/api'

interface AuthState {
  loading: boolean
  session: Session | null
  profile: Row | null
  orgs: Row[]
  org: Row | null
  role: string | null
  perms: Set<string>
  isPlatformAdmin: boolean
  can: (p: string) => boolean
  selectOrg: (id: string) => void
  reload: () => Promise<void>
  reloadPerms: () => Promise<void>
  signOut: () => Promise<void>
}

const Ctx = createContext<AuthState>(null as any)
export const useAuth = () => useContext(Ctx)
const KEY = 'sc_current_org'

export function AuthProvider({ children }: { children: ReactNode }) {
  const [loading, setLoading] = useState(true)
  const [session, setSession] = useState<Session | null>(null)
  const [profile, setProfile] = useState<Row | null>(null)
  const [orgs, setOrgs] = useState<Row[]>([])
  const [memberships, setMemberships] = useState<Row[]>([])
  const [orgId, setOrgId] = useState<string | null>(() => {
    try { return localStorage.getItem(KEY) } catch { return null }
  })
  const [perms, setPerms] = useState<Set<string>>(new Set())

  const loadUserData = useCallback(async (s: Session | null) => {
    if (!s) { setProfile(null); setOrgs([]); setMemberships([]); setPerms(new Set()); return }
    const [p, o, m] = await Promise.all([
      supabase.from('profiles').select('*').eq('id', s.user.id).maybeSingle(),
      supabase.from('organizations').select('*').order('legal_name'),
      supabase.from('organization_members').select('*').eq('user_id', s.user.id).eq('active', true),
    ])
    setProfile(p.data || null)
    const mine = new Set((m.data || []).map((x: Row) => x.organization_id))
    const list = (o.data || []).filter((x: Row) => mine.has(x.id) && x.active)
    setOrgs(list)
    setMemberships(m.data || [])
    setOrgId((cur) => (cur && list.some((x: Row) => x.id === cur) ? cur : list[0]?.id || null))
  }, [])

  useEffect(() => {
    if (!isConfigured) { setLoading(false); return }
    let alive = true
    supabase.auth.getSession().then(async ({ data }) => {
      if (!alive) return
      setSession(data.session)
      await loadUserData(data.session).catch(() => {})
      if (alive) setLoading(false)
    })
    const { data: sub } = supabase.auth.onAuthStateChange((event, s) => {
      setSession(s)
      if (event === 'SIGNED_IN' || event === 'SIGNED_OUT' || event === 'USER_UPDATED') {
        setTimeout(() => { loadUserData(s).catch(() => {}) }, 0)
      }
    })
    return () => { alive = false; sub.subscription.unsubscribe() }
  }, [loadUserData])

  const reloadPerms = useCallback(async () => {
    if (!orgId || !session) { setPerms(new Set()); return }
    try {
      const p = await rpc<string[]>('my_permissions', { p_org: orgId })
      setPerms(new Set(p || []))
    } catch { setPerms(new Set()) }
  }, [orgId, session])

  useEffect(() => {
    reloadPerms()
    try { if (orgId) localStorage.setItem(KEY, orgId) } catch { /* sin almacenamiento */ }
  }, [orgId, reloadPerms])

  const value = useMemo<AuthState>(() => {
    const org = orgs.find((o) => o.id === orgId) || null
    const role = memberships.find((m) => m.organization_id === orgId)?.role || null
    return {
      loading, session, profile, orgs, org, role, perms,
      isPlatformAdmin: !!profile?.is_platform_admin,
      can: (p: string) => perms.has(p),
      selectOrg: (id: string) => setOrgId(id),
      reload: async () => { await loadUserData(session) },
      reloadPerms,
      signOut: async () => { await supabase.auth.signOut(); setOrgId(null) },
    }
  }, [loading, session, profile, orgs, orgId, memberships, perms, loadUserData, reloadPerms])

  return <Ctx.Provider value={value}>{children}</Ctx.Provider>
}

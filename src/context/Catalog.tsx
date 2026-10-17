import { createContext, useCallback, useContext, useEffect, useState, ReactNode } from 'react'
import { supabase } from '../lib/supabase'
import { Row } from '../lib/api'
import { useAuth } from './Auth'

interface CatalogState {
  accounts: Row[]
  activities: Row[]
  taxes: Row[]
  products: Row[]
  cashAccounts: Row[]
  paymentMethods: Row[]
  currencies: Row[]
  rules: Record<string, string | null>
  settings: Row | null
  baseCurrency: string
  ready: boolean
  reload: () => Promise<void>
  accountLabel: (id?: string | null) => string
}
const Ctx = createContext<CatalogState>(null as any)
export const useCatalog = () => useContext(Ctx)

export function CatalogProvider({ children }: { children: ReactNode }) {
  const { org, session } = useAuth()
  const [st, setSt] = useState<Omit<CatalogState, 'reload' | 'accountLabel' | 'baseCurrency'>>({
    accounts: [], activities: [], taxes: [], products: [], cashAccounts: [], paymentMethods: [], currencies: [], rules: {}, settings: null, ready: false,
  })

  const load = useCallback(async () => {
    if (!org || !session) { setSt((s) => ({ ...s, ready: true })); return }
    const id = org.id
    const [a, ac, t, p, c, pm, cu, r, s] = await Promise.all([
      supabase.from('accounts').select('*').eq('organization_id', id).order('code'),
      supabase.from('activities').select('*').eq('organization_id', id).order('code'),
      supabase.from('tax_types').select('*').eq('organization_id', id).order('code'),
      supabase.from('products').select('*').eq('organization_id', id).order('name'),
      supabase.from('cash_bank_accounts').select('*').eq('organization_id', id).order('name'),
      supabase.from('payment_methods').select('*').eq('organization_id', id).order('name'),
      supabase.from('currencies').select('*').order('code'),
      supabase.from('accounting_rules').select('*').eq('organization_id', id),
      supabase.from('inventory_settings').select('*').eq('organization_id', id).maybeSingle(),
    ])
    const rules: Record<string, string | null> = {}
    ;(r.data || []).forEach((x: Row) => (rules[x.rule_key] = x.account_id))
    setSt({
      accounts: a.data || [], activities: ac.data || [], taxes: t.data || [], products: p.data || [], cashAccounts: c.data || [],
      paymentMethods: pm.data || [], currencies: cu.data || [], rules, settings: s.data || null, ready: true,
    })
  }, [org?.id, session?.user.id])

  useEffect(() => { setSt((s) => ({ ...s, ready: false })); load() }, [load])

  const accountLabel = (id?: string | null) => {
    const a = st.accounts.find((x) => x.id === id)
    return a ? `${a.code} · ${a.name}` : ''
  }
  return <Ctx.Provider value={{ ...st, baseCurrency: org?.base_currency || 'BOB', reload: load, accountLabel }}>{children}</Ctx.Provider>
}

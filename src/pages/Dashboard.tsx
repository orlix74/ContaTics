import { Link } from 'react-router-dom'
import { supabase } from '../lib/supabase'
import { Row, unwrap, DOC_ROUTE, DOC_TYPE_LABEL } from '../lib/api'
import { useAsync } from '../lib/hooks'
import { useAuth } from '../context/Auth'
import { useCatalog } from '../context/Catalog'
import { Alert, Empty, PageHeader, Spinner, Stat } from '../components/ui'
import { fdate, firstOfMonth, money, today, num } from '../lib/format'

export default function Dashboard() {
  const { org, can } = useAuth()
  const { cashAccounts, accounts, baseCurrency, ready } = useCatalog()
  const { data, loading } = useAsync(async () => {
    if (!org) return null
    const id = org.id
    const [pending, ap, ar, per, recent, bal, month] = await Promise.all([
      supabase.from('approval_requests').select('*').eq('organization_id', id).eq('status', 'pending').order('submitted_at', { ascending: false }).limit(8),
      supabase.from('purchase_invoices').select('total_base,paid_base_carried').eq('organization_id', id).eq('status', 'posted'),
      supabase.from('sales_invoices').select('total_base,paid_base_carried').eq('organization_id', id).eq('status', 'posted'),
      supabase.from('accounting_periods').select('*').eq('organization_id', id).lte('start_date', today()).gte('end_date', today()).maybeSingle(),
      supabase.from('journal_entries').select('id,entry_number,entry_date,description,total_debit_base').eq('organization_id', id).eq('status', 'posted').order('posted_at', { ascending: false }).limit(6),
      supabase.rpc('report_account_balances', { p_org: id, p_from: '1900-01-01', p_to: today() }),
      supabase.rpc('report_account_balances', { p_org: id, p_from: firstOfMonth(), p_to: today() }),
    ])
    return { pending: unwrap(pending) as Row[], ap: unwrap(ap) as Row[], ar: unwrap(ar) as Row[], per: per.data as Row | null, recent: unwrap(recent) as Row[], bal: unwrap(bal) as Row[], month: unwrap(month) as Row[] }
  }, [org?.id])

  if (!org) return <Alert kind="info">Seleccione o cree una empresa en la sección <Link to="/empresas">Empresas</Link>.</Alert>
  if (loading || !ready || !data) return <Spinner />
  const sumOut = (rows: Row[]) => rows.reduce((s, r) => s + num(r.total_base) - num(r.paid_base_carried), 0)
  const cashIds = new Set(cashAccounts.map((c) => c.account_id))
  const cash = data.bal.filter((b) => cashIds.has(b.account_id)).reduce((s, b) => s + num(b.opening_debit) + num(b.period_debit) - num(b.opening_credit) - num(b.period_credit), 0)
  const type = (id: string) => accounts.find((a) => a.id === id)?.account_type
  const inc = data.month.filter((b) => type(b.account_id) === 'revenue').reduce((s, b) => s + num(b.period_credit) - num(b.period_debit), 0)
  const exp = data.month.filter((b) => ['expense', 'cost'].includes(type(b.account_id) || '')).reduce((s, b) => s + num(b.period_debit) - num(b.period_credit), 0)

  return (
    <>
      <PageHeader title={org.trade_name || org.legal_name} sub={`Panel de control · cifras en ${baseCurrency}`} />
      {!data.per && <Alert kind="warn">No existe un periodo contable para hoy. Cree los periodos en <Link to="/configuracion/periodos">Configuración › Periodos</Link> antes de registrar documentos.</Alert>}
      {data.per?.status === 'closed' && <Alert kind="warn">El periodo de hoy ({data.per.name}) está cerrado.</Alert>}
      <div className="grid g4" style={{ margin: '14px 0' }}>
        <Stat k="Caja y bancos" v={money(cash)} />
        <Stat k="Por cobrar" v={money(sumOut(data.ar))} />
        <Stat k="Por pagar" v={money(sumOut(data.ap))} />
        <Stat k="Resultado del mes" v={money(inc - exp)} tone={inc - exp >= 0 ? 'ok' : 'err'} />
      </div>
      <div className="grid g2">
        <div className="card card-pad">
          <h3>Pendientes de aprobación {data.pending.length > 0 && <span className="badge b-pending_approval">{data.pending.length}</span>}</h3>
          {data.pending.length === 0 ? <Empty>No hay documentos esperando aprobación.</Empty> : (
            <ul className="timeline">{data.pending.map((r) => (
              <li key={r.id}><Link to={`${DOC_ROUTE[r.doc_type]}/${r.doc_id}`}>{DOC_TYPE_LABEL[r.doc_type]}</Link> — {r.doc_label}<div className="muted small">{fdate(r.submitted_at)}</div></li>
            ))}</ul>
          )}
          {can('documents.approve') && <div style={{ marginTop: 10 }}><Link to="/aprobaciones/bandeja">Abrir bandeja de aprobaciones →</Link></div>}
        </div>
        <div className="card card-pad">
          <h3>Últimos asientos contabilizados</h3>
          {data.recent.length === 0 ? <Empty>Todavía no hay asientos contabilizados.</Empty> : (
            <table className="t"><tbody>{data.recent.map((r) => (
              <tr key={r.id}><td className="nowrap"><Link to={`/contabilidad/asientos/${r.id}`}>N.º {r.entry_number}</Link></td><td className="muted nowrap">{fdate(r.entry_date)}</td><td>{r.description}</td><td className="num">{money(r.total_debit_base)}</td></tr>
            ))}</tbody></table>
          )}
        </div>
      </div>
    </>
  )
}

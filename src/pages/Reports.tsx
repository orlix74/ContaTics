import { ReactNode, useEffect, useMemo, useState } from 'react'
import { Link, useSearchParams } from 'react-router-dom'
import { supabase } from '../lib/supabase'
import { Row, errMsg, rpc, unwrap } from '../lib/api'
import { useAsync } from '../lib/hooks'
import { useAuth } from '../context/Auth'
import { useCatalog } from '../context/Catalog'
import { useToast } from '../context/Toast'
import { Alert, Empty, Field, NoAccess, PageHeader, Spinner } from '../components/ui'
import { ReportCol, ReportMeta, exportExcel, exportPdf } from '../lib/export'
import { daysBetween, fdate, firstOfYear, money, num, qty, round2, today } from '../lib/format'

type R = Record<string, any>

/* ---------- utilidades comunes ---------- */
async function fetchAll(build: (from: number, to: number) => PromiseLike<{ data: any; error: any }>): Promise<Row[]> {
  const out: Row[] = []
  for (let i = 0; ; i += 1000) {
    const page = unwrap(await build(i, i + 999)) as Row[]
    out.push(...page)
    if (page.length < 1000) break
  }
  return out
}
function useMeta(title: string, period?: string, filters?: string[]): ReportMeta {
  const { org } = useAuth()
  const { baseCurrency } = useCatalog()
  return { title, company: org?.legal_name || '', taxId: org?.tax_id, period, currency: baseCurrency, filters }
}
function cellText(c: ReportCol, v: any): ReactNode {
  if (v === null || v === undefined || v === '') return ''
  if (c.type === 'money') return money(v)
  if (c.type === 'qty') return qty(v)
  if (c.type === 'date') return fdate(v)
  return v
}
function ReportTable({ cols, rows, totals, meta, empty = 'Sin datos para los filtros elegidos.' }: { cols: ReportCol[]; rows: R[]; totals?: R; meta: ReportMeta; empty?: string }) {
  const { can } = useAuth()
  const toast = useToast()
  const exp = async (kind: 'x' | 'p') => { try { if (kind === 'x') await exportExcel(meta, cols, rows, totals); else exportPdf(meta, cols, rows, totals) } catch (e) { toast.err(errMsg(e)) } }
  return (
    <div className="card">
      {can('reports.export') && rows.length > 0 && <div className="card-pad row"><button className="btn sm" onClick={() => exp('x')}>⬇ Excel</button><button className="btn sm" onClick={() => exp('p')}>⬇ PDF</button></div>}
      <div className="table-wrap">
        {!rows.length ? <Empty>{empty}</Empty> : (
          <table className="t">
            <thead><tr>{cols.map((c) => <th key={c.key} className={c.type === 'money' || c.type === 'qty' ? 'r' : ''}>{c.label}</th>)}</tr></thead>
            <tbody>{rows.map((r, i) => (
              <tr key={i} style={r._bold ? { fontWeight: 700, background: 'var(--bg-soft, #f6f7fb)' } : undefined}>
                {cols.map((c, j) => <td key={c.key} className={c.type === 'money' || c.type === 'qty' ? 'num' : ''} style={j === 0 && r._indent ? { paddingLeft: 12 + r._indent * 18 } : undefined}>{r._link && j === 0 ? <Link to={r._link}>{cellText(c, r[c.key])}</Link> : cellText(c, r[c.key])}</td>)}
              </tr>))}</tbody>
            {totals && <tfoot><tr>{cols.map((c, j) => <td key={c.key} className={c.type === 'money' || c.type === 'qty' ? 'num' : ''}><b>{totals[c.key] !== undefined && totals[c.key] !== '' ? cellText(c, totals[c.key]) : j === 0 ? 'TOTALES' : ''}</b></td>)}</tr></tfoot>}
          </table>)}
      </div>
    </div>
  )
}
function DateRange({ from, to, setFrom, setTo, single }: { from: string; to: string; setFrom: (v: string) => void; setTo: (v: string) => void; single?: boolean }) {
  return (<>{!single && <Field label="Desde"><input type="date" value={from} onChange={(e) => setFrom(e.target.value)} /></Field>}<Field label={single ? 'Al día' : 'Hasta'}><input type="date" value={to} onChange={(e) => setTo(e.target.value)} /></Field></>)
}
const useBalances = (from: string, to: string) => {
  const { org } = useAuth()
  return useAsync(async () => (from && to ? (unwrap(await supabase.rpc('report_account_balances', { p_org: org!.id, p_from: from, p_to: to })) as Row[]) : []), [org?.id, from, to], [])
}
const typeLabel: Record<string, string> = { asset: 'Activo', liability: 'Pasivo', equity: 'Patrimonio', revenue: 'Ingreso', cost: 'Costo', expense: 'Gasto' }

/* ---------- Balanza de comprobación ---------- */
export function TrialBalance() {
  const { can } = useAuth()
  const { accounts, activities } = useCatalog()
  const [from, setFrom] = useState(firstOfYear())
  const [to, setTo] = useState(today())
  const [act, setAct] = useState('')
  const [level, setLevel] = useState('all')
  const { data, loading } = useBalances(from, to)
  const meta = useMeta('Balanza de comprobación', `${fdate(from)} al ${fdate(to)}`, act ? [`Actividad: ${activities.find((a) => a.id === act)?.name}`] : undefined)
  const { rows, totals } = useMemo(() => {
    const agg: Record<string, R> = {}
    for (const b of data || []) {
      if (act && b.activity_id !== act) continue
      const a = (agg[b.account_id] ||= { od: 0, oc: 0, pd: 0, pc: 0 })
      a.od += num(b.opening_debit); a.oc += num(b.opening_credit); a.pd += num(b.period_debit); a.pc += num(b.period_credit)
    }
    const out: R[] = []
    for (const a of accounts) {
      const v = agg[a.id]
      if (!v || !a.is_postable && level === 'post') continue
      const open = round2(v.od - v.oc), close = round2(open + v.pd - v.pc)
      if (!open && !v.pd && !v.pc) continue
      out.push({ code: a.code, name: a.name, odeb: open > 0 ? open : 0, ocre: open < 0 ? -open : 0, pdeb: round2(v.pd), pcre: round2(v.pc), cdeb: close > 0 ? close : 0, ccre: close < 0 ? -close : 0, _link: `/reportes/libro-mayor?cuenta=${a.id}` })
    }
    out.sort((x, y) => x.code.localeCompare(y.code))
    const t: R = { code: '', name: '' }
    for (const k of ['odeb', 'ocre', 'pdeb', 'pcre', 'cdeb', 'ccre']) t[k] = round2(out.reduce((s, r) => s + r[k], 0))
    return { rows: out, totals: t }
  }, [data, accounts, act, level])
  if (!can('data.view')) return <NoAccess perm="data.view" />
  const cols: ReportCol[] = [{ key: 'code', label: 'Código' }, { key: 'name', label: 'Cuenta' }, { key: 'odeb', label: 'Saldo inicial deudor', type: 'money' }, { key: 'ocre', label: 'Saldo inicial acreedor', type: 'money' }, { key: 'pdeb', label: 'Débitos del periodo', type: 'money' }, { key: 'pcre', label: 'Créditos del periodo', type: 'money' }, { key: 'cdeb', label: 'Saldo final deudor', type: 'money' }, { key: 'ccre', label: 'Saldo final acreedor', type: 'money' }]
  const ok = round2(totals.cdeb - totals.ccre) === 0 && round2(totals.pdeb - totals.pcre) === 0
  return (
    <>
      <PageHeader title="Balanza de comprobación" sub="Solo asientos contabilizados. Haga clic en un código para ver el libro mayor de la cuenta." />
      <div className="card card-pad grid g4"><DateRange {...{ from, to, setFrom, setTo }} />
        <Field label="Actividad"><select value={act} onChange={(e) => setAct(e.target.value)}><option value="">Todas</option>{activities.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name}</option>)}</select></Field></div>
      {loading ? <Spinner /> : (<>
        {rows.length > 0 && (ok ? <Alert kind="ok">La balanza cuadra: débitos = créditos.</Alert> : <Alert kind="err">La balanza no cuadra{act ? ' (normal al filtrar por actividad: un asiento puede repartirse en varias actividades)' : ': revise los asientos'}.</Alert>)}
        <ReportTable cols={cols} rows={rows} totals={totals} meta={meta} /></>)}
    </>
  )
}

/* ---------- Estados financieros configurables ---------- */
function evalFormula(f: string, get: (code: string) => number): number {
  const tk = f.match(/[A-Za-z0-9_.]+|[()+\-*/]/g) || []
  let p = 0
  const peek = () => tk[p]
  const expr = (): number => { let v = term(); while (peek() === '+' || peek() === '-') { const o = tk[p++]; const r = term(); v = o === '+' ? v + r : v - r } return v }
  const term = (): number => { let v = factor(); while (peek() === '*' || peek() === '/') { const o = tk[p++]; const r = factor(); v = o === '*' ? v * r : r === 0 ? 0 : v / r } return v }
  const factor = (): number => {
    const t = tk[p++]
    if (t === undefined) throw new Error('Fórmula incompleta')
    if (t === '(') { const v = expr(); if (tk[p++] !== ')') throw new Error('Falta cerrar paréntesis'); return v }
    if (t === '-') return -factor()
    if (t === '+') return factor()
    if (/^\d+(\.\d+)?$/.test(t)) return parseFloat(t)
    return get(t)
  }
  const v = expr()
  if (p < tk.length) throw new Error(`Texto inesperado “${tk[p]}”`)
  return v
}

export function FinancialStatement({ kind }: { kind: 'balance' | 'income' }) {
  const { org, can } = useAuth()
  const { accounts } = useCatalog()
  const isBal = kind === 'balance'
  const [from, setFrom] = useState(firstOfYear())
  const [to, setTo] = useState(today())
  const [tid, setTid] = useState('')
  const { data: tpls } = useAsync(async () => unwrap(await supabase.from('financial_statement_templates').select('*').eq('organization_id', org!.id).eq('kind', kind).eq('active', true).order('name')) as Row[], [org?.id, kind], [])
  useEffect(() => { if (tpls?.length && !tpls.some((t) => t.id === tid)) setTid(tpls[0].id) }, [tpls])
  const { data: tpl } = useAsync(async () => {
    if (!tid) return null
    const rows = unwrap(await supabase.from('financial_statement_rows').select('*').eq('template_id', tid).order('sort_order')) as Row[]
    const maps = rows.length ? (unwrap(await supabase.from('financial_statement_mappings').select('*').in('row_id', rows.map((r) => r.id))) as Row[]) : []
    return { rows, maps }
  }, [tid], null)
  const { data: bal, loading } = useBalances(isBal ? '1900-01-01' : from, to)
  const title = isBal ? 'Estado de situación financiera' : 'Estado de resultados'
  const meta = useMeta(title, isBal ? `Al ${fdate(to)}` : `${fdate(from)} al ${fdate(to)}`)

  const calc = useMemo(() => {
    if (!tpl || !bal) return null
    const net: Record<string, number> = {}
    for (const b of bal) net[b.account_id] = (net[b.account_id] || 0) + (isBal ? num(b.opening_debit) - num(b.opening_credit) : 0) + num(b.period_debit) - num(b.period_credit)
    const kids: Record<string, string[]> = {}
    accounts.forEach((a) => { if (a.parent_id) (kids[a.parent_id] ||= []).push(a.id) })
    const expand = (id: string, acc: Set<string>) => { acc.add(id); (kids[id] || []).forEach((k) => expand(k, acc)) }
    const warnings: string[] = []
    const val: Record<string, number> = {}
    const rowByCode: Record<string, Row> = {}
    tpl.rows.forEach((r) => (rowByCode[r.code] = r))
    const covered: Record<string, number> = {}
    for (const r of tpl.rows) {
      if (r.row_type !== 'accounts') continue
      const set = new Set<string>()
      tpl.maps.filter((m) => m.row_id === r.id).forEach((m) => (m.include_descendants ? expand(m.account_id, set) : set.add(m.account_id)))
      let s = 0
      set.forEach((id) => { const a = accounts.find((x) => x.id === id); if (a && a.is_postable) { s += net[id] || 0; covered[id] = (covered[id] || 0) + 1 } })
      val[r.code] = round2(s * r.sign)
    }
    const visiting = new Set<string>()
    const get = (code: string): number => {
      if (code in val) return val[code]
      const r = rowByCode[code]
      if (!r) throw new Error(`La fila “${code}” no existe`)
      if (visiting.has(code)) throw new Error(`Fórmula circular en “${code}”`)
      visiting.add(code)
      const v = r.row_type === 'subtotal' && r.formula ? round2(evalFormula(r.formula, get) * r.sign) : 0
      visiting.delete(code); val[code] = v; return v
    }
    const out: R[] = []
    const relevantTypes = isBal ? ['asset', 'liability', 'equity'] : ['revenue', 'cost', 'expense']
    for (const r of tpl.rows) {
      try { get(r.code) } catch (e) { warnings.push(`Fila ${r.code}: ${errMsg(e)}`) }
      out.push({ label: r.label, amount: r.row_type === 'header' ? '' : val[r.code] ?? 0, _bold: r.row_type !== 'accounts', _indent: r.indent })
    }
    const unmapped = accounts.filter((a) => a.is_postable && relevantTypes.includes(a.account_type) && round2(net[a.id] || 0) !== 0 && !covered[a.id])
    if (unmapped.length) warnings.push(`Cuentas con saldo que no están en ninguna fila de la plantilla: ${unmapped.slice(0, 6).map((a) => a.code).join(', ')}${unmapped.length > 6 ? '…' : ''}. Los totales no las incluyen.`)
    const dup = Object.entries(covered).filter(([, n]) => n > 1)
    if (dup.length) warnings.push(`Hay ${dup.length} cuenta(s) incluidas en más de una fila (posible doble conteo).`)
    return { out, warnings }
  }, [tpl, bal, accounts, isBal])

  if (!can('data.view')) return <NoAccess perm="data.view" />
  const cols: ReportCol[] = [{ key: 'label', label: 'Concepto' }, { key: 'amount', label: `Importe (${meta.currency})`, type: 'money' }]
  return (
    <>
      <PageHeader title={title} sub={<>Calculado desde los asientos contabilizados con la plantilla elegida. Las plantillas se editan en <Link to="/configuracion/estados-financieros">Configuración</Link>.</>} />
      <div className="card card-pad grid g4">
        <Field label="Plantilla"><select value={tid} onChange={(e) => setTid(e.target.value)}>{tpls?.map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}</select></Field>
        <DateRange {...{ from, to, setFrom, setTo }} single={isBal} />
      </div>
      {!tpls?.length ? <Alert kind="warn">No hay plantillas activas de este tipo.</Alert> : loading || !calc ? <Spinner /> : (<>
        {calc.warnings.map((w, i) => <Alert key={i} kind="warn">{w}</Alert>)}
        <ReportTable cols={cols} rows={calc.out} meta={meta} />
      </>)}
    </>
  )
}
export const BalanceSheet = () => <FinancialStatement kind="balance" />
export const IncomeStatement = () => <FinancialStatement kind="income" />

/* ---------- Libro diario ---------- */
export function JournalBook() {
  const { org, can } = useAuth()
  const { accounts, activities } = useCatalog()
  const [from, setFrom] = useState(firstOfYear())
  const [to, setTo] = useState(today())
  const { data, loading } = useAsync(async () => fetchAll((a, b) => supabase.from('journal_entry_lines').select('debit_base,credit_base,description,account_id,activity_id,line_no,journal_entries!inner(id,entry_number,entry_date,description,reference,status)').eq('organization_id', org!.id).eq('journal_entries.status', 'posted').gte('journal_entries.entry_date', from).lte('journal_entries.entry_date', to).range(a, b)), [org?.id, from, to], [])
  const meta = useMeta('Libro diario', `${fdate(from)} al ${fdate(to)}`)
  const rows = useMemo(() => (data || []).map((l) => ({ ...l, e: l.journal_entries })).sort((x, y) => x.e.entry_date.localeCompare(y.e.entry_date) || x.e.entry_number - y.e.entry_number || x.line_no - y.line_no).map((l) => {
    const a = accounts.find((x) => x.id === l.account_id)
    return { date: l.e.entry_date, num: l.e.entry_number, code: a?.code, name: a?.name, act: activities.find((x) => x.id === l.activity_id)?.code || '', desc: l.description || l.e.description, debit: num(l.debit_base), credit: num(l.credit_base), _link: `/contabilidad/asientos/${l.e.id}` }
  }), [data, accounts, activities])
  if (!can('data.view')) return <NoAccess perm="data.view" />
  const cols: ReportCol[] = [{ key: 'date', label: 'Fecha', type: 'date' }, { key: 'num', label: 'Asiento' }, { key: 'code', label: 'Cuenta' }, { key: 'name', label: 'Nombre de cuenta' }, { key: 'act', label: 'Act.' }, { key: 'desc', label: 'Descripción' }, { key: 'debit', label: 'Debe', type: 'money' }, { key: 'credit', label: 'Haber', type: 'money' }]
  const totals = { debit: round2(rows.reduce((s, r) => s + r.debit, 0)), credit: round2(rows.reduce((s, r) => s + r.credit, 0)) }
  return (
    <>
      <PageHeader title="Libro diario" sub="Todas las líneas de asientos contabilizados, en orden cronológico." />
      <div className="card card-pad grid g4"><DateRange {...{ from, to, setFrom, setTo }} /></div>
      {loading ? <Spinner /> : <ReportTable cols={cols} rows={rows} totals={totals} meta={meta} />}
    </>
  )
}

/* ---------- Libro mayor ---------- */
export function Ledger() {
  const { org, can } = useAuth()
  const { accounts } = useCatalog()
  const [sp, setSp] = useSearchParams()
  const [acc, setAcc] = useState(sp.get('cuenta') || '')
  const [from, setFrom] = useState(firstOfYear())
  const [to, setTo] = useState(today())
  const account = accounts.find((a) => a.id === acc)
  const { data, loading } = useAsync(async () => {
    if (!acc) return null
    const open = unwrap(await supabase.rpc('report_account_balances', { p_org: org!.id, p_from: from, p_to: to })) as Row[]
    const lines = await fetchAll((a, b) => supabase.from('journal_entry_lines').select('debit_base,credit_base,description,line_no,journal_entries!inner(id,entry_number,entry_date,description,reference,status)').eq('organization_id', org!.id).eq('account_id', acc).eq('journal_entries.status', 'posted').gte('journal_entries.entry_date', from).lte('journal_entries.entry_date', to).range(a, b))
    const o = open.filter((x) => x.account_id === acc).reduce((s, x) => s + num(x.opening_debit) - num(x.opening_credit), 0)
    return { opening: round2(o), lines }
  }, [org?.id, acc, from, to], null)
  const meta = useMeta('Libro mayor', `${fdate(from)} al ${fdate(to)}`, account ? [`Cuenta: ${account.code} ${account.name}`] : undefined)
  const rows = useMemo(() => {
    if (!data) return []
    const nat = account?.nature === 'credit' ? -1 : 1
    let run = data.opening
    const out: R[] = [{ date: from, num: '', desc: 'Saldo inicial', debit: '', credit: '', balance: round2(run * nat), _bold: true }]
    data.lines.map((l) => ({ ...l, e: l.journal_entries })).sort((x, y) => x.e.entry_date.localeCompare(y.e.entry_date) || x.e.entry_number - y.e.entry_number || x.line_no - y.line_no).forEach((l) => {
      run = round2(run + num(l.debit_base) - num(l.credit_base))
      out.push({ date: l.e.entry_date, num: l.e.entry_number, desc: l.description || l.e.description, debit: num(l.debit_base), credit: num(l.credit_base), balance: round2(run * nat), _link: `/contabilidad/asientos/${l.e.id}` })
    })
    return out
  }, [data, account, from])
  if (!can('data.view')) return <NoAccess perm="data.view" />
  const cols: ReportCol[] = [{ key: 'date', label: 'Fecha', type: 'date' }, { key: 'num', label: 'Asiento' }, { key: 'desc', label: 'Descripción' }, { key: 'debit', label: 'Debe', type: 'money' }, { key: 'credit', label: 'Haber', type: 'money' }, { key: 'balance', label: 'Saldo', type: 'money' }]
  const totals = { debit: round2(rows.reduce((s, r) => s + num(r.debit), 0)), credit: round2(rows.reduce((s, r) => s + num(r.credit), 0)), balance: rows.length ? rows[rows.length - 1].balance : 0 }
  return (
    <>
      <PageHeader title="Libro mayor" sub="Movimientos y saldo corrido de una cuenta. El saldo se muestra según la naturaleza de la cuenta." />
      <div className="card card-pad grid g4">
        <Field label="Cuenta"><select value={acc} onChange={(e) => { setAcc(e.target.value); setSp(e.target.value ? { cuenta: e.target.value } : {}) }}><option value="">— Seleccione —</option>{accounts.filter((a) => a.is_postable).map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name}</option>)}</select></Field>
        <DateRange {...{ from, to, setFrom, setTo }} />
      </div>
      {!acc ? <Empty>Seleccione una cuenta.</Empty> : loading ? <Spinner /> : <ReportTable cols={cols} rows={rows} totals={totals} meta={meta} />}
    </>
  )
}

/* ---------- Antigüedad de saldos ---------- */
function Aging({ kind }: { kind: 'ar' | 'ap' }) {
  const { org, can } = useAuth()
  const [asOf, setAsOf] = useState(today())
  const ar = kind === 'ar'
  const { data, loading } = useAsync(async () => {
    const table = ar ? 'sales_invoices' : 'purchase_invoices'
    const party = ar ? 'customers(name)' : 'suppliers(name)'
    return fetchAll((a, b) => supabase.from(table).select(`id,doc_number,${ar ? 'invoice_number' : 'supplier_doc_number'},issue_date,due_date,currency_code,total,paid_amount,total_base,paid_base_carried,${party}`).eq('organization_id', org!.id).eq('status', 'posted').range(a, b))
  }, [org?.id, kind], [])
  const title = ar ? 'Cuentas por cobrar — antigüedad de saldos' : 'Cuentas por pagar — antigüedad de saldos'
  const meta = useMeta(title, `Al ${fdate(asOf)}`)
  const rows: R[] = useMemo(() => (data || []).filter((i) => round2(num(i.total) - num(i.paid_amount)) > 0 && i.issue_date <= asOf).map((i) => {
    const bal = round2(num(i.total) - num(i.paid_amount))
    const balBase = round2(num(i.total_base) - num(i.paid_base_carried))
    const late = daysBetween(i.due_date || i.issue_date, asOf)
    const b = late <= 0 ? 'b0' : late <= 30 ? 'b1' : late <= 60 ? 'b2' : late <= 90 ? 'b3' : 'b4'
    return { party: (ar ? i.customers : i.suppliers)?.name, doc: i.doc_number, ref: ar ? i.invoice_number : i.supplier_doc_number, issue: i.issue_date, due: i.due_date, cur: i.currency_code, total: num(i.total), bal, base: balBase, late: Math.max(late, 0), b0: b === 'b0' ? balBase : 0, b1: b === 'b1' ? balBase : 0, b2: b === 'b2' ? balBase : 0, b3: b === 'b3' ? balBase : 0, b4: b === 'b4' ? balBase : 0, _link: `${ar ? '/ventas' : '/compras'}/facturas/${i.id}` }
  }).sort((x, y) => (x.party || '').localeCompare(y.party || '') || (x.due || '').localeCompare(y.due || '')), [data, asOf, ar])
  if (!can('data.view')) return <NoAccess perm="data.view" />
  const cols: ReportCol[] = [{ key: 'party', label: ar ? 'Cliente' : 'Proveedor' }, { key: 'doc', label: 'N.º interno' }, { key: 'ref', label: ar ? 'Factura' : 'Factura proveedor' }, { key: 'due', label: 'Vence', type: 'date' }, { key: 'cur', label: 'Moneda' }, { key: 'bal', label: 'Saldo en su moneda', type: 'money' }, { key: 'late', label: 'Días de mora' }, { key: 'b0', label: 'Vigente', type: 'money' }, { key: 'b1', label: '1–30', type: 'money' }, { key: 'b2', label: '31–60', type: 'money' }, { key: 'b3', label: '61–90', type: 'money' }, { key: 'b4', label: '+90', type: 'money' }, { key: 'base', label: `Total (${meta.currency})`, type: 'money' }]
  const totals: R = { }
  ;['b0', 'b1', 'b2', 'b3', 'b4', 'base'].forEach((k) => (totals[k] = round2(rows.reduce((s, r) => s + r[k], 0))))
  return (
    <>
      <PageHeader title={title} sub="Facturas contabilizadas con saldo pendiente. Los tramos se calculan por días vencidos y se expresan en moneda base." />
      <div className="card card-pad grid g4"><DateRange {...{ from: '', to: asOf, setFrom: () => {}, setTo: setAsOf }} single /></div>
      {loading ? <Spinner /> : <ReportTable cols={cols} rows={rows} totals={totals} meta={meta} empty="No hay saldos pendientes." />}
    </>
  )
}
export const Receivables = () => <Aging kind="ar" />
export const Payables = () => <Aging kind="ap" />

/* ---------- Inventarios ---------- */
export function InventoryReport() {
  const { org, can } = useAuth()
  const { baseCurrency } = useCatalog()
  const { data, loading } = useAsync(async () => {
    const p = unwrap(await supabase.from('products').select('sku,name,unit,category,qty_on_hand,avg_cost,inventory_value,active').eq('organization_id', org!.id).eq('product_type', 'inventory').order('sku')) as Row[]
    const c = unwrap(await supabase.rpc('report_inventory_vs_ledger', { p_org: org!.id })) as Row[]
    return { p, c: c[0] }
  }, [org?.id], null)
  const meta = useMeta('Inventario valorado', `Al ${fdate(today())}`)
  if (!can('data.view')) return <NoAccess perm="data.view" />
  const rows = (data?.p || []).filter((p) => num(p.qty_on_hand) !== 0 || num(p.inventory_value) !== 0).map((p) => ({ sku: p.sku, name: p.name, unit: p.unit, category: p.category, q: num(p.qty_on_hand), cost: num(p.avg_cost), value: num(p.inventory_value) }))
  const cols: ReportCol[] = [{ key: 'sku', label: 'Código' }, { key: 'name', label: 'Producto' }, { key: 'category', label: 'Categoría' }, { key: 'unit', label: 'Unidad' }, { key: 'q', label: 'Existencia', type: 'qty' }, { key: 'cost', label: 'Costo promedio', type: 'qty' }, { key: 'value', label: `Valor (${baseCurrency})`, type: 'money' }]
  const diff = data?.c ? round2(num(data.c.inventory_value) - num(data.c.ledger_balance)) : 0
  return (
    <>
      <PageHeader title="Inventario valorado y conciliación con contabilidad" sub="Existencias y valor según el método de valoración configurado, comparados con el saldo contable de las cuentas de inventario." />
      {loading || !data ? <Spinner /> : (<>
        <div className="grid g3">
          <div className="card stat"><div className="k">Valor del inventario (auxiliar)</div><div className="v">{money(data.c?.inventory_value)}</div></div>
          <div className="card stat"><div className="k">Saldo contable de inventarios</div><div className="v">{money(data.c?.ledger_balance)}</div></div>
          <div className="card stat"><div className="k">Diferencia</div><div className="v" style={{ color: diff === 0 ? 'var(--ok)' : 'var(--err)' }}>{money(diff)}</div></div>
        </div>
        {diff !== 0 && <Alert kind="warn">El auxiliar de inventario no coincide con la contabilidad. Revise asientos manuales a cuentas de inventario o documentos pendientes de contabilizar.</Alert>}
        <ReportTable cols={cols} rows={rows} totals={{ value: round2(rows.reduce((s, r) => s + r.value, 0)) }} meta={meta} />
      </>)}
    </>
  )
}

/* ---------- Conciliaciones ---------- */
export function ReconciliationsReport() {
  const { org, can } = useAuth()
  const { data, loading } = useAsync(async () => unwrap(await supabase.from('bank_reconciliations').select('*, cash_bank_accounts(name,currency_code)').eq('organization_id', org!.id).order('period_to', { ascending: false })) as Row[], [org?.id], [])
  const meta = useMeta('Resumen de conciliaciones bancarias')
  if (!can('data.view')) return <NoAccess perm="data.view" />
  const st: Record<string, string> = { draft: 'Borrador', pending_approval: 'Pendiente de aprobación', rejected: 'Rechazada', approved: 'Aprobada', posted: 'Cerrada', voided: 'Anulada' }
  const rows = (data || []).map((r) => ({ num: r.doc_number, acc: r.cash_bank_accounts?.name, cur: r.cash_bank_accounts?.currency_code, from: r.period_from, to: r.period_to, bal: num(r.statement_balance), st: st[r.status] || r.status, _link: `/tesoreria/conciliaciones/${r.id}` }))
  const cols: ReportCol[] = [{ key: 'num', label: 'N.º' }, { key: 'acc', label: 'Cuenta' }, { key: 'cur', label: 'Moneda' }, { key: 'from', label: 'Desde', type: 'date' }, { key: 'to', label: 'Hasta', type: 'date' }, { key: 'bal', label: 'Saldo extracto', type: 'money' }, { key: 'st', label: 'Estado' }]
  return (<><PageHeader title="Conciliaciones bancarias" sub="Historial y estado de cada conciliación." />{loading ? <Spinner /> : <ReportTable cols={cols} rows={rows} meta={meta} empty="No hay conciliaciones." />}</>)
}

/* ---------- Resultados por actividad ---------- */
export function ByActivity() {
  const { can } = useAuth()
  const { accounts, activities } = useCatalog()
  const [from, setFrom] = useState(firstOfYear())
  const [to, setTo] = useState(today())
  const { data, loading } = useBalances(from, to)
  const meta = useMeta('Resultados por actividad', `${fdate(from)} al ${fdate(to)}`)
  const rows = useMemo(() => {
    const acts = [...activities, { id: null, code: '—', name: 'Sin actividad asignada' }]
    const out: R[] = []
    for (const a of acts) {
      const sums = { revenue: 0, cost: 0, expense: 0 } as Record<string, number>
      for (const b of data || []) {
        if ((b.activity_id || null) !== a.id) continue
        const ac = accounts.find((x) => x.id === b.account_id)
        if (!ac || !(ac.account_type in sums)) continue
        const n = num(b.period_debit) - num(b.period_credit)
        sums[ac.account_type] += ac.account_type === 'revenue' ? -n : n
      }
      if (!sums.revenue && !sums.cost && !sums.expense) continue
      const gross = round2(sums.revenue - sums.cost), net = round2(gross - sums.expense)
      out.push({ act: `${a.code} · ${a.name}`, rev: round2(sums.revenue), cost: round2(sums.cost), gross, exp: round2(sums.expense), net, margin: sums.revenue ? `${((net / sums.revenue) * 100).toFixed(1)} %` : '' })
    }
    return out
  }, [data, accounts, activities])
  if (!can('data.view')) return <NoAccess perm="data.view" />
  const cols: ReportCol[] = [{ key: 'act', label: 'Actividad' }, { key: 'rev', label: 'Ingresos', type: 'money' }, { key: 'cost', label: 'Costos', type: 'money' }, { key: 'gross', label: 'Utilidad bruta', type: 'money' }, { key: 'exp', label: 'Gastos', type: 'money' }, { key: 'net', label: 'Resultado', type: 'money' }, { key: 'margin', label: 'Margen' }]
  const totals: R = {}
  ;['rev', 'cost', 'gross', 'exp', 'net'].forEach((k) => (totals[k] = round2(rows.reduce((s, r) => s + r[k], 0))))
  return (
    <>
      <PageHeader title="Resultados por actividad" sub="Ingresos, costos y gastos contabilizados, agrupados por la actividad asignada en cada línea." />
      <div className="card card-pad grid g4"><DateRange {...{ from, to, setFrom, setTo }} /></div>
      {loading ? <Spinner /> : <ReportTable cols={cols} rows={rows} totals={totals} meta={meta} />}
    </>
  )
}

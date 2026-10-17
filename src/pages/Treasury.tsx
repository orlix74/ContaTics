import { useEffect, useMemo, useState } from 'react'
import { Link, useNavigate, useParams } from 'react-router-dom'
import Papa from 'papaparse'
import { readSheet } from 'read-excel-file/browser'
import { supabase } from '../lib/supabase'
import { Row, errMsg, rpc, unwrap } from '../lib/api'
import { useAsync } from '../lib/hooks'
import { useAuth } from '../context/Auth'
import { useCatalog } from '../context/Catalog'
import { useToast } from '../context/Toast'
import CrudPage from '../components/CrudPage'
import { DocFrame, DocList, isEditable } from '../components/DocParts'
import { Alert, Empty, Field, Modal, NoAccess, PageHeader, Spinner } from '../components/ui'
import { daysBetween, fdate, money, num, round2, sha256, today, firstOfMonth } from '../lib/format'
import { useRateSync } from './Invoices'

/* ---------------- Cuentas de caja y bancos ---------------- */
export function CashAccounts() {
  const { accounts, currencies, reload } = useCatalog()
  return (
    <CrudPage table="cash_bank_accounts" title="Cajas y bancos" orderBy="name" writePerm="masters.manage" onChanged={reload} newLabel="Cuenta"
      sub="Cada caja o cuenta bancaria se asocia a una cuenta contable y a una moneda. No se pueden cambiar después de registrar movimientos."
      fields={[
        { key: 'name', label: 'Nombre', required: true }, { key: 'kind', label: 'Tipo', type: 'select', required: true, default: 'bank', options: [{ value: 'cash', label: 'Caja' }, { value: 'bank', label: 'Cuenta bancaria' }] },
        { key: 'bank_name', label: 'Banco', show: (f) => f.kind === 'bank' }, { key: 'account_number', label: 'N.º de cuenta', show: (f) => f.kind === 'bank' },
        { key: 'currency_code', label: 'Moneda', type: 'select', required: true, lockOnEdit: true, options: currencies.map((c) => ({ value: c.code, label: `${c.code} — ${c.name}` })) },
        { key: 'account_id', label: 'Cuenta contable', type: 'select', required: true, lockOnEdit: true, options: accounts.filter((a) => a.is_postable && a.active && a.account_type === 'asset').map((a) => ({ value: a.id, label: `${a.code} · ${a.name}` })) },
        { key: 'active', label: 'Activa', type: 'checkbox', default: true },
      ]}
      columns={[{ label: 'Nombre', key: 'name' }, { label: 'Tipo', render: (r) => (r.kind === 'cash' ? 'Caja' : 'Banco') }, { label: 'Banco', key: 'bank_name' }, { label: 'N.º cuenta', key: 'account_number' }, { label: 'Moneda', key: 'currency_code' }, { label: 'Estado', key: 'active' }]} />
  )
}

/* ---------------- Ingresos, egresos y transferencias ---------------- */
const MT: Record<string, string> = { income: 'Ingreso', expense: 'Egreso', transfer: 'Transferencia' }
export function CashMovementList() {
  return (
    <DocList table="cash_movements" type="cash_movement" title="Ingresos, egresos y transferencias" createPerm="treasury.create" dateField="movement_date" select="*, cash_bank_accounts!cash_movements_cash_bank_account_id_fkey(name)" newLabel="Movimiento"
      sub="Movimientos de caja y bancos que no provienen de un pago o cobro de facturas (esos ya generan su propio movimiento: no se duplican)."
      searchText={(r) => `${r.doc_number} ${r.description} ${r.reference}`}
      columns={[{ label: 'N.º', render: (r) => <b>{r.doc_number}</b> }, { label: 'Tipo', render: (r) => MT[r.movement_type] }, { label: 'Fecha', render: (r) => fdate(r.movement_date) }, { label: 'Cuenta', render: (r) => r.cash_bank_accounts?.name }, { label: 'Descripción', render: (r) => r.description }, { label: 'Importe', right: true, render: (r) => `${r.currency_code} ${money(r.amount)}` }]} />
  )
}

export function CashMovementForm() {
  const { id } = useParams()
  const isNew = id === 'nuevo'
  const nav = useNavigate()
  const { org, can } = useAuth()
  const { cashAccounts, accounts, activities, baseCurrency } = useCatalog()
  const toast = useToast()
  const [h, setH] = useState<Row>({ movement_type: 'income', movement_date: today(), cash_bank_account_id: '', to_cash_bank_account_id: '', counter_account_id: '', activity_id: '', currency_code: baseCurrency, exchange_rate: 1, amount: '', description: '', reference: '' })
  const [saving, setSaving] = useState(false)
  const { data: doc, loading, reload } = useAsync(async () => {
    if (isNew) return null
    const d = unwrap(await supabase.from('cash_movements').select('*').eq('id', id!).maybeSingle()) as Row | null
    if (d) setH({ ...d, to_cash_bank_account_id: d.to_cash_bank_account_id || '', counter_account_id: d.counter_account_id || '', activity_id: d.activity_id || '', description: d.description || '', reference: d.reference || '', _loadedCurrency: d.currency_code, _loadedDate: d.movement_date })
    return d
  }, [id, org?.id], null)
  const canEdit = (isNew || isEditable(doc?.status)) && can('treasury.create')
  useRateSync(h, setH, 'movement_date', canEdit, isNew)
  const pick = (aid: string) => { const a = cashAccounts.find((x) => x.id === aid); setH((x: Row) => ({ ...x, cash_bank_account_id: aid, currency_code: a?.currency_code || x.currency_code })) }
  const save = async () => {
    if (!org) return
    if (!h.cash_bank_account_id) return toast.err('Seleccione la cuenta.')
    if (num(h.amount) <= 0) return toast.err('Ingrese el importe.')
    if (h.movement_type === 'transfer' ? !h.to_cash_bank_account_id : !h.counter_account_id) return toast.err(h.movement_type === 'transfer' ? 'Seleccione la cuenta de destino.' : 'Seleccione la cuenta contable de contrapartida.')
    setSaving(true)
    try {
      const p = { movement_type: h.movement_type, movement_date: h.movement_date, cash_bank_account_id: h.cash_bank_account_id, to_cash_bank_account_id: h.movement_type === 'transfer' ? h.to_cash_bank_account_id : null, counter_account_id: h.movement_type === 'transfer' ? null : h.counter_account_id, activity_id: h.activity_id || null, currency_code: h.currency_code, exchange_rate: num(h.exchange_rate) || 1, amount: num(h.amount), description: h.description || null, reference: h.reference || null }
      if (isNew) { const r = unwrap(await supabase.from('cash_movements').insert({ ...p, organization_id: org.id }).select('id').single()) as Row; toast.ok('Guardado'); nav(`/tesoreria/movimientos/${r.id}`, { replace: true }) }
      else { unwrap(await supabase.from('cash_movements').update(p).eq('id', id!).select('id')); toast.ok('Guardado'); await reload() }
    } catch (e) { toast.err(errMsg(e)) } finally { setSaving(false) }
  }
  if (!isNew && loading && !doc) return <Spinner />
  const foreign = h.currency_code !== baseCurrency
  return (
    <DocFrame type="cash_movement" doc={doc} onChange={reload} title={isNew ? 'Nuevo movimiento de caja/banco' : `Movimiento ${doc?.doc_number || ''}`} sub="Ingreso, egreso o transferencia entre cuentas propias.">
      <div className="card card-pad stack">
        <div className="grid g4">
          <Field label="Tipo *"><select disabled={!canEdit} value={h.movement_type} onChange={(e) => setH({ ...h, movement_type: e.target.value })}><option value="income">Ingreso</option><option value="expense">Egreso</option><option value="transfer">Transferencia</option></select></Field>
          <Field label="Fecha *"><input type="date" disabled={!canEdit} value={h.movement_date} onChange={(e) => setH({ ...h, movement_date: e.target.value })} /></Field>
          <Field label={h.movement_type === 'transfer' ? 'Cuenta de origen *' : 'Caja / banco *'}><select disabled={!canEdit} value={h.cash_bank_account_id} onChange={(e) => pick(e.target.value)}><option value="">—</option>{cashAccounts.filter((a) => a.active).map((a) => <option key={a.id} value={a.id}>{a.name} ({a.currency_code})</option>)}</select></Field>
          {h.movement_type === 'transfer'
            ? <Field label="Cuenta de destino *"><select disabled={!canEdit} value={h.to_cash_bank_account_id} onChange={(e) => setH({ ...h, to_cash_bank_account_id: e.target.value })}><option value="">—</option>{cashAccounts.filter((a) => a.active && a.id !== h.cash_bank_account_id && a.currency_code === h.currency_code).map((a) => <option key={a.id} value={a.id}>{a.name}</option>)}</select></Field>
            : <Field label="Cuenta contable de contrapartida *"><select disabled={!canEdit} value={h.counter_account_id} onChange={(e) => setH({ ...h, counter_account_id: e.target.value })}><option value="">—</option>{accounts.filter((a) => a.is_postable && a.active).map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name}</option>)}</select></Field>}
          <Field label={`Importe (${h.currency_code}) *`}><input type="number" step="any" disabled={!canEdit} value={h.amount} onChange={(e) => setH({ ...h, amount: e.target.value })} /></Field>
          <Field label="Tipo de cambio"><input type="number" step="0.0001" disabled={!canEdit || !foreign} value={h.exchange_rate} onChange={(e) => setH({ ...h, exchange_rate: e.target.value })} /></Field>
          {h.movement_type !== 'transfer' && <Field label="Actividad"><select disabled={!canEdit} value={h.activity_id} onChange={(e) => setH({ ...h, activity_id: e.target.value })}><option value="">—</option>{activities.filter((a) => a.active).map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name}</option>)}</select></Field>}
          <Field label="Referencia"><input type="text" disabled={!canEdit} value={h.reference} onChange={(e) => setH({ ...h, reference: e.target.value })} /></Field>
        </div>
        <Field label="Descripción"><input type="text" disabled={!canEdit} value={h.description} onChange={(e) => setH({ ...h, description: e.target.value })} /></Field>
        {canEdit && <div><button className="btn primary" disabled={saving} onClick={save}>{saving ? 'Guardando…' : 'Guardar borrador'}</button></div>}
      </div>
    </DocFrame>
  )
}

/* ---------------- Extractos: listado ---------------- */
export function Statements() {
  const { org, can } = useAuth()
  const nav = useNavigate()
  const [view, setView] = useState<Row | null>(null)
  const { data, loading } = useAsync(async () => unwrap(await supabase.from('bank_statement_imports').select('*, cash_bank_accounts(name)').eq('organization_id', org!.id).order('imported_at', { ascending: false })) as Row[], [org?.id], [])
  return (
    <>
      <PageHeader title="Repositorio de extractos bancarios" sub="Extractos importados desde archivos CSV o Excel. Importar no genera asientos: primero se concilia y se aprueba.">
        {can('bank.import') && <button className="btn primary" onClick={() => nav('/tesoreria/extractos/importar')}>+ Importar extracto</button>}
      </PageHeader>
      <div className="card table-wrap">
        {loading ? <Spinner /> : !data?.length ? <Empty>Aún no se importó ningún extracto.</Empty> : (
          <table className="t"><thead><tr><th>Cuenta</th><th>Archivo</th><th>Periodo</th><th className="r">Líneas</th><th className="r">Duplicadas omitidas</th><th>Importado</th><th /></tr></thead>
            <tbody>{data.map((r) => (<tr key={r.id}><td>{r.cash_bank_accounts?.name}</td><td>{r.file_name}</td><td>{fdate(r.period_from)} – {fdate(r.period_to)}</td><td className="num">{r.line_count - r.duplicate_count}</td><td className="num">{r.duplicate_count}</td><td>{fdate(r.imported_at)}</td><td><button className="btn sm" onClick={() => setView(r)}>Ver líneas</button></td></tr>))}</tbody></table>
        )}
      </div>
      {view && <StatementLines imp={view} onClose={() => setView(null)} />}
    </>
  )
}
function StatementLines({ imp, onClose }: { imp: Row; onClose: () => void }) {
  const { data, loading } = useAsync(async () => unwrap(await supabase.from('bank_statement_lines').select('*').eq('import_id', imp.id).order('line_date').limit(3000)) as Row[], [imp.id], [])
  const st: Record<string, string> = { unmatched: 'Pendiente', partial: 'Parcial', matched: 'Conciliada', ignored: 'Ignorada' }
  return (
    <Modal wide title={`Extracto: ${imp.file_name}`} onClose={onClose}>
      {loading ? <Spinner /> : <div className="table-wrap"><table className="t"><thead><tr><th>Fecha</th><th>Descripción</th><th>Referencia</th><th className="r">Débito (cargo)</th><th className="r">Crédito (abono)</th><th>Estado</th></tr></thead>
        <tbody>{(data || []).map((l) => <tr key={l.id}><td>{fdate(l.line_date)}</td><td>{l.description}</td><td>{l.reference}</td><td className="num">{num(l.debit) ? money(l.debit) : ''}</td><td className="num">{num(l.credit) ? money(l.credit) : ''}</td><td>{st[l.match_status]}</td></tr>)}</tbody></table></div>}
    </Modal>
  )
}

/* ---------------- Extractos: importación ---------------- */
const FIELDS: [string, string, RegExp][] = [
  ['date', 'Fecha de operación *', /fecha|date/i], ['value_date', 'Fecha valor', /valor|value/i], ['description', 'Descripción', /descrip|concepto|detalle|glosa/i],
  ['reference', 'Referencia', /refer|nro|n[uú]mero|doc/i], ['external_id', 'Identificador bancario', /id|transac|operaci/i],
  ['debit', 'Débito / cargo / egreso', /d[eé]bito|cargo|egreso|retiro/i], ['credit', 'Crédito / abono / ingreso', /cr[eé]dito|abono|ingreso|dep[oó]sito/i],
  ['amount', 'Importe único (+ ingreso / − egreso)', /importe|monto|amount/i], ['balance', 'Saldo', /saldo|balance/i],
]
const norm = (s: any) => String(s ?? '').trim()

function parseNumber(v: any, decComma: boolean): number | null {
  if (v === null || v === undefined || v === '') return null
  if (typeof v === 'number') return v
  let s = String(v).trim().replace(/\s/g, '').replace(/[^\d.,\-+()]/g, '')
  if (!s) return null
  let neg = false
  if (/^\(.*\)$/.test(s)) { neg = true; s = s.slice(1, -1) }
  s = decComma ? s.replace(/\./g, '').replace(',', '.') : s.replace(/,/g, '')
  const n = parseFloat(s)
  if (!Number.isFinite(n)) return null
  return neg ? -n : n
}
function parseDate(v: any, fmt: string): string | null {
  if (v instanceof Date) return `${v.getFullYear()}-${String(v.getMonth() + 1).padStart(2, '0')}-${String(v.getDate()).padStart(2, '0')}`
  const s = norm(v)
  if (!s) return null
  let m = s.match(/^(\d{4})[-/](\d{1,2})[-/](\d{1,2})/)
  if (m) return `${m[1]}-${m[2].padStart(2, '0')}-${m[3].padStart(2, '0')}`
  m = s.match(/^(\d{1,2})[-/.](\d{1,2})[-/.](\d{2,4})/)
  if (!m) return null
  let [, a, b, y] = m
  if (y.length === 2) y = '20' + y
  const [d, mo] = fmt === 'mdy' ? [b, a] : [a, b]
  const dd = +d, mm = +mo
  if (mm < 1 || mm > 12 || dd < 1 || dd > 31) return null
  return `${y}-${String(mm).padStart(2, '0')}-${String(dd).padStart(2, '0')}`
}

export function StatementImport() {
  const { org, can } = useAuth()
  const { cashAccounts } = useCatalog()
  const toast = useToast()
  const nav = useNavigate()
  const [accId, setAccId] = useState('')
  const [file, setFile] = useState<File | null>(null)
  const [raw, setRaw] = useState<any[][]>([])
  const [hasHeader, setHasHeader] = useState(true)
  const [map, setMap] = useState<Record<string, string>>({})
  const [dateFmt, setDateFmt] = useState('dmy')
  const [decComma, setDecComma] = useState(false)
  const [busy, setBusy] = useState(false)
  const [result, setResult] = useState<Row | null>(null)
  if (!can('bank.import')) return <NoAccess perm="bank.import" />

  const headers = (hasHeader ? raw[0] : (raw[0] || []).map((_, i) => `Columna ${i + 1}`)) || []
  const body = hasHeader ? raw.slice(1) : raw
  const storeKey = `sc_map_${accId}`

  const load = async (f: File) => {
    setFile(f); setResult(null)
    try {
      let rows: any[][]
      if (/\.(xlsx)$/i.test(f.name)) rows = (await readSheet(f)) as any[][]
      else if (/\.xls$/i.test(f.name)) { toast.err('El formato .xls antiguo no es compatible: guárdelo como .xlsx o .csv.'); return }
      else {
        const text = await f.text()
        const res = Papa.parse<string[]>(text, { skipEmptyLines: true })
        rows = res.data as any[][]
      }
      rows = rows.filter((r) => r.some((c) => norm(c) !== ''))
      setRaw(rows)
      // mapeo guardado o sugerido
      let saved: Record<string, string> | null = null
      try { saved = JSON.parse(localStorage.getItem(storeKey) || 'null') } catch { /* nada */ }
      const hd = (rows[0] || []).map(norm)
      const guess: Record<string, string> = {}
      if (saved && Object.values(saved).every((v) => v === '' || +v < hd.length)) Object.assign(guess, saved)
      else FIELDS.forEach(([k, , re]) => { const i = hd.findIndex((h, ix) => re.test(h) && !Object.values(guess).includes(String(ix))); if (i >= 0) guess[k] = String(i) })
      setMap(guess)
    } catch (e) { toast.err('No se pudo leer el archivo: ' + errMsg(e)) }
  }

  const parsed = useMemo(() => {
    const out: Row[] = []; const errors: string[] = []
    if (!map.date) return { out, errors }
    body.forEach((r, i) => {
      const date = parseDate(r[+map.date], dateFmt)
      if (!date) { errors.push(`Fila ${i + (hasHeader ? 2 : 1)}: fecha no válida (“${norm(r[+map.date])}”)`); return }
      let debit = 0, credit = 0
      if (map.amount) { const a = parseNumber(r[+map.amount], decComma); if (a === null) { errors.push(`Fila ${i + (hasHeader ? 2 : 1)}: importe no válido`); return } if (a < 0) debit = -a; else credit = a }
      else { debit = Math.abs(parseNumber(r[+(map.debit ?? -1)], decComma) || 0); credit = Math.abs(parseNumber(r[+(map.credit ?? -1)], decComma) || 0) }
      if (debit === 0 && credit === 0) return
      out.push({ line_date: date, value_date: map.value_date ? parseDate(r[+map.value_date], dateFmt) : null, description: map.description ? norm(r[+map.description]) : null, reference: map.reference ? norm(r[+map.reference]) : null, external_id: map.external_id ? norm(r[+map.external_id]) : null, debit: round2(debit), credit: round2(credit), balance: map.balance ? parseNumber(r[+map.balance], decComma) : null })
    })
    return { out, errors }
  }, [raw, map, dateFmt, decComma, hasHeader])

  const doImport = async () => {
    if (!org || !file) return
    setBusy(true)
    try {
      const hash = await sha256(file)
      const r = await rpc<Row>('import_bank_statement', { p_org: org.id, p_account: accId, p_file_name: file.name, p_file_hash: hash, p_mapping: { ...map, dateFmt, decComma, hasHeader }, p_lines: parsed.out })
      try { localStorage.setItem(storeKey, JSON.stringify(map)) } catch { /* nada */ }
      setResult(r); toast.ok('Extracto importado')
    } catch (e) { toast.err(errMsg(e)) } finally { setBusy(false) }
  }
  const colSel = (k: string) => (
    <select value={map[k] ?? ''} onChange={(e) => setMap({ ...map, [k]: e.target.value })}>
      <option value="">— No usar —</option>{headers.map((h, i) => <option key={i} value={i}>{norm(h) || `Columna ${i + 1}`}</option>)}
    </select>
  )
  return (
    <>
      <PageHeader title="Importar extracto bancario" sub="Archivos CSV o Excel (.xlsx). Usted indica qué columna corresponde a cada dato; la correspondencia se recuerda para la próxima vez."><button className="btn" onClick={() => nav('/tesoreria/extractos')}>← Extractos</button></PageHeader>
      <div className="stack">
        <div className="card card-pad grid g2">
          <Field label="1. Cuenta bancaria *"><select value={accId} onChange={(e) => setAccId(e.target.value)}><option value="">— Seleccione —</option>{cashAccounts.filter((a) => a.kind === 'bank' && a.active).map((a) => <option key={a.id} value={a.id}>{a.name} ({a.currency_code})</option>)}</select></Field>
          <Field label="2. Archivo (.csv o .xlsx) *"><input type="file" accept=".csv,.xlsx,.txt" disabled={!accId} onChange={(e) => e.target.files?.[0] && load(e.target.files[0])} /></Field>
        </div>
        {raw.length > 0 && (
          <>
            <div className="card card-pad stack">
              <h3>3. Correspondencia de columnas</h3>
              <div className="row"><label className="check"><input type="checkbox" checked={hasHeader} onChange={(e) => setHasHeader(e.target.checked)} /> La primera fila contiene los títulos de columna</label></div>
              <div className="grid g3">
                {FIELDS.map(([k, l]) => <Field key={k} label={l}>{colSel(k)}</Field>)}
                <Field label="Formato de fecha"><select value={dateFmt} onChange={(e) => setDateFmt(e.target.value)}><option value="dmy">día/mes/año</option><option value="mdy">mes/día/año</option></select></Field>
                <Field label="Separador decimal"><select value={decComma ? 'c' : 'p'} onChange={(e) => setDecComma(e.target.value === 'c')}><option value="p">Punto (1,234.50)</option><option value="c">Coma (1.234,50)</option></select></Field>
              </div>
              <Alert kind="info">Use “Débito” y “Crédito” si el banco las entrega en columnas separadas, o “Importe único” si trae un solo monto con signo. Débito = salida de dinero (cargo); crédito = entrada (abono).</Alert>
            </div>
            <div className="card">
              <div className="card-pad"><h3>4. Vista previa — {parsed.out.length} movimientos válidos{parsed.errors.length ? `, ${parsed.errors.length} con error` : ''}</h3></div>
              {parsed.errors.length > 0 && <div className="card-pad"><Alert kind="warn">{parsed.errors.slice(0, 5).join(' · ')}{parsed.errors.length > 5 ? ' …' : ''}</Alert></div>}
              <div className="table-wrap"><table className="t"><thead><tr><th>Fecha</th><th>Descripción</th><th>Referencia</th><th className="r">Débito</th><th className="r">Crédito</th></tr></thead>
                <tbody>{parsed.out.slice(0, 15).map((l, i) => <tr key={i}><td>{fdate(l.line_date)}</td><td>{l.description}</td><td>{l.reference}</td><td className="num">{l.debit ? money(l.debit) : ''}</td><td className="num">{l.credit ? money(l.credit) : ''}</td></tr>)}</tbody></table></div>
              <div className="card-pad row">
                {result ? <Alert kind="ok">Importación lista: {result.inserted} movimientos nuevos, {result.duplicates} duplicados omitidos. <Link to="/tesoreria/conciliaciones/nuevo">Crear una conciliación →</Link></Alert> : (
                  <button className="btn primary" disabled={busy || !parsed.out.length || parsed.errors.length > 0 || !accId} onClick={doImport}>{busy ? 'Importando…' : `Importar ${parsed.out.length} movimientos`}</button>)}
                {parsed.errors.length > 0 && <span className="muted small">Corrija el mapeo o el archivo para poder importar.</span>}
              </div>
            </div>
          </>
        )}
      </div>
    </>
  )
}

/* ---------------- Conciliaciones ---------------- */
export function ReconciliationList() {
  return (
    <DocList table="bank_reconciliations" type="bank_reconciliation" title="Conciliaciones bancarias" createPerm="bank.reconcile" dateField="period_to" select="*, cash_bank_accounts(name)" newLabel="Conciliación"
      sub="Compare el extracto del banco con los movimientos contables de la cuenta." searchText={(r) => `${r.doc_number} ${r.cash_bank_accounts?.name}`}
      columns={[{ label: 'N.º', render: (r) => <b>{r.doc_number}</b> }, { label: 'Cuenta', render: (r) => r.cash_bank_accounts?.name }, { label: 'Periodo', render: (r) => `${fdate(r.period_from)} – ${fdate(r.period_to)}` }, { label: 'Saldo extracto', right: true, render: (r) => money(r.statement_balance) }]} />
  )
}

export function ReconciliationDetail() {
  const { id } = useParams()
  const isNew = id === 'nuevo'
  const nav = useNavigate()
  const { org, can } = useAuth()
  const { cashAccounts, accounts } = useCatalog()
  const toast = useToast()
  const [f, setF] = useState<Row>({ cash_bank_account_id: '', period_from: firstOfMonth(), period_to: today(), statement_balance: '', notes: '' })
  const [selS, setSelS] = useState<string | null>(null)
  const [selJ, setSelJ] = useState<string | null>(null)
  const [adj, setAdj] = useState<Row | null>(null)
  const [busy, setBusy] = useState(false)

  const { data: rec, loading: l1, reload: r1 } = useAsync(async () => (isNew ? null : (unwrap(await supabase.from('bank_reconciliations').select('*').eq('id', id!).maybeSingle()) as Row | null)), [id, org?.id], null)
  const acc = cashAccounts.find((a) => a.id === (isNew ? f.cash_bank_account_id : rec?.cash_bank_account_id))
  const { data: d, loading: l2, reload: r2 } = useAsync(async () => {
    if (isNew || !rec || !acc) return null
    const sl = unwrap(await supabase.from('bank_statement_lines').select('*').eq('cash_bank_account_id', acc.id).lte('line_date', rec.period_to).order('line_date').limit(5000)) as Row[]
    const jl = unwrap(await supabase.from('journal_entry_lines').select('id,debit,credit,description,journal_entries!inner(id,entry_number,entry_date,status,currency_code,reference,description)').eq('account_id', acc.account_id).eq('journal_entries.status', 'posted').lte('journal_entries.entry_date', rec.period_to).limit(5000)) as Row[]
    const ms = unwrap(await supabase.from('bank_reconciliation_matches').select('*, bank_statement_lines!inner(cash_bank_account_id)').eq('bank_statement_lines.cash_bank_account_id', acc.id).eq('status', 'active')) as Row[]
    const adjs = unwrap(await supabase.from('bank_reconciliation_adjustments').select('*').eq('reconciliation_id', rec.id)) as Row[]
    return { sl, jl: jl.filter((x) => x.journal_entries.currency_code === acc.currency_code), ms, adjs }
  }, [rec?.id, acc?.id, rec?.status], null)

  const editable = !isNew && isEditable(rec?.status) && can('bank.reconcile')
  const usedS = useMemo(() => { const m: Record<string, number> = {}; d?.ms.forEach((x) => (m[x.statement_line_id] = (m[x.statement_line_id] || 0) + num(x.amount))); return m }, [d])
  const usedJ = useMemo(() => { const m: Record<string, number> = {}; d?.ms.forEach((x) => (m[x.journal_line_id] = (m[x.journal_line_id] || 0) + num(x.amount))); return m }, [d])
  const stmtOpen = (d?.sl || []).filter((l) => l.match_status !== 'ignored' && round2(Math.abs(num(l.credit) - num(l.debit)) - (usedS[l.id] || 0)) > 0)
  const jOpen = (d?.jl || []).filter((l) => round2(Math.abs(num(l.debit) - num(l.credit)) - (usedJ[l.id] || 0)) > 0)
  const sRem = (l: Row) => round2(Math.abs(num(l.credit) - num(l.debit)) - (usedS[l.id] || 0))
  const jRem = (l: Row) => round2(Math.abs(num(l.debit) - num(l.credit)) - (usedJ[l.id] || 0))
  const sSign = (l: Row) => Math.sign(num(l.credit) - num(l.debit))
  const jSign = (l: Row) => Math.sign(num(l.debit) - num(l.credit))
  const bookBalance = round2((d?.jl || []).reduce((s, l) => s + num(l.debit) - num(l.credit), 0))

  const suggestions = useMemo(() => {
    const out: { s: Row; j: Row }[] = []; const taken = new Set<string>()
    stmtOpen.forEach((s) => {
      const cands = jOpen.filter((j) => !taken.has(j.id) && jSign(j) === sSign(s) && jRem(j) === sRem(s) && Math.abs(daysBetween(s.line_date, j.journal_entries.entry_date)) <= 7)
      if (!cands.length) return
      cands.sort((a, b) => Number((b.journal_entries.reference || '') === (s.reference || '') && !!s.reference) - Number((a.journal_entries.reference || '') === (s.reference || '') && !!s.reference) || Math.abs(daysBetween(s.line_date, a.journal_entries.entry_date)) - Math.abs(daysBetween(s.line_date, b.journal_entries.entry_date)))
      taken.add(cands[0].id); out.push({ s, j: cands[0] })
    })
    return out
  }, [d, usedS, usedJ])

  const create = async () => {
    if (!org || !f.cash_bank_account_id) return toast.err('Seleccione la cuenta bancaria.')
    try {
      const r = unwrap(await supabase.from('bank_reconciliations').insert({ organization_id: org.id, cash_bank_account_id: f.cash_bank_account_id, period_from: f.period_from, period_to: f.period_to, statement_balance: num(f.statement_balance), notes: f.notes || null }).select('id').single()) as Row
      nav(`/tesoreria/conciliaciones/${r.id}`, { replace: true })
    } catch (e) { toast.err(errMsg(e)) }
  }
  const doMatch = async (s: Row, j: Row, type: string) => {
    const amt = Math.min(sRem(s), jRem(j))
    await rpc('bank_match', { p_recon: rec!.id, p_stmt: s.id, p_jline: j.id, p_amount: amt, p_type: type })
  }
  const manual = async () => {
    const s = stmtOpen.find((x) => x.id === selS), j = jOpen.find((x) => x.id === selJ)
    if (!s || !j) return toast.err('Seleccione una línea del extracto y un movimiento contable.')
    setBusy(true)
    try { await doMatch(s, j, 'manual'); setSelS(null); setSelJ(null); toast.ok('Conciliado'); r2() } catch (e) { toast.err(errMsg(e)) } finally { setBusy(false) }
  }
  const acceptAll = async () => {
    setBusy(true); let n = 0
    try { for (const x of suggestions) { await doMatch(x.s, x.j, 'auto'); n++ }; toast.ok(`${n} coincidencias aceptadas`) } catch (e) { toast.err(errMsg(e)) } finally { setBusy(false); r2() }
  }
  const unmatch = async (m: Row) => { try { await rpc('bank_unmatch', { p_match: m.id, p_reason: 'Deshecho manualmente' }); r2() } catch (e) { toast.err(errMsg(e)) } }
  const ignore = async (l: Row, v: boolean) => { try { await rpc('bank_set_ignored', { p_line: l.id, p_ignored: v }); r2() } catch (e) { toast.err(errMsg(e)) } }
  const saveAdj = async () => {
    if (!adj!.counter) return toast.err('Seleccione la cuenta contable del ajuste.')
    try { const je = await rpc<string>('create_bank_adjustment', { p_recon: rec!.id, p_stmt: adj!.line.id, p_type: adj!.type, p_counter: adj!.counter, p_description: adj!.desc }); toast.ok('Ajuste propuesto como asiento en borrador. Debe aprobarse y contabilizarse.'); setAdj(null); r2(); nav(`/contabilidad/asientos/${je}`) } catch (e) { toast.err(errMsg(e)) }
  }

  if (isNew) {
    return (
      <>
        <PageHeader title="Nueva conciliación bancaria"><button className="btn" onClick={() => nav('/tesoreria/conciliaciones')}>← Volver</button></PageHeader>
        <div className="card card-pad stack" style={{ maxWidth: 720 }}>
          <div className="grid g2">
            <Field label="Cuenta bancaria *"><select value={f.cash_bank_account_id} onChange={(e) => setF({ ...f, cash_bank_account_id: e.target.value })}><option value="">—</option>{cashAccounts.filter((a) => a.kind === 'bank' && a.active).map((a) => <option key={a.id} value={a.id}>{a.name} ({a.currency_code})</option>)}</select></Field>
            <Field label="Saldo final según el extracto"><input type="number" step="any" value={f.statement_balance} onChange={(e) => setF({ ...f, statement_balance: e.target.value })} /></Field>
            <Field label="Desde"><input type="date" value={f.period_from} onChange={(e) => setF({ ...f, period_from: e.target.value })} /></Field>
            <Field label="Hasta"><input type="date" value={f.period_to} onChange={(e) => setF({ ...f, period_to: e.target.value })} /></Field>
          </div>
          <Field label="Notas"><input type="text" value={f.notes} onChange={(e) => setF({ ...f, notes: e.target.value })} /></Field>
          <div><button className="btn primary" onClick={create}>Crear y comenzar a conciliar</button></div>
        </div>
      </>
    )
  }
  if (l1 && !rec) return <Spinner />
  if (!rec) return <Alert kind="err">Conciliación no encontrada.</Alert>
  const diff = round2(num(rec.statement_balance) - bookBalance)
  const pendS = round2(stmtOpen.reduce((s, l) => s + sSign(l) * sRem(l), 0))
  const pendJ = round2(jOpen.reduce((s, l) => s + jSign(l) * jRem(l), 0))
  const unexplained = round2(diff - (pendS - pendJ))
  return (
    <DocFrame type="bank_reconciliation" doc={rec} onChange={() => { r1(); r2() }} title={`Conciliación ${rec.doc_number}`} listPath="/tesoreria/conciliaciones"
      sub={`${acc?.name || ''} · ${fdate(rec.period_from)} – ${fdate(rec.period_to)} · ${acc?.currency_code || ''}`}>
      <div className="grid g4">
        <div className="card stat"><div className="k">Saldo según extracto</div><div className="v">{money(rec.statement_balance)}</div></div>
        <div className="card stat"><div className="k">Saldo según contabilidad</div><div className="v">{money(bookBalance)}</div></div>
        <div className="card stat"><div className="k">Diferencia</div><div className="v">{money(diff)}</div></div>
        <div className="card stat"><div className="k">Diferencia no explicada</div><div className="v" style={{ color: unexplained === 0 ? 'var(--ok)' : 'var(--err)' }}>{money(unexplained)}</div></div>
      </div>
      <div className="muted small">Diferencia no explicada = diferencia − (partidas pendientes del extracto {money(pendS)} − partidas pendientes en libros {money(pendJ)}). Debe ser 0.00 para considerar la conciliación cuadrada.</div>
      {l2 || !d ? <Spinner /> : (
        <>
          {editable && (
            <div className="card card-pad row">
              <button className="btn gold" disabled={busy || !suggestions.length} onClick={acceptAll}>Aceptar {suggestions.length} sugerencias automáticas</button>
              <button className="btn primary" disabled={busy || !selS || !selJ} onClick={manual}>Conciliar selección manual</button>
              <span className="muted small">Sugerencias: mismo importe y sentido, fechas a ≤ 7 días (prioriza igual referencia). Puede revisarlas y deshacerlas.</span>
            </div>
          )}
          <div className="grid g2">
            <div className="card"><div className="card-pad"><h3>Extracto — pendiente de conciliar ({stmtOpen.length})</h3></div>
              <div className="table-wrap" style={{ maxHeight: 420, overflowY: 'auto' }}>{!stmtOpen.length ? <Empty>Sin partidas pendientes.</Empty> : (
                <table className="t"><tbody>{stmtOpen.map((l) => (
                  <tr key={l.id} className={suggestions.some((x) => x.s.id === l.id) ? 'match-good' : ''}>
                    <td>{editable && <input type="radio" name="s" checked={selS === l.id} onChange={() => setSelS(l.id)} />}</td>
                    <td className="nowrap">{fdate(l.line_date)}</td><td>{l.description}<div className="muted small">{l.reference}</div></td>
                    <td className="num" style={{ color: sSign(l) < 0 ? 'var(--err)' : 'var(--ok)' }}>{sSign(l) < 0 ? '−' : '+'}{money(sRem(l))}</td>
                    <td className="nowrap">{editable && !usedS[l.id] && <><button className="btn sm ghost" onClick={() => setAdj({ line: l, type: sSign(l) < 0 ? 'fee' : 'interest', counter: '', desc: l.description })}>Ajuste</button><button className="btn sm ghost" onClick={() => ignore(l, true)}>Ignorar</button></>}</td></tr>
                ))}</tbody></table>)}</div></div>
            <div className="card"><div className="card-pad"><h3>Libros — pendiente de conciliar ({jOpen.length})</h3></div>
              <div className="table-wrap" style={{ maxHeight: 420, overflowY: 'auto' }}>{!jOpen.length ? <Empty>Sin movimientos pendientes.</Empty> : (
                <table className="t"><tbody>{jOpen.map((l) => (
                  <tr key={l.id} className={suggestions.some((x) => x.j.id === l.id) ? 'match-good' : ''}>
                    <td>{editable && <input type="radio" name="j" checked={selJ === l.id} onChange={() => setSelJ(l.id)} />}</td>
                    <td className="nowrap">{fdate(l.journal_entries.entry_date)}</td><td><Link to={`/contabilidad/asientos/${l.journal_entries.id}`}>N.º {l.journal_entries.entry_number}</Link> {l.description || l.journal_entries.description}<div className="muted small">{l.journal_entries.reference}</div></td>
                    <td className="num" style={{ color: jSign(l) < 0 ? 'var(--err)' : 'var(--ok)' }}>{jSign(l) < 0 ? '−' : '+'}{money(jRem(l))}</td></tr>
                ))}</tbody></table>)}</div></div>
          </div>
          <div className="card"><div className="card-pad"><h3>Coincidencias registradas ({d.ms.filter((m) => m.reconciliation_id === rec.id).length})</h3></div>
            <div className="table-wrap">{!d.ms.filter((m) => m.reconciliation_id === rec.id).length ? <Empty>Aún no hay coincidencias en esta conciliación.</Empty> : (
              <table className="t"><thead><tr><th>Extracto</th><th>Libros</th><th className="r">Importe</th><th>Tipo</th><th /></tr></thead>
                <tbody>{d.ms.filter((m) => m.reconciliation_id === rec.id).map((m) => { const s = d.sl.find((x) => x.id === m.statement_line_id); const j = d.jl.find((x) => x.id === m.journal_line_id); return (
                  <tr key={m.id}><td>{fdate(s?.line_date)} · {s?.description}</td><td>{j ? `N.º ${j.journal_entries.entry_number} · ${fdate(j.journal_entries.entry_date)}` : '—'}</td><td className="num">{money(m.amount)}</td><td>{m.match_type === 'auto' ? 'Automática' : 'Manual'}</td><td>{editable && <button className="btn sm danger" onClick={() => unmatch(m)}>Deshacer</button>}</td></tr>) })}</tbody></table>)}</div></div>
          {d.adjs.length > 0 && <div className="card card-pad"><h3>Ajustes propuestos</h3><ul>{d.adjs.map((a) => <li key={a.id}>{a.description} — <Link to={`/contabilidad/asientos/${a.journal_entry_id}`}>asiento en borrador/aprobación</Link></li>)}</ul></div>}
        </>
      )}
      {adj && (
        <Modal title="Proponer ajuste bancario" onClose={() => setAdj(null)} footer={<><button className="btn" onClick={() => setAdj(null)}>Cancelar</button><button className="btn primary" onClick={saveAdj}>Crear asiento en borrador</button></>}>
          <div className="stack">
            <Alert kind="info">No se contabiliza nada automáticamente: se crea un asiento en borrador que debe enviarse a aprobación.</Alert>
            <div><b>{fdate(adj.line.line_date)}</b> · {adj.line.description} · <b>{money(Math.abs(num(adj.line.credit) - num(adj.line.debit)))}</b></div>
            <Field label="Tipo"><select value={adj.type} onChange={(e) => setAdj({ ...adj, type: e.target.value })}><option value="fee">Comisión</option><option value="charge">Cargo</option><option value="interest">Interés</option><option value="other">Otro</option></select></Field>
            <Field label="Cuenta contable de contrapartida *"><select value={adj.counter} onChange={(e) => setAdj({ ...adj, counter: e.target.value })}><option value="">—</option>{accounts.filter((a) => a.is_postable && a.active && a.id !== acc?.account_id).map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name}</option>)}</select></Field>
            <Field label="Descripción"><input type="text" value={adj.desc || ''} onChange={(e) => setAdj({ ...adj, desc: e.target.value })} /></Field>
          </div>
        </Modal>
      )}
    </DocFrame>
  )
}

import { useEffect, useMemo, useState } from 'react'
import { Link, useNavigate, useParams } from 'react-router-dom'
import { supabase } from '../lib/supabase'
import { Row, errMsg, unwrap } from '../lib/api'
import { useAsync } from '../lib/hooks'
import { useAuth } from '../context/Auth'
import { useCatalog } from '../context/Catalog'
import { useToast } from '../context/Toast'
import { DocFrame, DocList, isEditable } from '../components/DocParts'
import { Alert, Field, Spinner } from '../components/ui'
import { fdate, money, num, round2, today } from '../lib/format'
import { useRateSync } from './Invoices'

interface Cfg { table: string; allocTable: string; fk: string; invTable: string; partyKey: string; partyTable: string; dateKey: string; perm: string; type: string; base: string; title: string; numKey: string; supplier: boolean }
const SUP: Cfg = { table: 'supplier_payments', allocTable: 'supplier_payment_allocations', fk: 'payment_id', invTable: 'purchase_invoices', partyKey: 'supplier_id', partyTable: 'suppliers', dateKey: 'payment_date', perm: 'payments.create', type: 'supplier_payment', base: '/compras/pagos', title: 'Pago a proveedor', numKey: 'supplier_doc_number', supplier: true }
const CUS: Cfg = { table: 'customer_receipts', allocTable: 'customer_receipt_allocations', fk: 'receipt_id', invTable: 'sales_invoices', partyKey: 'customer_id', partyTable: 'customers', dateKey: 'receipt_date', perm: 'receipts.create', type: 'customer_receipt', base: '/ventas/cobros', title: 'Cobro de cliente', numKey: 'invoice_number', supplier: false }

export const SupplierPayments = () => <PayList cfg={SUP} />
export const CustomerReceipts = () => <PayList cfg={CUS} />
export const SupplierPaymentForm = () => <PayForm cfg={SUP} />
export const CustomerReceiptForm = () => <PayForm cfg={CUS} />

function PayList({ cfg }: { cfg: Cfg }) {
  return (
    <DocList table={cfg.table} type={cfg.type} title={cfg.supplier ? 'Pagos a proveedores' : 'Cobros de clientes'} createPerm={cfg.perm} dateField={cfg.dateKey} select={`*, ${cfg.partyTable}(name), cash_bank_accounts(name)`}
      sub="Pagos y cobros totales o parciales, distribuidos entre una o varias facturas." searchText={(r) => `${r.doc_number} ${r[cfg.partyTable]?.name} ${r.reference}`}
      columns={[
        { label: 'N.º', render: (r) => <b>{r.doc_number}</b> }, { label: cfg.supplier ? 'Proveedor' : 'Cliente', render: (r) => r[cfg.partyTable]?.name },
        { label: 'Fecha', render: (r) => fdate(r[cfg.dateKey]) }, { label: 'Cuenta', render: (r) => r.cash_bank_accounts?.name },
        { label: 'Referencia', render: (r) => r.reference }, { label: 'Importe', right: true, render: (r) => `${r.currency_code} ${money(r.amount)}` },
      ]} />
  )
}

function PayForm({ cfg }: { cfg: Cfg }) {
  const { id } = useParams()
  const isNew = id === 'nuevo'
  const nav = useNavigate()
  const { org, can } = useAuth()
  const { cashAccounts, paymentMethods, baseCurrency } = useCatalog()
  const toast = useToast()
  const [h, setH] = useState<Row>({ [cfg.partyKey]: '', [cfg.dateKey]: today(), cash_bank_account_id: '', payment_method_id: '', currency_code: baseCurrency, exchange_rate: 1, amount: '', reference: '', notes: '' })
  const [alloc, setAlloc] = useState<Record<string, string>>({})
  const [saving, setSaving] = useState(false)

  const { data: parties } = useAsync(async () => unwrap(await supabase.from(cfg.partyTable).select('id,name,active').eq('organization_id', org!.id).order('name')) as Row[], [org?.id, cfg.partyTable], [])
  const { data: doc, loading, reload } = useAsync(async () => {
    if (isNew) return null
    const d = unwrap(await supabase.from(cfg.table).select('*').eq('id', id!).maybeSingle()) as Row | null
    if (!d) return null
    const a = unwrap(await supabase.from(cfg.allocTable).select('*').eq(cfg.fk, id!)) as Row[]
    setH({ ...d, payment_method_id: d.payment_method_id || '', reference: d.reference || '', notes: d.notes || '', _loadedCurrency: d.currency_code, _loadedDate: d[cfg.dateKey] })
    setAlloc(Object.fromEntries(a.map((x) => [x.invoice_id, String(x.amount)])))
    return d
  }, [id, org?.id], null)

  const editable = isNew || isEditable(doc?.status)
  const canEdit = editable && can(cfg.perm)
  useRateSync(h, setH, cfg.dateKey, canEdit, isNew)

  const { data: invoices } = useAsync(async () => {
    if (!h[cfg.partyKey]) return []
    const r = unwrap(await supabase.from(cfg.invTable).select('*').eq('organization_id', org!.id).eq(cfg.partyKey, h[cfg.partyKey]).eq('status', 'posted').eq('currency_code', h.currency_code).order('issue_date')) as Row[]
    return r.filter((x) => num(x.total) - num(x.paid_amount) > 0 || alloc[x.id])
  }, [h[cfg.partyKey], h.currency_code, org?.id, doc?.status], [])

  const pickAccount = (aid: string) => {
    const a = cashAccounts.find((x) => x.id === aid)
    setH((x: Row) => ({ ...x, cash_bank_account_id: aid, currency_code: a?.currency_code || x.currency_code }))
    setAlloc({})
  }
  const allocated = useMemo(() => round2(Object.values(alloc).reduce((s, v) => s + num(v), 0)), [alloc])
  const amount = round2(num(h.amount))
  const autoDistribute = () => {
    let rest = amount
    const next: Record<string, string> = {}
    for (const inv of invoices || []) {
      const out = round2(num(inv.total) - num(inv.paid_amount))
      const take = Math.min(rest, out)
      if (take > 0) { next[inv.id] = String(take); rest = round2(rest - take) }
    }
    setAlloc(next)
    if (rest > 0) toast.info(`Quedan ${money(rest)} sin asignar: los anticipos no están habilitados en esta versión.`)
  }

  const save = async () => {
    if (!org) return
    if (!h[cfg.partyKey]) return toast.err(cfg.supplier ? 'Seleccione el proveedor.' : 'Seleccione el cliente.')
    if (!h.cash_bank_account_id) return toast.err('Seleccione la cuenta de caja o banco.')
    if (amount <= 0) return toast.err('Ingrese el importe.')
    if (allocated !== amount) return toast.err(`El total asignado a facturas (${money(allocated)}) debe ser igual al importe (${money(amount)}).`)
    for (const inv of invoices || []) {
      const a = num(alloc[inv.id])
      if (a > round2(num(inv.total) - num(inv.paid_amount)) + 0.0001) return toast.err(`La asignación a la factura ${inv[cfg.numKey]} supera su saldo pendiente.`)
    }
    setSaving(true)
    try {
      const header = { [cfg.partyKey]: h[cfg.partyKey], [cfg.dateKey]: h[cfg.dateKey], cash_bank_account_id: h.cash_bank_account_id, payment_method_id: h.payment_method_id || null, currency_code: h.currency_code, exchange_rate: num(h.exchange_rate) || 1, amount, reference: h.reference || null, notes: h.notes || null }
      let docId = id!
      if (isNew) docId = (unwrap(await supabase.from(cfg.table).insert({ ...header, organization_id: org.id }).select('id').single()) as Row).id
      else unwrap(await supabase.from(cfg.table).update(header).eq('id', docId).select('id'))
      unwrap(await supabase.from(cfg.allocTable).delete().eq(cfg.fk, docId).select('id'))
      const rows = Object.entries(alloc).filter(([, v]) => num(v) > 0).map(([invoice_id, v]) => ({ organization_id: org.id, [cfg.fk]: docId, invoice_id, amount: num(v) }))
      if (rows.length) unwrap(await supabase.from(cfg.allocTable).insert(rows).select('id'))
      toast.ok('Guardado')
      if (isNew) nav(`${cfg.base}/${docId}`, { replace: true }); else await reload()
    } catch (e) { toast.err(errMsg(e)) } finally { setSaving(false) }
  }

  if (!isNew && loading && !doc) return <Spinner />
  if (!isNew && !loading && !doc) return <Alert kind="err">No se encontró el documento. <Link to={cfg.base}>Volver</Link></Alert>
  const foreign = h.currency_code !== baseCurrency

  return (
    <DocFrame type={cfg.type} doc={doc} onChange={reload} title={isNew ? `Nuevo: ${cfg.title.toLowerCase()}` : `${cfg.title} ${doc?.doc_number || ''}`}
      sub="Asigne el importe a una o varias facturas contabilizadas. No se puede asignar más que el saldo pendiente.">
      <div className="card card-pad stack">
        <div className="grid g4">
          <Field label={cfg.supplier ? 'Proveedor *' : 'Cliente *'}><select disabled={!canEdit} value={h[cfg.partyKey]} onChange={(e) => { setH({ ...h, [cfg.partyKey]: e.target.value }); setAlloc({}) }}><option value="">— Seleccione —</option>{(parties || []).filter((p) => p.active || p.id === h[cfg.partyKey]).map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}</select></Field>
          <Field label="Fecha *"><input type="date" disabled={!canEdit} value={h[cfg.dateKey]} onChange={(e) => setH({ ...h, [cfg.dateKey]: e.target.value })} /></Field>
          <Field label={cfg.supplier ? 'Pagar desde *' : 'Cobrar en *'}><select disabled={!canEdit} value={h.cash_bank_account_id} onChange={(e) => pickAccount(e.target.value)}><option value="">— Cuenta —</option>{cashAccounts.filter((a) => a.active || a.id === h.cash_bank_account_id).map((a) => <option key={a.id} value={a.id}>{a.name} ({a.currency_code})</option>)}</select></Field>
          <Field label="Método"><select disabled={!canEdit} value={h.payment_method_id} onChange={(e) => setH({ ...h, payment_method_id: e.target.value })}><option value="">—</option>{paymentMethods.filter((m) => m.active).map((m) => <option key={m.id} value={m.id}>{m.name}</option>)}</select></Field>
          <Field label={`Importe (${h.currency_code}) *`}><input type="number" step="any" disabled={!canEdit} value={h.amount} onChange={(e) => setH({ ...h, amount: e.target.value })} /></Field>
          <Field label={`Tipo de cambio${foreign ? ` (${baseCurrency} por ${h.currency_code})` : ''}`} hint={foreign ? 'Si difiere del de la factura se registrará diferencia de cambio.' : undefined}><input type="number" step="0.0001" disabled={!canEdit || !foreign} value={h.exchange_rate} onChange={(e) => setH({ ...h, exchange_rate: e.target.value })} /></Field>
          <Field label="Referencia (n.º de transferencia, cheque…)"><input type="text" disabled={!canEdit} value={h.reference} onChange={(e) => setH({ ...h, reference: e.target.value })} /></Field>
          <Field label="Notas"><input type="text" disabled={!canEdit} value={h.notes} onChange={(e) => setH({ ...h, notes: e.target.value })} /></Field>
        </div>
      </div>
      <div className="card">
        <div className="card-pad row" style={{ justifyContent: 'space-between' }}>
          <h3 style={{ margin: 0 }}>Facturas pendientes ({h.currency_code})</h3>
          {canEdit && <button className="btn sm" onClick={autoDistribute}>Distribuir automáticamente (más antiguas primero)</button>}
        </div>
        <div className="table-wrap">
          {!h[cfg.partyKey] ? <div className="empty">Seleccione un {cfg.supplier ? 'proveedor' : 'cliente'} y una cuenta para ver sus facturas pendientes en esa moneda.</div> : !invoices?.length ? <div className="empty">No hay facturas contabilizadas con saldo pendiente en {h.currency_code}.</div> : (
            <table className="t lines"><thead><tr><th>Factura</th><th>Fecha</th><th>Vence</th><th className="r">Total</th><th className="r">Saldo pendiente</th><th className="r">Aplicar</th></tr></thead>
              <tbody>{invoices.map((inv) => {
                const out = round2(num(inv.total) - num(inv.paid_amount))
                return (<tr key={inv.id}><td><Link to={`${cfg.supplier ? '/compras/facturas' : '/ventas/facturas'}/${inv.id}`}>{inv[cfg.numKey]}</Link></td><td>{fdate(inv.issue_date)}</td><td>{fdate(inv.due_date)}</td><td className="num">{money(inv.total)}</td><td className="num">{money(out)}</td>
                  <td className="num"><input type="number" step="any" style={{ width: 120 }} disabled={!canEdit} value={alloc[inv.id] ?? ''} onChange={(e) => setAlloc({ ...alloc, [inv.id]: e.target.value })} /></td></tr>)
              })}</tbody>
              <tfoot><tr><td colSpan={5} className="num">Total asignado</td><td className="num">{money(allocated)}</td></tr></tfoot></table>
          )}
        </div>
        <div className="card-pad row">
          <span className={`badge ${allocated === amount && amount > 0 ? 'b-ok' : 'b-warn'}`}>{allocated === amount && amount > 0 ? 'Asignación completa' : `Por asignar: ${money(amount - allocated)}`}</span>
          <span style={{ flex: 1 }} />
          {canEdit && <button className="btn primary" disabled={saving} onClick={save}>{saving ? 'Guardando…' : 'Guardar borrador'}</button>}
        </div>
      </div>
    </DocFrame>
  )
}

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
import { addDays, fdate, money, num, round2, today } from '../lib/format'

export async function latestRate(orgId: string, currency: string, date: string): Promise<number | null> {
  const { data } = await supabase.from('exchange_rates').select('rate').eq('organization_id', orgId).eq('currency_code', currency).lte('rate_date', date).order('rate_date', { ascending: false }).limit(1)
  return data && data.length ? Number(data[0].rate) : null
}

export function useRateSync(h: Row, setH: (f: (x: Row) => Row) => void, dateKey: string, editable: boolean, isNew: boolean) {
  const { org } = useAuth()
  const { baseCurrency } = useCatalog()
  useEffect(() => {
    if (!org || !editable || !h.currency_code) return
    if (h.currency_code === baseCurrency) { if (num(h.exchange_rate) !== 1) setH((x) => ({ ...x, exchange_rate: 1 })); return }
    if (!isNew && h._loadedCurrency === h.currency_code && h._loadedDate === h[dateKey]) return
    latestRate(org.id, h.currency_code, h[dateKey] || today()).then((r) => { if (r) setH((x) => ({ ...x, exchange_rate: r, _noRate: false })); else setH((x) => ({ ...x, _noRate: true })) })
  }, [h.currency_code, h[dateKey], baseCurrency, editable])
}

interface Cfg {
  kind: 'purchase' | 'sales'; table: string; linesTable: string; type: string; partyKey: string; partyTable: string; numKey: string
  title: string; perm: string; applies: string; base: string
}
const CFG: Record<string, Cfg> = {
  purchase: { kind: 'purchase', table: 'purchase_invoices', linesTable: 'purchase_invoice_lines', type: 'purchase_invoice', partyKey: 'supplier_id', partyTable: 'suppliers', numKey: 'supplier_doc_number', title: 'Factura de compra', perm: 'purchases.create', applies: 'purchase', base: '/compras/facturas' },
  sales: { kind: 'sales', table: 'sales_invoices', linesTable: 'sales_invoice_lines', type: 'sales_invoice', partyKey: 'customer_id', partyTable: 'customers', numKey: 'invoice_number', title: 'Factura de venta', perm: 'sales.create', applies: 'sales', base: '/ventas/facturas' },
}

export function PurchaseInvoices() { return <InvoiceList cfg={CFG.purchase} /> }
export function SalesInvoices() { return <InvoiceList cfg={CFG.sales} /> }
export function PurchaseInvoiceForm() { return <InvoiceForm cfg={CFG.purchase} /> }
export function SalesInvoiceForm() { return <InvoiceForm cfg={CFG.sales} /> }

function InvoiceList({ cfg }: { cfg: Cfg }) {
  const p = cfg.kind === 'purchase'
  return (
    <DocList table={cfg.table} type={cfg.type} title={p ? 'Facturas de compra' : 'Facturas de venta'} createPerm={cfg.perm} dateField="issue_date"
      select={`*, ${cfg.partyTable}(name)`} searchText={(r) => `${r.doc_number} ${r[cfg.numKey]} ${r[cfg.partyTable]?.name}`}
      columns={[
        { label: 'N.º interno', render: (r) => <b>{r.doc_number}</b> },
        { label: p ? 'Factura proveedor' : 'Factura', render: (r) => r[cfg.numKey] },
        { label: p ? 'Proveedor' : 'Cliente', render: (r) => r[cfg.partyTable]?.name },
        { label: 'Fecha', render: (r) => fdate(r.issue_date) },
        { label: 'Moneda', render: (r) => r.currency_code },
        { label: 'Total', right: true, render: (r) => money(r.total) },
        { label: 'Saldo', right: true, render: (r) => (r.status === 'posted' ? money(num(r.total) - num(r.paid_amount)) : '') },
      ]} />
  )
}

type Line = Row

function InvoiceForm({ cfg }: { cfg: Cfg }) {
  const { id } = useParams()
  const isNew = id === 'nuevo'
  const nav = useNavigate()
  const { org, can } = useAuth()
  const { accounts, activities, taxes, products, currencies, baseCurrency } = useCatalog()
  const toast = useToast()
  const purchase = cfg.kind === 'purchase'
  const [h, setH] = useState<Row>({ issue_date: today(), registration_date: today(), currency_code: baseCurrency, exchange_rate: 1, payment_form: 'credit', [cfg.partyKey]: '', [cfg.numKey]: '', authorization_number: '', due_date: '', notes: '' })
  const [lines, setLines] = useState<Line[]>([])
  const [oldIds, setOldIds] = useState<string[]>([])
  const [saving, setSaving] = useState(false)

  const { data: parties } = useAsync(async () => unwrap(await supabase.from(cfg.partyTable).select('id,name,tax_id,payment_terms_days,active').eq('organization_id', org!.id).order('name')) as Row[], [org?.id, cfg.partyTable], [])
  const { data: doc, loading, reload } = useAsync(async () => {
    if (isNew) return null
    const d = unwrap(await supabase.from(cfg.table).select('*').eq('id', id!).maybeSingle()) as Row | null
    if (!d) return null
    const l = unwrap(await supabase.from(cfg.linesTable).select('*').eq('invoice_id', id!).order('line_no')) as Row[]
    setH({ ...d, due_date: d.due_date || '', authorization_number: d.authorization_number || '', notes: d.notes || '', _loadedCurrency: d.currency_code, _loadedDate: d.issue_date })
    setLines(l.map((x) => ({ ...x, product_id: x.product_id || '', account_id: x.account_id || '', tax_type_id: x.tax_type_id || '', activity_id: x.activity_id || '', description: x.description || '' })))
    setOldIds(l.map((x) => x.id))
    return d
  }, [id, org?.id], null)

  const editable = isNew || isEditable(doc?.status)
  const canEdit = editable && can(cfg.perm)
  useRateSync(h, setH, 'issue_date', canEdit, isNew)

  useEffect(() => { if (isNew && lines.length === 0) setLines([newLine(purchase)]) }, [isNew])

  const taxOpts = taxes.filter((t) => t.active && (t.applies_to === 'both' || t.applies_to === cfg.applies))
  const calc = (l: Line) => {
    const base = round2(num(l.quantity) * num(l.unit_price) - num(l.discount))
    const rate = num(taxes.find((t) => t.id === l.tax_type_id)?.rate)
    const tax = round2((base * rate) / 100)
    return { base, tax, total: base + tax }
  }
  const totals = useMemo(() => lines.reduce((a, l) => { const c = calc(l); return { sub: a.sub + c.base, tax: a.tax + c.tax } }, { sub: 0, tax: 0 }), [lines, taxes])
  const total = round2(totals.sub + totals.tax)

  const setLine = (i: number, patch: Row) => setLines((ls) => ls.map((l, j) => (j === i ? { ...l, ...patch } : l)))
  const pickProduct = (i: number, pid: string) => {
    const p = products.find((x) => x.id === pid)
    setLine(i, { product_id: pid, description: p?.name || '', ...(p && !purchase ? { unit_price: p.sale_price } : {}) })
  }
  const pickParty = (pid: string) => {
    const p = parties?.find((x) => x.id === pid)
    setH((x: Row) => ({ ...x, [cfg.partyKey]: pid, due_date: p && num(p.payment_terms_days) > 0 ? addDays(x.issue_date, num(p.payment_terms_days)) : x.due_date }))
  }

  const save = async () => {
    if (!org) return
    if (!h[cfg.partyKey]) return toast.err(purchase ? 'Seleccione el proveedor.' : 'Seleccione el cliente.')
    if (!String(h[cfg.numKey]).trim()) return toast.err(purchase ? 'Ingrese el número de la factura del proveedor.' : 'Ingrese el número de factura.')
    const valid = lines.filter((l) => num(l.quantity) > 0)
    if (!valid.length) return toast.err('Agregue al menos una línea con cantidad.')
    for (const l of valid) {
      if (purchase && l.line_kind === 'inventory' && !l.product_id) return toast.err('Las líneas de inventario requieren un producto.')
      if (purchase && l.line_kind === 'expense' && !l.account_id) return toast.err('Las líneas de gasto requieren una cuenta contable.')
    }
    if (h.currency_code !== baseCurrency && num(h.exchange_rate) <= 0) return toast.err('Ingrese el tipo de cambio.')
    setSaving(true)
    try {
      const header: Row = {
        [cfg.partyKey]: h[cfg.partyKey], [cfg.numKey]: String(h[cfg.numKey]).trim(), authorization_number: h.authorization_number || null,
        issue_date: h.issue_date, due_date: h.due_date || null, currency_code: h.currency_code, exchange_rate: num(h.exchange_rate) || 1, notes: h.notes || null,
        ...(purchase ? { registration_date: h.registration_date || today(), payment_form: h.payment_form } : {}),
      }
      let docId = id!
      if (isNew) docId = (unwrap(await supabase.from(cfg.table).insert({ ...header, organization_id: org.id }).select('id').single()) as Row).id
      else unwrap(await supabase.from(cfg.table).update(header).eq('id', docId).select('id'))
      const rows = valid.map((l, i) => ({
        organization_id: org.id, invoice_id: docId, line_no: i + 1, product_id: l.product_id || null, account_id: l.account_id || null, description: l.description || null,
        quantity: num(l.quantity), unit_price: num(l.unit_price), discount: num(l.discount), tax_type_id: l.tax_type_id || null, activity_id: l.activity_id || null,
        ...(purchase ? { line_kind: l.line_kind } : {}),
      }))
      unwrap(await supabase.from(cfg.linesTable).insert(rows).select('id'))
      if (oldIds.length) unwrap(await supabase.from(cfg.linesTable).delete().in('id', oldIds).select('id'))
      toast.ok('Documento guardado')
      if (isNew) nav(`${cfg.base}/${docId}`, { replace: true }); else await reload()
    } catch (e) { toast.err(errMsg(e)) } finally { setSaving(false) }
  }

  if (!isNew && loading && !doc) return <Spinner />
  if (!isNew && !loading && !doc) return <Alert kind="err">No se encontró el documento. <Link to={cfg.base}>Volver</Link></Alert>
  const party = parties?.find((p) => p.id === h[cfg.partyKey])
  const foreign = h.currency_code !== baseCurrency

  return (
    <DocFrame type={cfg.type} doc={doc} title={isNew ? `Nueva ${cfg.title.toLowerCase()}` : `${cfg.title} ${doc?.doc_number || ''}`} onChange={reload}
      sub={!isNew && doc ? `Registrada por el usuario el ${fdate(doc.created_at)}` : 'Complete los datos y guarde como borrador. Luego envíela a aprobación.'}>
      <div className="card card-pad stack">
        <div className="grid g4">
          <Field label={purchase ? 'Proveedor *' : 'Cliente *'} className="g-span2">
            <select disabled={!canEdit} value={h[cfg.partyKey]} onChange={(e) => pickParty(e.target.value)}>
              <option value="">— Seleccione —</option>
              {(parties || []).filter((p) => p.active || p.id === h[cfg.partyKey]).map((p) => <option key={p.id} value={p.id}>{p.name}{p.tax_id ? ` (${p.tax_id})` : ''}</option>)}
            </select>
          </Field>
          <Field label={purchase ? 'N.º factura del proveedor *' : 'N.º de factura *'}><input type="text" disabled={!canEdit} value={h[cfg.numKey]} onChange={(e) => setH({ ...h, [cfg.numKey]: e.target.value })} /></Field>
          <Field label="N.º de autorización (opcional)"><input type="text" disabled={!canEdit} value={h.authorization_number} onChange={(e) => setH({ ...h, authorization_number: e.target.value })} /></Field>
          <Field label="Fecha de emisión *" hint="Define el periodo contable"><input type="date" disabled={!canEdit} value={h.issue_date} onChange={(e) => setH({ ...h, issue_date: e.target.value })} /></Field>
          {purchase && <Field label="Fecha de registro"><input type="date" disabled={!canEdit} value={h.registration_date} onChange={(e) => setH({ ...h, registration_date: e.target.value })} /></Field>}
          <Field label="Vencimiento"><input type="date" disabled={!canEdit} value={h.due_date} onChange={(e) => setH({ ...h, due_date: e.target.value })} /></Field>
          {purchase && <Field label="Forma de pago"><select disabled={!canEdit} value={h.payment_form} onChange={(e) => setH({ ...h, payment_form: e.target.value })}><option value="credit">Crédito</option><option value="cash">Contado</option></select></Field>}
          <Field label="Moneda"><select disabled={!canEdit} value={h.currency_code} onChange={(e) => setH({ ...h, currency_code: e.target.value })}>{currencies.map((c) => <option key={c.code} value={c.code}>{c.code}</option>)}</select></Field>
          <Field label={`Tipo de cambio${foreign ? ` (${baseCurrency} por ${h.currency_code})` : ''}`} hint={foreign && h._noRate ? 'No hay tipo de cambio registrado a esa fecha: ingréselo.' : undefined}>
            <input type="number" step="0.0001" disabled={!canEdit || !foreign} value={h.exchange_rate} onChange={(e) => setH({ ...h, exchange_rate: e.target.value })} />
          </Field>
        </div>
        <Field label="Observaciones"><textarea disabled={!canEdit} value={h.notes} onChange={(e) => setH({ ...h, notes: e.target.value })} /></Field>
        {party && !party.active && <Alert kind="warn">Este {purchase ? 'proveedor' : 'cliente'} está inactivo.</Alert>}
      </div>

      <div className="card">
        <div className="table-wrap">
          <table className="t lines">
            <thead><tr>{purchase && <th>Tipo</th>}<th style={{ minWidth: 200 }}>{purchase ? 'Producto / cuenta' : 'Producto / servicio'}</th><th style={{ minWidth: 170 }}>Descripción</th><th className="r">Cant.</th><th className="r">Precio unit.</th><th className="r">Descuento</th><th>Impuesto</th><th>Actividad</th><th className="r">Importe</th><th /></tr></thead>
            <tbody>
              {lines.map((l, i) => {
                const c = calc(l)
                return (
                  <tr key={i}>
                    {purchase && <td><select disabled={!canEdit} value={l.line_kind} onChange={(e) => setLine(i, { line_kind: e.target.value })}><option value="inventory">Inventario</option><option value="expense">Gasto / servicio</option><option value="landed_cost">Costo adicional</option></select></td>}
                    <td>
                      {purchase ? (l.line_kind === 'inventory' ? (
                        <select disabled={!canEdit} value={l.product_id} onChange={(e) => pickProduct(i, e.target.value)}><option value="">Producto…</option>{products.filter((p) => p.product_type === 'inventory' && p.active).map((p) => <option key={p.id} value={p.id}>{p.sku} · {p.name}</option>)}</select>
                      ) : l.line_kind === 'expense' ? (
                        <select disabled={!canEdit} value={l.account_id} onChange={(e) => setLine(i, { account_id: e.target.value })}><option value="">Cuenta de gasto/activo…</option>{accounts.filter((a) => a.is_postable && a.active).map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name}</option>)}</select>
                      ) : <span className="muted small">Se reparte entre las líneas de inventario</span>)
                        : (
                          <select disabled={!canEdit} value={l.product_id} onChange={(e) => pickProduct(i, e.target.value)}><option value="">Concepto libre…</option>{products.filter((p) => p.active).map((p) => <option key={p.id} value={p.id}>{p.sku} · {p.name}</option>)}</select>
                        )}
                    </td>
                    <td><input type="text" disabled={!canEdit} value={l.description} onChange={(e) => setLine(i, { description: e.target.value })} />
                      {!purchase && !l.product_id && <select style={{ marginTop: 4 }} disabled={!canEdit} value={l.account_id} onChange={(e) => setLine(i, { account_id: e.target.value })}><option value="">Cuenta de ingreso (por defecto)</option>{accounts.filter((a) => a.is_postable && a.active && a.account_type === 'revenue').map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name}</option>)}</select>}
                    </td>
                    <td><input type="number" step="any" style={{ width: 84 }} disabled={!canEdit} value={l.quantity} onChange={(e) => setLine(i, { quantity: e.target.value })} /></td>
                    <td><input type="number" step="any" style={{ width: 104 }} disabled={!canEdit} value={l.unit_price} onChange={(e) => setLine(i, { unit_price: e.target.value })} /></td>
                    <td><input type="number" step="any" style={{ width: 90 }} disabled={!canEdit} value={l.discount} onChange={(e) => setLine(i, { discount: e.target.value })} /></td>
                    <td><select disabled={!canEdit} value={l.tax_type_id} onChange={(e) => setLine(i, { tax_type_id: e.target.value })}><option value="">Sin impuesto</option>{taxOpts.map((t) => <option key={t.id} value={t.id}>{t.code} ({t.rate}%)</option>)}</select></td>
                    <td><select disabled={!canEdit} value={l.activity_id} onChange={(e) => setLine(i, { activity_id: e.target.value })}><option value="">—</option>{activities.filter((a) => a.active).map((a) => <option key={a.id} value={a.id}>{a.code}</option>)}</select></td>
                    <td className="num">{money(c.base)}</td>
                    <td>{canEdit && <button className="btn sm ghost" aria-label="Quitar línea" onClick={() => setLines(lines.filter((_, j) => j !== i))}>✕</button>}</td>
                  </tr>
                )
              })}
            </tbody>
            <tfoot>
              <tr><td colSpan={purchase ? 8 : 7} className="num">Subtotal</td><td className="num">{money(totals.sub)}</td><td /></tr>
              <tr><td colSpan={purchase ? 8 : 7} className="num">Impuestos</td><td className="num">{money(totals.tax)}</td><td /></tr>
              <tr><td colSpan={purchase ? 8 : 7} className="num">TOTAL {h.currency_code}</td><td className="num">{money(total)}</td><td /></tr>
              {foreign && <tr><td colSpan={purchase ? 8 : 7} className="num muted">Equivale a {baseCurrency}</td><td className="num muted">{money(total * num(h.exchange_rate))}</td><td /></tr>}
            </tfoot>
          </table>
        </div>
        {canEdit && (
          <div className="card-pad row">
            <button className="btn" onClick={() => setLines([...lines, newLine(purchase)])}>+ Agregar línea</button>
            <span style={{ flex: 1 }} />
            <button className="btn primary" disabled={saving} onClick={save}>{saving ? 'Guardando…' : 'Guardar borrador'}</button>
          </div>
        )}
      </div>
      {doc?.status === 'posted' && (
        <div className="card card-pad"><h3>Saldo</h3>
          <div className="row">Total <b>{money(doc.total)}</b> · {purchase ? 'Pagado' : 'Cobrado'} <b>{money(doc.paid_amount)}</b> · Saldo pendiente <b>{money(num(doc.total) - num(doc.paid_amount))}</b> {doc.currency_code}</div>
        </div>
      )}
      <style>{`.g-span2{grid-column:span 2}@media(max-width:980px){.g-span2{grid-column:auto}}`}</style>
    </DocFrame>
  )
}

const newLine = (purchase: boolean): Line => ({ line_kind: purchase ? 'inventory' : undefined, product_id: '', account_id: '', description: '', quantity: 1, unit_price: 0, discount: 0, tax_type_id: '', activity_id: '' })

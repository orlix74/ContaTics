import { useEffect, useState } from 'react'
import { Link, useNavigate, useParams } from 'react-router-dom'
import { supabase } from '../lib/supabase'
import { DOC_ROUTE, DOC_TYPE_LABEL, Row, errMsg, unwrap } from '../lib/api'
import { useAsync } from '../lib/hooks'
import { useAuth } from '../context/Auth'
import { useCatalog } from '../context/Catalog'
import { useToast } from '../context/Toast'
import { DocFrame, DocList, isEditable } from '../components/DocParts'
import { Alert, Empty, Field, PageHeader, Spinner } from '../components/ui'
import { fdate, firstOfYear, money, num, qty, today } from '../lib/format'
import { exportExcel, exportPdf } from '../lib/export'

const MOV_LABEL: Record<string, string> = { purchase_in: 'Compra', sale_out: 'Venta', adjust_in: 'Ajuste (+)', adjust_out: 'Ajuste (−)', purchase_return_out: 'Devolución/anulación compra', sale_return_in: 'Devolución/anulación venta' }

export function Movements() {
  const { org, can } = useAuth()
  const { products, activities } = useCatalog()
  const [pid, setPid] = useState('')
  const [from, setFrom] = useState(firstOfYear())
  const [to, setTo] = useState(today())
  const { data, loading, error } = useAsync(async () => {
    let q = supabase.from('inventory_movements').select('*').eq('organization_id', org!.id).gte('movement_date', from).lte('movement_date', to)
    if (pid) q = q.eq('product_id', pid)
    return unwrap(await q.order('movement_date').order('created_at').limit(3000)) as Row[]
  }, [org?.id, pid, from, to], [])
  const prod = (id: string) => products.find((p) => p.id === id)
  let run = 0, runv = 0
  const rows = (data || []).map((m) => { run += num(m.quantity); runv += num(m.total_cost); return { ...m, _bal: run, _val: runv, _p: prod(m.product_id) } })
  const cols = [{ key: 'd', label: 'Fecha', type: 'date' as const }, { key: 'p', label: 'Producto' }, { key: 't', label: 'Movimiento' }, { key: 'q', label: 'Cantidad', type: 'qty' as const }, { key: 'u', label: 'Costo unit.', type: 'money' as const }, { key: 'c', label: 'Costo total', type: 'money' as const }, ...(pid ? [{ key: 'b', label: 'Saldo cant.', type: 'qty' as const }, { key: 'v', label: 'Saldo valor', type: 'money' as const }] : [])]
  const exportRows = rows.map((m) => ({ d: m.movement_date, p: `${m._p?.sku || ''} ${m._p?.name || ''}`, t: MOV_LABEL[m.movement_type], q: m.quantity, u: m.unit_cost, c: m.total_cost, b: m._bal, v: m._val }))
  const meta = { title: pid ? `Kardex ${prod(pid)?.name}` : 'Movimientos de inventario', company: org!.legal_name, taxId: org!.tax_id, period: `${fdate(from)} al ${fdate(to)}`, currency: org!.base_currency }
  return (
    <>
      <PageHeader title="Movimientos de inventario y kardex" sub="Cada movimiento está vinculado a su documento de origen. Seleccione un producto para ver el kardex con saldos.">
        {can('reports.export') && <><button className="btn" onClick={() => exportExcel(meta, cols, exportRows)}>Excel</button><button className="btn" onClick={() => exportPdf(meta, cols, exportRows)}>PDF</button></>}
      </PageHeader>
      <div className="toolbar">
        <Field label="Producto"><select value={pid} onChange={(e) => setPid(e.target.value)}><option value="">Todos</option>{products.filter((p) => p.product_type === 'inventory').map((p) => <option key={p.id} value={p.id}>{p.sku} · {p.name}</option>)}</select></Field>
        <Field label="Desde"><input type="date" value={from} onChange={(e) => setFrom(e.target.value)} /></Field>
        <Field label="Hasta"><input type="date" value={to} onChange={(e) => setTo(e.target.value)} /></Field>
      </div>
      <div className="card table-wrap">
        {loading ? <Spinner /> : error ? <div className="card-pad"><Alert kind="err">{error}</Alert></div> : !rows.length ? <Empty>No hay movimientos en el periodo.</Empty> : (
          <table className="t"><thead><tr><th>Fecha</th><th>Producto</th><th>Movimiento</th><th>Documento</th><th className="r">Cantidad</th><th className="r">Costo unit.</th><th className="r">Costo total</th>{pid && <><th className="r">Saldo cant.</th><th className="r">Saldo valor</th></>}</tr></thead>
            <tbody>{rows.map((m) => (
              <tr key={m.id}><td>{fdate(m.movement_date)}</td><td>{m._p?.name}</td><td>{MOV_LABEL[m.movement_type]}</td>
                <td><Link to={`${DOC_ROUTE[m.source_type]}/${m.source_id}`}>{DOC_TYPE_LABEL[m.source_type]}</Link></td>
                <td className="num">{qty(m.quantity)}</td><td className="num">{money(m.unit_cost)}</td><td className="num">{money(m.total_cost)}</td>
                {pid && <><td className="num">{qty(m._bal)}</td><td className="num">{money(m._val)}</td></>}</tr>
            ))}</tbody></table>
        )}
      </div>
    </>
  )
}

export function AdjustmentList() {
  return (
    <DocList table="inventory_adjustments" type="inventory_adjustment" title="Ajustes de inventario" createPerm="inventory.create" dateField="adjustment_date" newLabel="Ajuste"
      sub="Altas y bajas de existencias (stock inicial, mermas, diferencias de inventario físico). Requieren aprobación."
      searchText={(r) => `${r.doc_number} ${r.reason}`}
      columns={[{ label: 'N.º', render: (r) => <b>{r.doc_number}</b> }, { label: 'Fecha', render: (r) => fdate(r.adjustment_date) }, { label: 'Motivo', render: (r) => r.reason }]} />
  )
}

export function AdjustmentForm() {
  const { id } = useParams()
  const isNew = id === 'nuevo'
  const nav = useNavigate()
  const { org, can } = useAuth()
  const { products, activities } = useCatalog()
  const toast = useToast()
  const [h, setH] = useState<Row>({ adjustment_date: today(), reason: '' })
  const [lines, setLines] = useState<Row[]>([])
  const [oldIds, setOldIds] = useState<string[]>([])
  const [saving, setSaving] = useState(false)
  const { data: doc, loading, reload } = useAsync(async () => {
    if (isNew) return null
    const d = unwrap(await supabase.from('inventory_adjustments').select('*').eq('id', id!).maybeSingle()) as Row | null
    if (!d) return null
    const l = unwrap(await supabase.from('inventory_adjustment_lines').select('*').eq('adjustment_id', id!).order('line_no')) as Row[]
    setH(d); setLines(l.map((x) => ({ ...x, activity_id: x.activity_id || '' }))); setOldIds(l.map((x) => x.id))
    return d
  }, [id, org?.id], null)
  useEffect(() => { if (isNew && !lines.length) setLines([{ product_id: '', quantity_delta: '', unit_cost: '', activity_id: '' }]) }, [isNew])
  const canEdit = (isNew || isEditable(doc?.status)) && can('inventory.create')
  const setLine = (i: number, p: Row) => setLines((ls) => ls.map((l, j) => (j === i ? { ...l, ...p } : l)))
  const save = async () => {
    if (!org) return
    if (!h.reason.trim()) return toast.err('Indique el motivo del ajuste.')
    const valid = lines.filter((l) => l.product_id && num(l.quantity_delta) !== 0)
    if (!valid.length) return toast.err('Agregue al menos una línea con producto y cantidad.')
    if (valid.some((l) => num(l.quantity_delta) > 0 && num(l.unit_cost) <= 0)) return toast.err('Las entradas (+) requieren un costo unitario mayor que cero.')
    setSaving(true)
    try {
      let docId = id!
      const header = { adjustment_date: h.adjustment_date, reason: h.reason.trim() }
      if (isNew) docId = (unwrap(await supabase.from('inventory_adjustments').insert({ ...header, organization_id: org.id }).select('id').single()) as Row).id
      else unwrap(await supabase.from('inventory_adjustments').update(header).eq('id', docId).select('id'))
      unwrap(await supabase.from('inventory_adjustment_lines').insert(valid.map((l, i) => ({ organization_id: org.id, adjustment_id: docId, line_no: i + 1, product_id: l.product_id, quantity_delta: num(l.quantity_delta), unit_cost: num(l.quantity_delta) > 0 ? num(l.unit_cost) : 0, activity_id: l.activity_id || null }))).select('id'))
      if (oldIds.length) unwrap(await supabase.from('inventory_adjustment_lines').delete().in('id', oldIds).select('id'))
      toast.ok('Guardado')
      if (isNew) nav(`/inventario/ajustes/${docId}`, { replace: true }); else await reload()
    } catch (e) { toast.err(errMsg(e)) } finally { setSaving(false) }
  }
  if (!isNew && loading && !doc) return <Spinner />
  return (
    <DocFrame type="inventory_adjustment" doc={doc} onChange={reload} title={isNew ? 'Nuevo ajuste de inventario' : `Ajuste ${doc?.doc_number || ''}`}
      sub="Cantidad positiva = entrada (indique el costo unitario). Cantidad negativa = salida (se valora con el método de la empresa).">
      <div className="card card-pad grid g2">
        <Field label="Fecha *"><input type="date" disabled={!canEdit} value={h.adjustment_date} onChange={(e) => setH({ ...h, adjustment_date: e.target.value })} /></Field>
        <Field label="Motivo *"><input type="text" disabled={!canEdit} value={h.reason} onChange={(e) => setH({ ...h, reason: e.target.value })} /></Field>
      </div>
      <div className="card"><div className="table-wrap">
        <table className="t lines"><thead><tr><th style={{ minWidth: 240 }}>Producto</th><th className="r">Cantidad (+/−)</th><th className="r">Costo unitario (entradas)</th><th>Actividad</th><th /></tr></thead>
          <tbody>{lines.map((l, i) => (
            <tr key={i}><td><select disabled={!canEdit} value={l.product_id} onChange={(e) => setLine(i, { product_id: e.target.value })}><option value="">Producto…</option>{products.filter((p) => p.product_type === 'inventory' && p.active).map((p) => <option key={p.id} value={p.id}>{p.sku} · {p.name}</option>)}</select></td>
              <td><input type="number" step="any" disabled={!canEdit} value={l.quantity_delta} onChange={(e) => setLine(i, { quantity_delta: e.target.value })} /></td>
              <td><input type="number" step="any" disabled={!canEdit || num(l.quantity_delta) <= 0} value={l.unit_cost} onChange={(e) => setLine(i, { unit_cost: e.target.value })} /></td>
              <td><select disabled={!canEdit} value={l.activity_id} onChange={(e) => setLine(i, { activity_id: e.target.value })}><option value="">—</option>{activities.filter((a) => a.active).map((a) => <option key={a.id} value={a.id}>{a.code}</option>)}</select></td>
              <td>{canEdit && <button className="btn sm ghost" onClick={() => setLines(lines.filter((_, j) => j !== i))}>✕</button>}</td></tr>
          ))}</tbody></table></div>
        {canEdit && <div className="card-pad row"><button className="btn" onClick={() => setLines([...lines, { product_id: '', quantity_delta: '', unit_cost: '', activity_id: '' }])}>+ Línea</button><span style={{ flex: 1 }} /><button className="btn primary" disabled={saving} onClick={save}>{saving ? 'Guardando…' : 'Guardar borrador'}</button></div>}
      </div>
    </DocFrame>
  )
}

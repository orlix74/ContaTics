import { useEffect, useMemo, useState } from 'react'
import { Link, useNavigate, useParams } from 'react-router-dom'
import { supabase } from '../lib/supabase'
import { DOC_ROUTE, DOC_TYPE_LABEL, Row, errMsg, unwrap } from '../lib/api'
import { useAsync } from '../lib/hooks'
import { useAuth } from '../context/Auth'
import { useCatalog } from '../context/Catalog'
import { useToast } from '../context/Toast'
import { DocFrame, DocList, isEditable } from '../components/DocParts'
import { Alert, Field, Spinner } from '../components/ui'
import { fdate, money, num, round2, today } from '../lib/format'
import { useRateSync } from './Invoices'

export function JournalList() {
  return (
    <DocList table="journal_entries" type="journal_entry" title="Asientos contables" createPerm="journal.create" dateField="entry_date" newLabel="Asiento manual"
      sub="Asientos manuales y los generados automáticamente por compras, ventas, pagos, cobros e inventario."
      searchText={(r) => `${r.entry_number} ${r.description} ${r.reference}`}
      columns={[
        { label: 'N.º', render: (r) => <b>{r.entry_number ?? 'Borrador'}</b> },
        { label: 'Fecha', render: (r) => fdate(r.entry_date) },
        { label: 'Glosa', render: (r) => r.description },
        { label: 'Origen', render: (r) => (r.source_type ? DOC_TYPE_LABEL[r.source_type] || r.source_type : r.entry_kind === 'reversal' ? 'Reversión' : 'Manual') },
        { label: 'Total (base)', right: true, render: (r) => money(r.total_debit_base) },
      ]} />
  )
}

export function JournalForm() {
  const { id } = useParams()
  const isNew = id === 'nuevo'
  const nav = useNavigate()
  const { org, can } = useAuth()
  const { accounts, activities, currencies, baseCurrency } = useCatalog()
  const toast = useToast()
  const [h, setH] = useState<Row>({ entry_date: today(), description: '', reference: '', currency_code: baseCurrency, exchange_rate: 1 })
  const [lines, setLines] = useState<Row[]>([])
  const [oldIds, setOldIds] = useState<string[]>([])
  const [saving, setSaving] = useState(false)
  const [rel, setRel] = useState<Row>({})

  const { data: doc, loading, reload } = useAsync(async () => {
    if (isNew) return null
    const d = unwrap(await supabase.from('journal_entries').select('*').eq('id', id!).maybeSingle()) as Row | null
    if (!d) return null
    const l = unwrap(await supabase.from('journal_entry_lines').select('*').eq('entry_id', id!).order('line_no')) as Row[]
    setH({ ...d, reference: d.reference || '', _loadedCurrency: d.currency_code, _loadedDate: d.entry_date })
    setLines(l.map((x) => ({ ...x, activity_id: x.activity_id || '', description: x.description || '', debit: num(x.debit) || '', credit: num(x.credit) || '' })))
    setOldIds(l.map((x) => x.id))
    const ids = [d.reverses_entry_id, d.reversed_by_entry_id].filter(Boolean)
    if (ids.length) { const r = unwrap(await supabase.from('journal_entries').select('id,entry_number').in('id', ids)) as Row[]; setRel(Object.fromEntries(r.map((x) => [x.id, x.entry_number]))) }
    return d
  }, [id, org?.id], null)

  const editable = isNew || (isEditable(doc?.status) && doc?.entry_kind === 'manual')
  const canEdit = editable && can('journal.create')
  useRateSync(h, setH, 'entry_date', canEdit, isNew)
  useEffect(() => { if (isNew && !lines.length) setLines([{ account_id: '', activity_id: '', description: '', debit: '', credit: '' }, { account_id: '', activity_id: '', description: '', debit: '', credit: '' }]) }, [isNew])

  const rate = num(h.exchange_rate) || 1
  const tot = useMemo(() => lines.reduce((a, l) => ({ d: a.d + round2(num(l.debit) * rate), c: a.c + round2(num(l.credit) * rate) }), { d: 0, c: 0 }), [lines, rate])
  const diff = round2(tot.d - tot.c)
  const setLine = (i: number, p: Row) => setLines((ls) => ls.map((l, j) => (j === i ? { ...l, ...p } : l)))

  const save = async () => {
    if (!org) return
    if (!h.description.trim()) return toast.err('Escriba la glosa del asiento.')
    const valid = lines.filter((l) => l.account_id && (num(l.debit) > 0 || num(l.credit) > 0))
    if (valid.length < 2) return toast.err('El asiento necesita al menos dos líneas con cuenta e importe.')
    if (valid.some((l) => num(l.debit) > 0 && num(l.credit) > 0)) return toast.err('Una línea no puede tener débito y crédito a la vez.')
    setSaving(true)
    try {
      const header = { entry_date: h.entry_date, description: h.description.trim(), reference: h.reference || null, currency_code: h.currency_code, exchange_rate: rate }
      let docId = id!
      if (isNew) docId = (unwrap(await supabase.from('journal_entries').insert({ ...header, organization_id: org.id }).select('id').single()) as Row).id
      else unwrap(await supabase.from('journal_entries').update(header).eq('id', docId).select('id'))
      const rows = valid.map((l, i) => ({ organization_id: org.id, entry_id: docId, line_no: i + 1, account_id: l.account_id, activity_id: l.activity_id || null, description: l.description || null, debit: num(l.debit), credit: num(l.credit) }))
      unwrap(await supabase.from('journal_entry_lines').insert(rows).select('id'))
      if (oldIds.length) unwrap(await supabase.from('journal_entry_lines').delete().in('id', oldIds).select('id'))
      toast.ok('Asiento guardado')
      if (isNew) nav(`/contabilidad/asientos/${docId}`, { replace: true }); else await reload()
    } catch (e) { toast.err(errMsg(e)) } finally { setSaving(false) }
  }

  if (!isNew && loading && !doc) return <Spinner />
  if (!isNew && !loading && !doc) return <Alert kind="err">No se encontró el asiento. <Link to="/contabilidad/asientos">Volver</Link></Alert>
  const foreign = h.currency_code !== baseCurrency
  const src = doc?.source_type && doc?.source_id ? `${DOC_ROUTE[doc.source_type]}/${doc.source_id}` : null

  return (
    <DocFrame type="journal_entry" doc={doc} onChange={reload} title={isNew ? 'Nuevo asiento manual' : `Asiento ${doc?.entry_number ?? '(borrador)'}`}
      sub={doc?.entry_kind === 'auto' ? 'Generado automáticamente: no puede modificarse. Para corregirlo, anule el documento de origen.' : 'Los asientos contabilizados no se editan: se corrigen con una reversión autorizada.'}>
      {doc?.entry_kind === 'auto' && src && <Alert kind="info">Documento de origen: <Link to={src}>{DOC_TYPE_LABEL[doc.source_type]}</Link></Alert>}
      {doc?.reversed_by_entry_id && <Alert kind="warn">Este asiento fue revertido por el asiento N.º <Link to={`/contabilidad/asientos/${doc.reversed_by_entry_id}`}>{rel[doc.reversed_by_entry_id]}</Link>.</Alert>}
      {doc?.reverses_entry_id && <Alert kind="info">Revierte el asiento N.º <Link to={`/contabilidad/asientos/${doc.reverses_entry_id}`}>{rel[doc.reverses_entry_id]}</Link>.</Alert>}
      <div className="card card-pad stack">
        <div className="grid g4">
          <Field label="Fecha *"><input type="date" disabled={!canEdit} value={h.entry_date} onChange={(e) => setH({ ...h, entry_date: e.target.value })} /></Field>
          <Field label="Referencia"><input type="text" disabled={!canEdit} value={h.reference} onChange={(e) => setH({ ...h, reference: e.target.value })} /></Field>
          <Field label="Moneda"><select disabled={!canEdit} value={h.currency_code} onChange={(e) => setH({ ...h, currency_code: e.target.value })}>{currencies.map((c) => <option key={c.code} value={c.code}>{c.code}</option>)}</select></Field>
          <Field label="Tipo de cambio"><input type="number" step="0.0001" disabled={!canEdit || !foreign} value={h.exchange_rate} onChange={(e) => setH({ ...h, exchange_rate: e.target.value })} /></Field>
        </div>
        <Field label="Glosa *"><input type="text" disabled={!canEdit} value={h.description} onChange={(e) => setH({ ...h, description: e.target.value })} /></Field>
      </div>
      <div className="card">
        <div className="table-wrap">
          <table className="t lines">
            <thead><tr><th style={{ minWidth: 260 }}>Cuenta</th><th>Actividad</th><th style={{ minWidth: 160 }}>Detalle</th><th className="r">Débito</th><th className="r">Crédito</th>{!canEdit && <th className="r">Débito {baseCurrency}</th>}{!canEdit && <th className="r">Crédito {baseCurrency}</th>}<th /></tr></thead>
            <tbody>
              {lines.map((l, i) => (
                <tr key={i}>
                  <td><select disabled={!canEdit} value={l.account_id} onChange={(e) => setLine(i, { account_id: e.target.value })}><option value="">Cuenta…</option>{accounts.filter((a) => (a.is_postable && a.active) || a.id === l.account_id).map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name}</option>)}</select></td>
                  <td><select disabled={!canEdit} value={l.activity_id} onChange={(e) => setLine(i, { activity_id: e.target.value })}><option value="">—</option>{activities.filter((a) => a.active).map((a) => <option key={a.id} value={a.id}>{a.code}</option>)}</select></td>
                  <td><input type="text" disabled={!canEdit} value={l.description} onChange={(e) => setLine(i, { description: e.target.value })} /></td>
                  <td><input type="number" step="any" style={{ width: 120 }} disabled={!canEdit} value={l.debit} onChange={(e) => setLine(i, { debit: e.target.value, credit: e.target.value ? '' : l.credit })} /></td>
                  <td><input type="number" step="any" style={{ width: 120 }} disabled={!canEdit} value={l.credit} onChange={(e) => setLine(i, { credit: e.target.value, debit: e.target.value ? '' : l.debit })} /></td>
                  {!canEdit && <td className="num">{money(l.debit_base)}</td>}{!canEdit && <td className="num">{money(l.credit_base)}</td>}
                  <td>{canEdit && <button className="btn sm ghost" aria-label="Quitar línea" onClick={() => setLines(lines.filter((_, j) => j !== i))}>✕</button>}</td>
                </tr>
              ))}
            </tbody>
            <tfoot><tr><td colSpan={3} className="num">Totales ({baseCurrency})</td><td className="num">{money(canEdit ? tot.d : doc?.total_debit_base)}</td><td className="num">{money(canEdit ? tot.c : doc?.total_credit_base)}</td>{!canEdit && <td colSpan={2} />}<td /></tr></tfoot>
          </table>
        </div>
        {canEdit && (
          <div className="card-pad row">
            <button className="btn" onClick={() => setLines([...lines, { account_id: '', activity_id: '', description: '', debit: '', credit: '' }])}>+ Agregar línea</button>
            <span className={`badge ${diff === 0 && tot.d > 0 ? 'b-ok' : 'b-warn'}`}>{diff === 0 && tot.d > 0 ? 'Asiento cuadrado' : `Diferencia: ${money(diff)}`}</span>
            <span style={{ flex: 1 }} />
            <button className="btn primary" disabled={saving} onClick={save}>{saving ? 'Guardando…' : 'Guardar borrador'}</button>
          </div>
        )}
      </div>
    </DocFrame>
  )
}

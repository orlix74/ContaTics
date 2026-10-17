import { useEffect, useMemo, useState } from 'react'
import { supabase } from '../lib/supabase'
import { Row, errMsg, rpc, unwrap, DOC_TYPE_LABEL } from '../lib/api'
import { useAsync } from '../lib/hooks'
import { useAuth } from '../context/Auth'
import { useCatalog } from '../context/Catalog'
import { useToast } from '../context/Toast'
import CrudPage from '../components/CrudPage'
import { Alert, ConfirmModal, Empty, Field, Modal, NoAccess, PageHeader, PromptModal, Spinner, Tabs } from '../components/ui'
import { fdate, num } from '../lib/format'

const postable = (accounts: Row[]) => accounts.filter((a) => a.is_postable && a.active).map((a) => ({ value: a.id, label: `${a.code} · ${a.name}` }))

/* ---------------- Empresa ---------------- */
export function CompanySettings() {
  const { org, can, reload } = useAuth()
  const toast = useToast()
  const [f, setF] = useState<Row>({})
  useEffect(() => { if (org) setF({ ...org }) }, [org?.id])
  if (!org) return null
  const canEdit = can('config.manage')
  const save = async () => {
    const { error } = await supabase.from('organizations').update({ legal_name: f.legal_name, trade_name: f.trade_name || null, tax_id: f.tax_id || null, fiscal_address: f.fiscal_address || null }).eq('id', org.id)
    if (error) return toast.err(errMsg(error))
    toast.ok('Datos de la empresa guardados'); reload()
  }
  return (
    <>
      <PageHeader title="Datos de la empresa" sub="Información legal y tributaria" />
      <div className="card card-pad stack" style={{ maxWidth: 760 }}>
        <div className="grid g2">
          <Field label="Razón social"><input type="text" disabled={!canEdit} value={f.legal_name || ''} onChange={(e) => setF({ ...f, legal_name: e.target.value })} /></Field>
          <Field label="Nombre comercial"><input type="text" disabled={!canEdit} value={f.trade_name || ''} onChange={(e) => setF({ ...f, trade_name: e.target.value })} /></Field>
          <Field label="NIT / identificación tributaria"><input type="text" disabled={!canEdit} value={f.tax_id || ''} onChange={(e) => setF({ ...f, tax_id: e.target.value })} /></Field>
          <Field label="Moneda base" hint="Se define al crear la empresa y no cambia una vez que hay asientos."><input type="text" disabled value={org.base_currency} /></Field>
        </div>
        <Field label="Domicilio fiscal"><input type="text" disabled={!canEdit} value={f.fiscal_address || ''} onChange={(e) => setF({ ...f, fiscal_address: e.target.value })} /></Field>
        {canEdit && <div><button className="btn primary" onClick={save}>Guardar</button></div>}
      </div>
    </>
  )
}

/* ---------------- Monedas y tipos de cambio ---------------- */
export function Currencies() {
  const { currencies, baseCurrency } = useCatalog()
  return (
    <>
      <CrudPage table="exchange_rates" title="Monedas y tipos de cambio" orderBy="rate_date" orderDesc writePerm={['config.manage', 'accounts.manage']} newLabel="Tipo de cambio"
        sub={<>Moneda base: <b>{baseCurrency}</b>. El tipo de cambio es la cantidad de {baseCurrency} por 1 unidad de la moneda extranjera. Los documentos conservan el tipo de cambio con el que se registraron.</>}
        searchKeys={['currency_code']}
        fields={[
          { key: 'currency_code', label: 'Moneda', type: 'select', required: true, lockOnEdit: true, options: currencies.filter((c) => c.code !== baseCurrency).map((c) => ({ value: c.code, label: `${c.code} — ${c.name}` })) },
          { key: 'rate_date', label: 'Fecha', type: 'date', required: true, lockOnEdit: true },
          { key: 'rate', label: `Tipo de cambio (${baseCurrency} por unidad)`, type: 'number', required: true, step: '0.0001' },
          { key: 'source', label: 'Fuente (opcional)' },
        ]}
        columns={[{ label: 'Fecha', render: (r) => fdate(r.rate_date) }, { label: 'Moneda', key: 'currency_code' }, { label: 'Tipo de cambio', key: 'rate', right: true }, { label: 'Fuente', key: 'source' }]}
        canDelete
        validate={(f) => (num(f.rate) <= 0 ? 'El tipo de cambio debe ser mayor que cero.' : null)}
      />
    </>
  )
}

/* ---------------- Impuestos ---------------- */
export function Taxes() {
  const { accounts, reload } = useCatalog()
  return (
    <CrudPage table="tax_types" title="Impuestos" orderBy="code" writePerm={['config.manage', 'accounts.manage']} onChanged={reload} newLabel="Impuesto"
      sub="Configure cada impuesto: tasa, vigencia, tratamiento contable y cuentas. Los valores precargados son ejemplos: verifíquelos con su contador y la normativa vigente."
      fields={[
        { key: 'code', label: 'Código', required: true, lockOnEdit: true },
        { key: 'name', label: 'Nombre', required: true },
        { key: 'rate', label: 'Tasa (%)', type: 'number', required: true, step: '0.01' },
        { key: 'category', label: 'Categoría tributaria' },
        { key: 'applies_to', label: 'Aplica a', type: 'select', required: true, default: 'both', options: [{ value: 'purchase', label: 'Compras' }, { value: 'sales', label: 'Ventas' }, { value: 'both', label: 'Compras y ventas' }] },
        { key: 'treatment', label: 'Tratamiento contable', type: 'select', required: true, hint: 'Recuperable: va a una cuenta de crédito fiscal. Costo/gasto: se suma al costo. Por pagar: pasivo en ventas.', options: [{ value: 'recoverable', label: 'Recuperable (compras)' }, { value: 'cost', label: 'No recuperable: suma al costo/gasto (compras)' }, { value: 'payable', label: 'Por pagar (ventas)' }] },
        { key: 'account_id', label: 'Cuenta contable relacionada', type: 'select', options: postable(accounts), blankOption: '— Ninguna —', hint: 'Obligatoria para tasas mayores a 0 con tratamiento recuperable o por pagar.' },
        { key: 'valid_from', label: 'Vigente desde', type: 'date' },
        { key: 'valid_to', label: 'Vigente hasta', type: 'date' },
        { key: 'active', label: 'Activo', type: 'checkbox', default: true },
        { key: 'notes', label: 'Notas', type: 'textarea' },
      ]}
      columns={[{ label: 'Código', key: 'code' }, { label: 'Nombre', key: 'name' }, { label: 'Tasa %', key: 'rate', right: true }, { label: 'Aplica a', render: (r) => ({ purchase: 'Compras', sales: 'Ventas', both: 'Ambos' } as any)[r.applies_to] },
        { label: 'Tratamiento', render: (r) => ({ recoverable: 'Recuperable', cost: 'Costo/gasto', payable: 'Por pagar' } as any)[r.treatment] }, { label: 'Vigencia', render: (r) => (r.valid_from || r.valid_to ? `${fdate(r.valid_from) || '…'} → ${fdate(r.valid_to) || '…'}` : 'Sin límite') }, { label: 'Estado', key: 'active' }]}
      validate={(f) => (f.treatment !== 'cost' && num(f.rate) > 0 && !f.account_id ? 'Seleccione la cuenta contable del impuesto.' : null)}
    />
  )
}

/* ---------------- Periodos ---------------- */
export function Periods() {
  const { org, can } = useAuth()
  const toast = useToast()
  const [year, setYear] = useState(new Date().getFullYear() + 1)
  const [act, setAct] = useState<{ p: Row; kind: 'close' | 'reopen' } | null>(null)
  const { data, loading, reload } = useAsync(async () => unwrap(await supabase.from('accounting_periods').select('*').eq('organization_id', org!.id).order('start_date', { ascending: false })) as Row[], [org?.id], [])
  const gen = async () => { try { await rpc('generate_periods', { p_org: org!.id, p_year: year }); toast.ok(`Periodos de ${year} generados`); reload() } catch (e) { toast.err(errMsg(e)) } }
  const run = async (reason: string) => {
    try {
      if (act!.kind === 'close') await rpc('close_period', { p_period: act!.p.id, p_reason: reason || null })
      else await rpc('reopen_period', { p_period: act!.p.id, p_reason: reason })
      toast.ok(act!.kind === 'close' ? 'Periodo cerrado' : 'Periodo reabierto'); setAct(null); reload()
    } catch (e) { toast.err(errMsg(e)) }
  }
  return (
    <>
      <PageHeader title="Periodos contables" sub="Un periodo cerrado bloquea cualquier contabilización con fechas dentro de él. La reapertura requiere autorización y queda registrada.">
        {(can('config.manage') || can('periods.close')) && (
          <div className="row"><input type="number" style={{ width: 100 }} value={year} onChange={(e) => setYear(num(e.target.value))} /><button className="btn" onClick={gen}>Generar periodos del año</button></div>
        )}
      </PageHeader>
      <div className="card table-wrap">
        {loading ? <Spinner /> : !data?.length ? <Empty>Sin periodos.</Empty> : (
          <table className="t"><thead><tr><th>Periodo</th><th>Desde</th><th>Hasta</th><th>Estado</th><th /></tr></thead>
            <tbody>{data.map((p) => (
              <tr key={p.id}><td><b>{p.name}</b></td><td>{fdate(p.start_date)}</td><td>{fdate(p.end_date)}</td>
                <td><span className={`badge ${p.status === 'open' ? 'b-ok' : 'b-off'}`}>{p.status === 'open' ? 'Abierto' : 'Cerrado'}</span></td>
                <td style={{ textAlign: 'right' }}>
                  {p.status === 'open' && can('periods.close') && <button className="btn sm" onClick={() => setAct({ p, kind: 'close' })}>Cerrar</button>}
                  {p.status === 'closed' && can('periods.reopen') && <button className="btn sm danger" onClick={() => setAct({ p, kind: 'reopen' })}>Reabrir (excepcional)</button>}
                </td></tr>
            ))}</tbody></table>
        )}
      </div>
      {act && <PromptModal title={act.kind === 'close' ? `Cerrar periodo ${act.p.name}` : `Reabrir periodo ${act.p.name}`} label={act.kind === 'close' ? 'Comentario (opcional)' : 'Motivo de la reapertura (obligatorio)'} required={act.kind === 'reopen'} confirmText={act.kind === 'close' ? 'Cerrar periodo' : 'Reabrir'} onCancel={() => setAct(null)} onConfirm={run} />}
    </>
  )
}

/* ---------------- Reglas contables ---------------- */
const RULES: [string, string][] = [
  ['purchase.payable', 'Cuentas por pagar a proveedores'], ['purchase.expense', 'Gasto por defecto en compras (si la línea no indica cuenta)'],
  ['sales.receivable', 'Cuentas por cobrar a clientes'], ['sales.revenue', 'Ingresos por defecto en ventas'], ['sales.cogs', 'Costo de ventas por defecto'],
  ['inventory.asset', 'Inventarios por defecto'], ['inventory.adjustment', 'Ajustes de inventario (contrapartida)'],
  ['fx.gain', 'Ganancia por diferencia de cambio'], ['fx.loss', 'Pérdida por diferencia de cambio'],
]
export function Rules() {
  const { org, can } = useAuth()
  const { accounts, rules, reload } = useCatalog()
  const toast = useToast()
  const [vals, setVals] = useState<Record<string, string>>({})
  useEffect(() => { setVals(Object.fromEntries(RULES.map(([k]) => [k, rules[k] || '']))) }, [rules])
  const canEdit = can('accounts.manage')
  const save = async () => {
    try {
      for (const [k] of RULES) {
        unwrap(await supabase.from('accounting_rules').upsert({ organization_id: org!.id, rule_key: k, account_id: vals[k] || null }, { onConflict: 'organization_id,rule_key' }).select())
      }
      toast.ok('Reglas guardadas'); reload()
    } catch (e) { toast.err(errMsg(e)) }
  }
  return (
    <>
      <PageHeader title="Reglas contables" sub="Cuentas que el sistema usa al generar asientos automáticos. Los productos y las líneas pueden indicar cuentas propias que tienen prioridad." />
      <div className="card card-pad stack" style={{ maxWidth: 820 }}>
        {RULES.map(([k, l]) => (
          <Field key={k} label={l}>
            <select disabled={!canEdit} value={vals[k] || ''} onChange={(e) => setVals({ ...vals, [k]: e.target.value })}>
              <option value="">— Sin configurar —</option>
              {postable(accounts).map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
            </select>
          </Field>
        ))}
        {canEdit && <div><button className="btn primary" onClick={save}>Guardar reglas</button></div>}
      </div>
    </>
  )
}

/* ---------------- Aprobaciones ---------------- */
export function ApprovalSettings() {
  const { org, can } = useAuth()
  const toast = useToast()
  const { data, loading, reload } = useAsync(async () => unwrap(await supabase.from('approval_workflows').select('*').eq('organization_id', org!.id)) as Row[], [org?.id], [])
  const [rows, setRows] = useState<Row[]>([])
  useEffect(() => setRows(data || []), [data])
  const canEdit = can('config.manage')
  const save = async (r: Row) => {
    const { error } = await supabase.from('approval_workflows').update({ required_approvals: num(r.required_approvals), allow_self_approval: r.allow_self_approval, active: r.active }).eq('id', r.id)
    if (error) return toast.err(errMsg(error))
    toast.ok('Guardado'); reload()
  }
  const set = (id: string, k: string, v: any) => setRows(rows.map((r) => (r.id === id ? { ...r, [k]: v } : r)))
  return (
    <>
      <PageHeader title="Flujos de aprobación" sub="Todo documento con efectos contables debe aprobarse antes de contabilizarse. Aquí define cuántas aprobaciones requiere cada tipo." />
      <Alert kind="info">Regla general: nadie aprueba sus propios documentos. Permitir la autoaprobación es una excepción que queda registrada en la auditoría.</Alert>
      <div className="card table-wrap" style={{ marginTop: 14 }}>
        {loading ? <Spinner /> : (
          <table className="t"><thead><tr><th>Tipo de documento</th><th>Aprobaciones requeridas</th><th>Permitir autoaprobación</th><th>Activo</th><th /></tr></thead>
            <tbody>{rows.map((r) => (
              <tr key={r.id}><td>{DOC_TYPE_LABEL[r.doc_type]}</td>
                <td><input type="number" min={1} max={5} style={{ width: 80 }} disabled={!canEdit} value={r.required_approvals} onChange={(e) => set(r.id, 'required_approvals', e.target.value)} /></td>
                <td><input type="checkbox" disabled={!canEdit} checked={r.allow_self_approval} onChange={(e) => set(r.id, 'allow_self_approval', e.target.checked)} /></td>
                <td><input type="checkbox" disabled={!canEdit} checked={r.active} onChange={(e) => set(r.id, 'active', e.target.checked)} /></td>
                <td>{canEdit && <button className="btn sm" onClick={() => save(r)}>Guardar</button>}</td></tr>
            ))}</tbody></table>
        )}
      </div>
    </>
  )
}

/* ---------------- Inventario: valoración ---------------- */
export function InventorySettings() {
  const { org, can } = useAuth()
  const { settings, reload } = useCatalog()
  const toast = useToast()
  const [f, setF] = useState<Row>({})
  const { data: hasMov } = useAsync(async () => { const { count } = await supabase.from('inventory_movements').select('id', { count: 'exact', head: true }).eq('organization_id', org!.id); return (count || 0) > 0 }, [org?.id], false)
  useEffect(() => { if (settings) setF({ ...settings }) }, [settings])
  const canEdit = can('config.manage')
  const save = async () => {
    const { error } = await supabase.from('inventory_settings').update({ valuation_method: f.valuation_method, effective_from: f.effective_from, cost_decimals: num(f.cost_decimals), allow_negative_stock: f.allow_negative_stock }).eq('organization_id', org!.id)
    if (error) return toast.err(errMsg(error))
    toast.ok('Configuración guardada'); reload()
  }
  return (
    <>
      <PageHeader title="Valoración de inventarios" sub="Método de costeo y reglas de existencias de esta empresa." />
      {hasMov && <Alert kind="warn">Ya existen movimientos de inventario: el método de valoración y la precisión del costo quedan bloqueados. Cambiarlos requiere un proceso formal autorizado (no incluido en esta versión).</Alert>}
      <div className="card card-pad stack" style={{ maxWidth: 680, marginTop: 14 }}>
        <Field label="Método de valoración"><select disabled={!canEdit || hasMov} value={f.valuation_method || ''} onChange={(e) => setF({ ...f, valuation_method: e.target.value })}><option value="weighted_average">Promedio ponderado</option><option value="fifo">PEPS / FIFO (primero en entrar, primero en salir)</option></select></Field>
        <div className="grid g2">
          <Field label="Vigente desde"><input type="date" disabled={!canEdit} value={f.effective_from || ''} onChange={(e) => setF({ ...f, effective_from: e.target.value })} /></Field>
          <Field label="Decimales del costo unitario" hint="Informativo en pantallas; el sistema guarda 6."><input type="number" min={2} max={6} disabled={!canEdit || hasMov} value={f.cost_decimals ?? ''} onChange={(e) => setF({ ...f, cost_decimals: e.target.value })} /></Field>
        </div>
        <label className="check"><input type="checkbox" disabled={!canEdit} checked={!!f.allow_negative_stock} onChange={(e) => setF({ ...f, allow_negative_stock: e.target.checked })} /> Permitir existencias negativas (se valoran al último costo promedio)</label>
        {canEdit && <div><button className="btn primary" onClick={save}>Guardar</button></div>}
      </div>
    </>
  )
}

/* ---------------- Numeración y métodos de pago ---------------- */
export function Numbering() {
  const { org, can } = useAuth()
  const toast = useToast()
  const { data, loading, reload } = useAsync(async () => unwrap(await supabase.from('document_sequences').select('*').eq('organization_id', org!.id).order('doc_type')) as Row[], [org?.id], [])
  const [rows, setRows] = useState<Row[]>([])
  useEffect(() => setRows(data || []), [data])
  const canEdit = can('config.manage')
  const save = async (r: Row) => {
    const { error } = await supabase.from('document_sequences').update({ prefix: r.prefix, padding: num(r.padding), next_number: num(r.next_number) }).eq('organization_id', org!.id).eq('doc_type', r.doc_type)
    if (error) return toast.err(errMsg(error))
    toast.ok('Guardado'); reload()
  }
  const set = (t: string, k: string, v: any) => setRows(rows.map((r) => (r.doc_type === t ? { ...r, [k]: v } : r)))
  return (
    <>
      <PageHeader title="Numeración documental" sub="Prefijo y correlativo de cada tipo de documento. El siguiente número solo puede aumentar." />
      <div className="card table-wrap">
        {loading ? <Spinner /> : (
          <table className="t"><thead><tr><th>Documento</th><th>Prefijo</th><th>Dígitos</th><th>Próximo número</th><th /></tr></thead>
            <tbody>{rows.map((r) => (
              <tr key={r.doc_type}><td>{DOC_TYPE_LABEL[r.doc_type]}</td>
                <td><input type="text" style={{ width: 90 }} disabled={!canEdit} value={r.prefix} onChange={(e) => set(r.doc_type, 'prefix', e.target.value)} /></td>
                <td><input type="number" style={{ width: 80 }} disabled={!canEdit} value={r.padding} onChange={(e) => set(r.doc_type, 'padding', e.target.value)} /></td>
                <td><input type="number" style={{ width: 120 }} disabled={!canEdit} value={r.next_number} onChange={(e) => set(r.doc_type, 'next_number', e.target.value)} /></td>
                <td>{canEdit && <button className="btn sm" onClick={() => save(r)}>Guardar</button>}</td></tr>
            ))}</tbody></table>
        )}
      </div>
      <div style={{ height: 28 }} />
      <CrudPage table="payment_methods" title="Métodos de pago y cobro" orderBy="name" writePerm="config.manage" canDelete newLabel="Método"
        fields={[{ key: 'name', label: 'Nombre', required: true }, { key: 'kind', label: 'Tipo', type: 'select', required: true, default: 'bank_transfer', options: [{ value: 'cash', label: 'Efectivo' }, { value: 'bank_transfer', label: 'Transferencia' }, { value: 'check', label: 'Cheque' }, { value: 'card', label: 'Tarjeta' }, { value: 'other', label: 'Otro' }] }, { key: 'active', label: 'Activo', type: 'checkbox', default: true }]}
        columns={[{ label: 'Nombre', key: 'name' }, { label: 'Tipo', key: 'kind' }, { label: 'Estado', key: 'active' }]} />
    </>
  )
}

/* ---------------- Integraciones ---------------- */
export function Integrations() {
  return (
    <>
      <PageHeader title="Integraciones" sub="Conexiones con servicios externos." />
      <div className="card card-pad stack" style={{ maxWidth: 760 }}>
        <Alert kind="info">En esta primera versión la información tributaria de las facturas se <b>registra manualmente</b> (número de factura, número de autorización, impuestos).</Alert>
        <div><b>Servicios tributarios / facturación electrónica</b><div className="muted small">Estado: no disponible. La estructura de datos ya incluye los campos de autorización para conectar el servicio correspondiente en una versión futura, sin rehacer el sistema.</div></div>
        <div><b>Importación de extractos bancarios</b><div className="muted small">Disponible mediante archivos CSV o Excel (Tesorería › Extractos).</div></div>
        <div><b>Notificaciones por correo de aprobaciones</b><div className="muted small">Estado: pendiente para una versión futura.</div></div>
      </div>
    </>
  )
}

/* ---------------- Plantillas de estados financieros ---------------- */
export function StatementTemplates() {
  const { org, can } = useAuth()
  const { accounts } = useCatalog()
  const toast = useToast()
  const canEdit = can('accounts.manage')
  const [tplId, setTplId] = useState('')
  const [rowEdit, setRowEdit] = useState<Row | null>(null)
  const [newTpl, setNewTpl] = useState<Row | null>(null)
  const [delRow, setDelRow] = useState<Row | null>(null)
  const { data: tpls, reload: reloadT } = useAsync(async () => unwrap(await supabase.from('financial_statement_templates').select('*').eq('organization_id', org!.id).order('name')) as Row[], [org?.id], [])
  useEffect(() => { if (!tplId && tpls?.length) setTplId(tpls[0].id) }, [tpls])
  const { data, loading, reload } = useAsync(async () => {
    if (!tplId) return { rows: [] as Row[], maps: [] as Row[] }
    const rows = unwrap(await supabase.from('financial_statement_rows').select('*').eq('template_id', tplId).order('sort_order')) as Row[]
    const maps = rows.length ? (unwrap(await supabase.from('financial_statement_mappings').select('*').in('row_id', rows.map((r) => r.id))) as Row[]) : []
    return { rows, maps }
  }, [tplId], { rows: [], maps: [] })
  const accLabel = (id: string) => { const a = accounts.find((x) => x.id === id); return a ? `${a.code} ${a.name}` : id }

  const openRow = (r?: Row) => {
    const rows = data?.rows || []
    setRowEdit(r ? { ...r, formula: r.formula || '', maps: (data?.maps || []).filter((m) => m.row_id === r.id).map((m) => ({ account_id: m.account_id, include_descendants: m.include_descendants })) }
      : { code: '', label: '', row_type: 'accounts', sort_order: (rows[rows.length - 1]?.sort_order || 0) + 10, formula: '', sign: 1, indent: 0, maps: [] })
  }
  const saveRow = async () => {
    const r = rowEdit!
    if (!r.code?.trim() || !r.label?.trim()) return toast.err('Complete el código y la etiqueta.')
    if (r.row_type === 'subtotal' && !String(r.formula).trim()) return toast.err('Indique la fórmula del subtotal, por ejemplo A1+A2.')
    try {
      const payload = { code: r.code.trim(), label: r.label, row_type: r.row_type, sort_order: num(r.sort_order), formula: r.row_type === 'subtotal' ? r.formula : null, sign: num(r.sign) >= 0 ? 1 : -1, indent: num(r.indent) }
      let id = r.id
      if (id) unwrap(await supabase.from('financial_statement_rows').update(payload).eq('id', id).select())
      else id = (unwrap(await supabase.from('financial_statement_rows').insert({ ...payload, organization_id: org!.id, template_id: tplId }).select('id').single()) as Row).id
      unwrap(await supabase.from('financial_statement_mappings').delete().eq('row_id', id).select())
      if (r.row_type === 'accounts' && r.maps.length) unwrap(await supabase.from('financial_statement_mappings').insert(r.maps.map((m: Row) => ({ organization_id: org!.id, row_id: id, account_id: m.account_id, include_descendants: m.include_descendants }))).select())
      toast.ok('Fila guardada'); setRowEdit(null); reload()
    } catch (e) { toast.err(errMsg(e)) }
  }
  const createTpl = async () => {
    try {
      const r = unwrap(await supabase.from('financial_statement_templates').insert({ organization_id: org!.id, name: newTpl!.name, kind: newTpl!.kind }).select('id').single()) as Row
      setNewTpl(null); await reloadT(); setTplId(r.id)
    } catch (e) { toast.err(errMsg(e)) }
  }
  const removeRow = async () => {
    try { unwrap(await supabase.from('financial_statement_rows').delete().eq('id', delRow!.id).select()); setDelRow(null); reload() } catch (e) { toast.err(errMsg(e)) }
  }
  if (!can('data.view')) return <NoAccess />
  return (
    <>
      <PageHeader title="Plantillas de estados financieros" sub="Defina filas, cuentas asociadas, fórmulas y signos. La presentación es independiente de la jerarquía del plan de cuentas.">
        {canEdit && <button className="btn" onClick={() => setNewTpl({ name: '', kind: 'other' })}>+ Nueva plantilla</button>}
        {canEdit && tplId && <button className="btn primary" onClick={() => openRow()}>+ Fila</button>}
      </PageHeader>
      <div className="toolbar"><Field label="Plantilla"><select value={tplId} onChange={(e) => setTplId(e.target.value)}>{(tpls || []).map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}</select></Field></div>
      <Alert kind="info">Valor de una fila de cuentas = <b>signo × (débitos − créditos)</b> de sus cuentas. Use signo −1 para pasivos, patrimonio e ingresos. Una cuenta no debe aparecer en dos filas de la misma plantilla (se advierte en el reporte).</Alert>
      <div className="card table-wrap" style={{ marginTop: 14 }}>
        {loading ? <Spinner /> : !data?.rows.length ? <Empty>Esta plantilla no tiene filas.</Empty> : (
          <table className="t"><thead><tr><th>Orden</th><th>Código</th><th>Etiqueta</th><th>Tipo</th><th>Cuentas / fórmula</th><th>Signo</th><th /></tr></thead>
            <tbody>{data.rows.map((r) => (
              <tr key={r.id}><td>{r.sort_order}</td><td><b>{r.code}</b></td><td style={{ paddingLeft: 12 + r.indent * 16 }}>{r.label}</td>
                <td>{({ header: 'Encabezado', accounts: 'Cuentas', subtotal: 'Subtotal' } as any)[r.row_type]}</td>
                <td className="small">{r.row_type === 'subtotal' ? <code>{r.formula}</code> : r.row_type === 'accounts' ? data.maps.filter((m) => m.row_id === r.id).map((m) => accLabel(m.account_id) + (m.include_descendants ? ' (+sub)' : '')).join(' · ') : ''}</td>
                <td>{r.row_type === 'accounts' ? (r.sign > 0 ? '+1' : '−1') : ''}</td>
                <td className="nowrap" style={{ textAlign: 'right' }}>{canEdit && <><button className="btn sm" onClick={() => openRow(r)}>Editar</button> <button className="btn sm danger" onClick={() => setDelRow(r)}>Quitar</button></>}</td></tr>
            ))}</tbody></table>
        )}
      </div>
      {rowEdit && (
        <Modal wide title={rowEdit.id ? 'Editar fila' : 'Nueva fila'} onClose={() => setRowEdit(null)} footer={<><button className="btn" onClick={() => setRowEdit(null)}>Cancelar</button><button className="btn primary" onClick={saveRow}>Guardar fila</button></>}>
          <div className="grid g3">
            <Field label="Código"><input type="text" value={rowEdit.code} onChange={(e) => setRowEdit({ ...rowEdit, code: e.target.value })} /></Field>
            <Field label="Etiqueta"><input type="text" value={rowEdit.label} onChange={(e) => setRowEdit({ ...rowEdit, label: e.target.value })} /></Field>
            <Field label="Tipo"><select value={rowEdit.row_type} onChange={(e) => setRowEdit({ ...rowEdit, row_type: e.target.value })}><option value="header">Encabezado</option><option value="accounts">Cuentas</option><option value="subtotal">Subtotal (fórmula)</option></select></Field>
            <Field label="Orden"><input type="number" value={rowEdit.sort_order} onChange={(e) => setRowEdit({ ...rowEdit, sort_order: e.target.value })} /></Field>
            <Field label="Sangría (0-3)"><input type="number" min={0} max={3} value={rowEdit.indent} onChange={(e) => setRowEdit({ ...rowEdit, indent: e.target.value })} /></Field>
            {rowEdit.row_type === 'accounts' && <Field label="Signo de presentación"><select value={rowEdit.sign} onChange={(e) => setRowEdit({ ...rowEdit, sign: num(e.target.value) })}><option value={1}>+1 (activos, costos, gastos)</option><option value={-1}>−1 (pasivo, patrimonio, ingresos)</option></select></Field>}
            {rowEdit.row_type === 'subtotal' && <Field label="Fórmula" hint="Códigos de fila con + y −. Ej.: A1+A2−A3"><input type="text" value={rowEdit.formula} onChange={(e) => setRowEdit({ ...rowEdit, formula: e.target.value })} /></Field>}
          </div>
          {rowEdit.row_type === 'accounts' && (
            <div style={{ marginTop: 14 }}>
              <b>Cuentas asociadas</b>
              <table className="t" style={{ marginTop: 6 }}><tbody>
                {rowEdit.maps.map((m: Row, i: number) => (
                  <tr key={i}><td>{accLabel(m.account_id)}</td>
                    <td><label className="check"><input type="checkbox" checked={m.include_descendants} onChange={(e) => setRowEdit({ ...rowEdit, maps: rowEdit.maps.map((x: Row, j: number) => (j === i ? { ...x, include_descendants: e.target.checked } : x)) })} /> Incluir subcuentas</label></td>
                    <td><button className="btn sm danger" onClick={() => setRowEdit({ ...rowEdit, maps: rowEdit.maps.filter((_: Row, j: number) => j !== i) })}>Quitar</button></td></tr>
                ))}</tbody></table>
              <div className="row" style={{ marginTop: 8 }}>
                <select id="addacc" defaultValue="" style={{ maxWidth: 420 }} onChange={(e) => { const v = e.target.value; if (v && !rowEdit.maps.some((m: Row) => m.account_id === v)) setRowEdit({ ...rowEdit, maps: [...rowEdit.maps, { account_id: v, include_descendants: true }] }); e.target.value = '' }}>
                  <option value="">+ Agregar cuenta…</option>
                  {accounts.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name}{a.is_postable ? '' : ' (grupo)'}</option>)}
                </select>
              </div>
            </div>
          )}
        </Modal>
      )}
      {newTpl && (
        <Modal title="Nueva plantilla" onClose={() => setNewTpl(null)} footer={<><button className="btn" onClick={() => setNewTpl(null)}>Cancelar</button><button className="btn primary" onClick={createTpl}>Crear</button></>}>
          <div className="stack"><Field label="Nombre"><input type="text" value={newTpl.name} onChange={(e) => setNewTpl({ ...newTpl, name: e.target.value })} /></Field>
            <Field label="Tipo"><select value={newTpl.kind} onChange={(e) => setNewTpl({ ...newTpl, kind: e.target.value })}><option value="balance">Situación financiera</option><option value="income">Resultados</option><option value="other">Otro</option></select></Field></div>
        </Modal>
      )}
      {delRow && <ConfirmModal danger title="Quitar fila" text={`¿Quitar la fila "${delRow.label}"?`} confirmText="Quitar" onCancel={() => setDelRow(null)} onConfirm={removeRow} />}
    </>
  )
}

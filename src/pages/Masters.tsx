import { useState } from 'react'
import { Link } from 'react-router-dom'
import { supabase } from '../lib/supabase'
import { Row, unwrap } from '../lib/api'
import { useAsync } from '../lib/hooks'
import { useAuth } from '../context/Auth'
import { useCatalog } from '../context/Catalog'
import CrudPage from '../components/CrudPage'
import { Empty, Modal, Spinner } from '../components/ui'
import { exportExcel, exportPdf } from '../lib/export'
import { fdate, money, num, qty } from '../lib/format'

const typeLabel: Record<string, string> = { asset: 'Activo', liability: 'Pasivo', equity: 'Patrimonio', revenue: 'Ingreso', cost: 'Costo', expense: 'Gasto' }

export function Accounts() {
  const { org } = useAuth()
  const { accounts, reload } = useCatalog()
  const depth = (a: Row) => { let d = 0, p = a.parent_id; while (p && d < 10) { p = accounts.find((x) => x.id === p)?.parent_id; d++ } return d }
  const exp = (kind: 'x' | 'p') => {
    const cols = [{ key: 'code', label: 'Código' }, { key: 'name', label: 'Nombre' }, { key: 'type', label: 'Tipo' }, { key: 'nature', label: 'Naturaleza' }, { key: 'postable', label: 'Movimiento' }, { key: 'parent', label: 'Cuenta padre' }]
    const rows = accounts.map((a) => ({ code: a.code, name: a.name, type: typeLabel[a.account_type], nature: a.nature === 'debit' ? 'Deudora' : 'Acreedora', postable: a.is_postable ? 'Sí' : 'Agrupación', parent: accounts.find((x) => x.id === a.parent_id)?.code || '' }))
    const meta = { title: 'Plan de cuentas', company: org!.legal_name, taxId: org!.tax_id }
    kind === 'x' ? exportExcel(meta, cols, rows) : exportPdf(meta, cols, rows)
  }
  return (
    <CrudPage table="accounts" title="Plan de cuentas" orderBy="code" writePerm="accounts.manage" onChanged={reload} newLabel="Cuenta"
      sub="Jerarquía de cuentas. Las cuentas con movimientos no pueden cambiar de código, tipo ni naturaleza, ni eliminarse: desactívelas."
      searchKeys={['code', 'name']} modalWide
      headerActions={<><button className="btn" onClick={() => exp('x')}>Excel</button><button className="btn" onClick={() => exp('p')}>PDF</button></>}
      fields={[
        { key: 'code', label: 'Código', required: true },
        { key: 'name', label: 'Nombre', required: true },
        { key: 'parent_id', label: 'Cuenta padre', type: 'select', blankOption: '— Es una cuenta de primer nivel —', options: accounts.filter((a) => !a.is_postable || true).map((a) => ({ value: a.id, label: `${a.code} · ${a.name}` })) },
        { key: 'account_type', label: 'Tipo', type: 'select', required: true, options: Object.entries(typeLabel).map(([value, label]) => ({ value, label })) },
        { key: 'nature', label: 'Naturaleza', type: 'select', required: true, hint: 'Activos, costos y gastos: deudora. Pasivos, patrimonio e ingresos: acreedora.', options: [{ value: 'debit', label: 'Deudora' }, { value: 'credit', label: 'Acreedora' }] },
        { key: 'is_postable', label: 'Cuenta de movimiento (recibe asientos)', type: 'checkbox', default: true, hint: 'Desmarque para cuentas de agrupación.' },
        { key: 'active', label: 'Activa', type: 'checkbox', default: true },
        { key: 'description', label: 'Descripción', type: 'textarea' },
      ]}
      columns={[
        { label: 'Código', render: (r) => <span style={{ paddingLeft: depth(r) * 14, fontWeight: r.is_postable ? 400 : 700 }}>{r.code}</span> },
        { label: 'Nombre', render: (r) => <span style={{ fontWeight: r.is_postable ? 400 : 700 }}>{r.name}</span> },
        { label: 'Tipo', render: (r) => typeLabel[r.account_type] }, { label: 'Naturaleza', render: (r) => (r.nature === 'debit' ? 'Deudora' : 'Acreedora') },
        { label: 'Movimiento', render: (r) => (r.is_postable ? 'Sí' : 'Agrupación') }, { label: 'Estado', key: 'active' },
      ]}
      rowActions={(r) => r.is_postable ? <Link className="btn sm" to={`/contabilidad/libro-mayor?cuenta=${r.id}`}>Mayor</Link> : null}
      validate={(f) => ((['asset', 'expense', 'cost'].includes(f.account_type) && f.nature === 'credit') || (['liability', 'equity', 'revenue'].includes(f.account_type) && f.nature === 'debit') ? null : null)}
    />
  )
}

export function Activities() {
  const { reload } = useCatalog()
  return (
    <CrudPage table="activities" title="Actividades" orderBy="code" writePerm="accounts.manage" onChanged={reload} newLabel="Actividad" canDelete
      sub="Centros de actividad para analizar ingresos, costos y gastos. Asígnelos en las líneas de documentos y asientos. Para repartir un gasto compartido, divídalo en varias líneas, una por actividad: así no se duplican importes."
      fields={[{ key: 'code', label: 'Código', required: true, lockOnEdit: true }, { key: 'name', label: 'Nombre', required: true }, { key: 'description', label: 'Descripción', type: 'textarea' }, { key: 'active', label: 'Activa', type: 'checkbox', default: true }]}
      columns={[{ label: 'Código', key: 'code' }, { label: 'Nombre', key: 'name' }, { label: 'Descripción', key: 'description' }, { label: 'Estado', key: 'active' }]} />
  )
}

function PartyStatement({ kind, party, onClose }: { kind: 'supplier' | 'customer'; party: Row; onClose: () => void }) {
  const sup = kind === 'supplier'
  const { data, loading } = useAsync(async () => {
    const t = sup ? 'purchase_invoices' : 'sales_invoices', k = sup ? 'supplier_id' : 'customer_id'
    return unwrap(await supabase.from(t).select('*').eq(k, party.id).in('status', ['posted', 'voided', 'pending_approval', 'approved', 'draft']).order('issue_date', { ascending: false })) as Row[]
  }, [party.id], [])
  const open = (data || []).filter((i) => i.status === 'posted')
  const saldo = open.reduce((s, i) => s + num(i.total_base) - num(i.paid_base_carried), 0)
  return (
    <Modal wide title={`Estado de cuenta — ${party.name}`} onClose={onClose}>
      {loading ? <Spinner /> : !data?.length ? <Empty>Sin operaciones registradas.</Empty> : (
        <div className="table-wrap"><table className="t"><thead><tr><th>Factura</th><th>Fecha</th><th>Vence</th><th>Moneda</th><th className="r">Total</th><th className="r">{sup ? 'Pagado' : 'Cobrado'}</th><th className="r">Saldo</th><th>Estado</th></tr></thead>
          <tbody>{data.map((i) => (
            <tr key={i.id}><td>{sup ? i.supplier_doc_number : i.invoice_number}</td><td>{fdate(i.issue_date)}</td><td>{fdate(i.due_date)}</td><td>{i.currency_code}</td><td className="num">{money(i.total)}</td><td className="num">{money(i.paid_amount)}</td>
              <td className="num">{i.status === 'posted' ? money(num(i.total) - num(i.paid_amount)) : ''}</td><td><span className={`badge b-${i.status}`}>{({ posted: 'Contabilizada', draft: 'Borrador', voided: 'Anulada', pending_approval: 'En aprobación', approved: 'Aprobada' } as any)[i.status]}</span></td></tr>
          ))}</tbody></table></div>
      )}
      <div style={{ marginTop: 12 }}><b>Saldo pendiente (moneda base): {money(saldo)}</b></div>
    </Modal>
  )
}

function PartyPage({ kind }: { kind: 'supplier' | 'customer' }) {
  const sup = kind === 'supplier'
  const [st, setSt] = useState<Row | null>(null)
  return (
    <>
      <CrudPage table={sup ? 'suppliers' : 'customers'} title={sup ? 'Proveedores' : 'Clientes'} orderBy="name" writePerm="masters.manage" newLabel={sup ? 'Proveedor' : 'Cliente'}
        searchKeys={['name', 'tax_id', 'email']}
        sub={sup ? 'Datos fiscales y comerciales. El sistema impide duplicar el NIT.' : 'Datos fiscales y comerciales de sus clientes.'}
        fields={[
          { key: 'name', label: 'Nombre / razón social', required: true }, { key: 'tax_id', label: 'NIT / identificación' },
          { key: 'email', label: 'Correo', type: 'email' }, { key: 'phone', label: 'Teléfono' }, { key: 'address', label: 'Dirección', full: true },
          { key: 'payment_terms_days', label: 'Plazo de pago (días)', type: 'number', default: 0 }, { key: 'active', label: 'Activo', type: 'checkbox', default: true },
          { key: 'notes', label: 'Notas', type: 'textarea' },
        ]}
        columns={[{ label: 'Nombre', key: 'name' }, { label: 'NIT', key: 'tax_id' }, { label: 'Teléfono', key: 'phone' }, { label: 'Plazo (días)', key: 'payment_terms_days', right: true }, { label: 'Estado', key: 'active' }]}
        rowActions={(r) => <button className="btn sm" onClick={() => setSt(r)}>Estado de cuenta</button>} />
      {st && <PartyStatement kind={kind} party={st} onClose={() => setSt(null)} />}
    </>
  )
}
export const Suppliers = () => <PartyPage kind="supplier" />
export const Customers = () => <PartyPage kind="customer" />

export function Products() {
  const { accounts, reload } = useCatalog()
  const opts = accounts.filter((a) => a.is_postable && a.active).map((a) => ({ value: a.id, label: `${a.code} · ${a.name}` }))
  return (
    <CrudPage table="products" title="Productos y servicios" orderBy="name" writePerm="masters.manage" onChanged={reload} newLabel="Producto" searchKeys={['sku', 'name', 'category']} modalWide
      sub="Productos de inventario (con existencias y costo) y servicios. Las cuentas propias del producto tienen prioridad sobre las reglas contables generales."
      fields={[
        { key: 'sku', label: 'Código (SKU)', required: true, lockOnEdit: true }, { key: 'name', label: 'Nombre', required: true },
        { key: 'product_type', label: 'Tipo', type: 'select', required: true, default: 'inventory', options: [{ value: 'inventory', label: 'Producto de inventario' }, { value: 'service', label: 'Servicio (sin existencias)' }] },
        { key: 'unit', label: 'Unidad de medida', default: 'unidad' }, { key: 'category', label: 'Categoría' }, { key: 'sale_price', label: 'Precio de venta', type: 'number', default: 0 },
        { key: 'inventory_account_id', label: 'Cuenta de inventario', type: 'select', options: opts, blankOption: '— Usar regla general —', show: (f) => f.product_type === 'inventory' },
        { key: 'cogs_account_id', label: 'Cuenta de costo de ventas', type: 'select', options: opts, blankOption: '— Usar regla general —', show: (f) => f.product_type === 'inventory' },
        { key: 'revenue_account_id', label: 'Cuenta de ingresos', type: 'select', options: opts, blankOption: '— Usar regla general —' },
        { key: 'expense_account_id', label: 'Cuenta de gasto (si se compra como gasto)', type: 'select', options: opts, blankOption: '— Usar regla general —' },
        { key: 'active', label: 'Activo', type: 'checkbox', default: true },
      ]}
      columns={[{ label: 'SKU', key: 'sku' }, { label: 'Nombre', key: 'name' }, { label: 'Tipo', render: (r) => (r.product_type === 'inventory' ? 'Inventario' : 'Servicio') }, { label: 'Unidad', key: 'unit' },
        { label: 'Existencias', right: true, render: (r) => (r.product_type === 'inventory' ? qty(r.qty_on_hand) : '—') }, { label: 'Costo prom.', right: true, render: (r) => (r.product_type === 'inventory' ? money(r.avg_cost) : '—') },
        { label: 'Precio venta', right: true, render: (r) => money(r.sale_price) }, { label: 'Estado', key: 'active' }]} />
  )
}

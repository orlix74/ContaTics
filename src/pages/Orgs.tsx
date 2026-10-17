import { useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { rpc, errMsg } from '../lib/api'
import { useAuth } from '../context/Auth'
import { useCatalog } from '../context/Catalog'
import { useToast } from '../context/Toast'
import { Empty, Field, Modal, PageHeader } from '../components/ui'
import { supabase } from '../lib/supabase'
import { ROLE_LABEL } from '../lib/api'

export default function Orgs() {
  const { orgs, org, selectOrg, isPlatformAdmin, reload } = useAuth()
  const { currencies } = useCatalog()
  const nav = useNavigate()
  const toast = useToast()
  const [open, setOpen] = useState(false)
  const [f, setF] = useState({ legal_name: '', trade_name: '', tax_id: '', address: '', currency: 'BOB' })
  const [busy, setBusy] = useState(false)
  const [curList, setCurList] = useState<any[]>([])

  const openForm = async () => {
    setOpen(true)
    if (!curList.length) { const { data } = await supabase.from('currencies').select('*').order('code'); setCurList(data || []) }
  }
  const create = async () => {
    if (!f.legal_name.trim()) return toast.err('Ingrese la razón social.')
    setBusy(true)
    try {
      const id = await rpc<string>('create_organization', { p_legal_name: f.legal_name, p_trade_name: f.trade_name, p_tax_id: f.tax_id, p_address: f.address, p_currency: f.currency })
      await reload(); selectOrg(id); toast.ok('Empresa creada con plan de cuentas, impuestos y periodos iniciales.'); setOpen(false); nav('/dashboard')
    } catch (e) { toast.err(errMsg(e)) } finally { setBusy(false) }
  }
  return (
    <>
      <PageHeader title="Empresas" sub="Seleccione la empresa con la que desea trabajar.">
        {isPlatformAdmin && <button className="btn primary" onClick={openForm}>+ Nueva empresa</button>}
      </PageHeader>
      {orgs.length === 0 ? (
        <div className="card"><Empty>{isPlatformAdmin ? 'Todavía no hay empresas. Cree la primera con el botón "Nueva empresa".' : 'No tiene acceso a ninguna empresa. Pida a un administrador que lo agregue.'}</Empty></div>
      ) : (
        <div className="grid g3">
          {orgs.map((o) => (
            <div key={o.id} className="card card-pad stack" style={o.id === org?.id ? { outline: '2px solid var(--gold)' } : undefined}>
              <div><h3 style={{ marginBottom: 2 }}>{o.trade_name || o.legal_name}</h3><div className="muted small">{o.legal_name}</div></div>
              <div className="small">NIT: <b>{o.tax_id || '—'}</b> · Moneda base: <b>{o.base_currency}</b></div>
              <div><button className="btn primary sm" onClick={() => { selectOrg(o.id); nav('/dashboard') }}>{o.id === org?.id ? 'Empresa activa — abrir' : 'Trabajar con esta empresa'}</button></div>
            </div>
          ))}
        </div>
      )}
      {open && (
        <Modal title="Nueva empresa" onClose={() => setOpen(false)} footer={<><button className="btn" onClick={() => setOpen(false)}>Cancelar</button><button className="btn primary" disabled={busy} onClick={create}>{busy ? 'Creando…' : 'Crear empresa'}</button></>}>
          <div className="stack">
            <Field label="Razón social *"><input type="text" value={f.legal_name} onChange={(e) => setF({ ...f, legal_name: e.target.value })} /></Field>
            <Field label="Nombre comercial"><input type="text" value={f.trade_name} onChange={(e) => setF({ ...f, trade_name: e.target.value })} /></Field>
            <div className="grid g2">
              <Field label="NIT / identificación tributaria"><input type="text" value={f.tax_id} onChange={(e) => setF({ ...f, tax_id: e.target.value })} /></Field>
              <Field label="Moneda base" hint="No podrá cambiarse cuando existan asientos.">
                <select value={f.currency} onChange={(e) => setF({ ...f, currency: e.target.value })}>{curList.map((c) => <option key={c.code} value={c.code}>{c.code} — {c.name}</option>)}</select>
              </Field>
            </div>
            <Field label="Domicilio fiscal"><input type="text" value={f.address} onChange={(e) => setF({ ...f, address: e.target.value })} /></Field>
            <div className="alert info small">Se cargará un plan de cuentas sugerido, impuestos de ejemplo, periodos del año, numeración y flujos de aprobación. Todo es editable.</div>
          </div>
        </Modal>
      )}
    </>
  )
}

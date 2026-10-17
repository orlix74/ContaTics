import { ReactNode, useMemo, useState } from 'react'
import { supabase } from '../lib/supabase'
import { Row, errMsg, unwrap } from '../lib/api'
import { useAsync } from '../lib/hooks'
import { useAuth } from '../context/Auth'
import { useToast } from '../context/Toast'
import { ActiveBadge, ConfirmModal, Empty, Field, Modal, NoAccess, PageHeader, Spinner } from './ui'
import { num } from '../lib/format'

export interface FieldDef {
  key: string
  label: string
  type?: 'text' | 'number' | 'textarea' | 'select' | 'checkbox' | 'date' | 'email'
  options?: { value: string; label: string }[]
  required?: boolean
  hint?: string
  default?: any
  lockOnEdit?: boolean
  full?: boolean
  step?: string
  show?: (f: Row) => boolean
  blankOption?: string
}
export interface ColDef {
  label: string
  key?: string
  render?: (r: Row) => ReactNode
  right?: boolean
}

interface Props {
  table: string
  title: string
  sub?: ReactNode
  fields: FieldDef[]
  columns: ColDef[]
  writePerm: string | string[]
  readPerm?: string
  orderBy?: string
  extraDefaults?: Row
  canDelete?: boolean
  searchKeys?: string[]
  filter?: (q: any) => any
  rowActions?: (r: Row, reload: () => void) => ReactNode
  headerActions?: ReactNode
  onChanged?: () => void
  newLabel?: string
  validate?: (form: Row, isNew: boolean) => string | null
  modalWide?: boolean
  noCreate?: boolean
  refreshKey?: any
  orderDesc?: boolean
}

export default function CrudPage(p: Props) {
  const { org, can } = useAuth()
  const toast = useToast()
  const [editing, setEditing] = useState<Row | null>(null)
  const [isNew, setIsNew] = useState(false)
  const [delRow, setDelRow] = useState<Row | null>(null)
  const [search, setSearch] = useState('')
  const [saving, setSaving] = useState(false)
  const writePerms = Array.isArray(p.writePerm) ? p.writePerm : [p.writePerm]
  const canWrite = writePerms.some((x) => can(x))

  const { data, loading, error, reload } = useAsync<Row[]>(async () => {
    if (!org) return []
    let q = supabase.from(p.table).select('*').eq('organization_id', org.id)
    if (p.filter) q = p.filter(q)
    q = q.order(p.orderBy || 'created_at', { ascending: p.orderBy ? !p.orderDesc : false })
    return unwrap(await q) as Row[]
  }, [org?.id, p.table, p.refreshKey], [])

  const rows = useMemo(() => {
    const s = search.trim().toLowerCase()
    if (!s) return data || []
    const keys = p.searchKeys || p.columns.map((c) => c.key).filter(Boolean) as string[]
    return (data || []).filter((r) => keys.some((k) => String(r[k] ?? '').toLowerCase().includes(s)))
  }, [data, search])

  if (p.readPerm && !can(p.readPerm)) return <NoAccess perm={p.readPerm} />

  const openNew = () => {
    const f: Row = { ...(p.extraDefaults || {}) }
    p.fields.forEach((fd) => { if (f[fd.key] === undefined) f[fd.key] = fd.default !== undefined ? fd.default : fd.type === 'checkbox' ? false : '' })
    setEditing(f); setIsNew(true)
  }
  const openEdit = (r: Row) => {
    const f: Row = { ...r }
    p.fields.forEach((fd) => { if (f[fd.key] === null || f[fd.key] === undefined) f[fd.key] = fd.type === 'checkbox' ? false : '' })
    setEditing(f); setIsNew(false)
  }

  const save = async () => {
    if (!editing || !org) return
    for (const fd of p.fields) {
      if (fd.show && !fd.show(editing)) continue
      if (fd.required && (editing[fd.key] === '' || editing[fd.key] === null || editing[fd.key] === undefined)) {
        toast.err(`Complete el campo: ${fd.label}`); return
      }
    }
    const verr = p.validate?.(editing, isNew)
    if (verr) { toast.err(verr); return }
    const payload: Row = {}
    for (const fd of p.fields) {
      if (fd.show && !fd.show(editing)) { payload[fd.key] = null; continue }
      if (!isNew && fd.lockOnEdit) continue
      let v = editing[fd.key]
      if (fd.type === 'number') v = v === '' ? null : num(v)
      else if (fd.type !== 'checkbox' && v === '') v = null
      payload[fd.key] = v
    }
    setSaving(true)
    try {
      if (isNew) unwrap(await supabase.from(p.table).insert({ ...payload, ...(p.extraDefaults || {}), organization_id: org.id }).select('id'))
      else unwrap(await supabase.from(p.table).update(payload).eq('id', editing.id).select('id'))
      toast.ok('Guardado correctamente')
      setEditing(null); await reload(); p.onChanged?.()
    } catch (e) { toast.err(errMsg(e)) } finally { setSaving(false) }
  }

  const remove = async () => {
    if (!delRow) return
    try {
      unwrap(await supabase.from(p.table).delete().eq('id', delRow.id).select('id'))
      toast.ok('Eliminado'); setDelRow(null); await reload(); p.onChanged?.()
    } catch (e) {
      const m = errMsg(e)
      toast.err(/usado|permiso/.test(m) && 'active' in delRow ? `${m} Puede desactivarlo en su lugar.` : m)
      setDelRow(null)
    }
  }

  const upd = (k: string, v: any) => setEditing((e: Row | null) => ({ ...(e as Row), [k]: v }))

  return (
    <>
      <PageHeader title={p.title} sub={p.sub}>
        {p.headerActions}
        {canWrite && !p.noCreate && <button className="btn primary" onClick={openNew}>+ {p.newLabel || 'Nuevo'}</button>}
      </PageHeader>
      <div className="toolbar">
        <Field><input className="search" type="search" placeholder="Buscar…" value={search} onChange={(e) => setSearch(e.target.value)} /></Field>
      </div>
      <div className="card table-wrap">
        {loading && !data?.length ? <Spinner /> : error ? <div className="card-pad"><div className="alert err">{error}</div></div> : rows.length === 0 ? (
          <Empty>No hay registros{search ? ' que coincidan con la búsqueda' : ' todavía'}.</Empty>
        ) : (
          <table className="t">
            <thead><tr>{p.columns.map((c, i) => <th key={i} className={c.right ? 'r' : ''}>{c.label}</th>)}<th /></tr></thead>
            <tbody>
              {rows.map((r) => (
                <tr key={r.id}>
                  {p.columns.map((c, i) => (
                    <td key={i} className={c.right ? 'num' : ''}>
                      {c.render ? c.render(r) : c.key === 'active' ? <ActiveBadge active={r.active} /> : String(r[c.key!] ?? '')}
                    </td>
                  ))}
                  <td className="nowrap" style={{ textAlign: 'right' }}>
                    {p.rowActions?.(r, reload)}
                    {canWrite && <button className="btn sm" onClick={() => openEdit(r)}>Editar</button>}{' '}
                    {canWrite && p.canDelete && <button className="btn sm danger" onClick={() => setDelRow(r)}>Eliminar</button>}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>

      {editing && (
        <Modal title={isNew ? `Nuevo: ${p.title}` : `Editar: ${p.title}`} wide={p.modalWide} onClose={() => setEditing(null)}
          footer={<><button className="btn" onClick={() => setEditing(null)}>Cancelar</button><button className="btn primary" disabled={saving} onClick={save}>{saving ? 'Guardando…' : 'Guardar'}</button></>}>
          <div className="grid g2">
            {p.fields.filter((fd) => !fd.show || fd.show(editing)).map((fd) => (
              <Field key={fd.key} label={fd.label + (fd.required ? ' *' : '')} hint={fd.hint} className={fd.full || fd.type === 'textarea' ? 'full' : ''}>
                {fd.type === 'textarea' ? (
                  <textarea value={editing[fd.key]} onChange={(e) => upd(fd.key, e.target.value)} />
                ) : fd.type === 'select' ? (
                  <select value={editing[fd.key] ?? ''} disabled={!isNew && fd.lockOnEdit} onChange={(e) => upd(fd.key, e.target.value)}>
                    <option value="">{fd.blankOption ?? '— Seleccione —'}</option>
                    {(fd.options || []).map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
                  </select>
                ) : fd.type === 'checkbox' ? (
                  <label className="check"><input type="checkbox" checked={!!editing[fd.key]} onChange={(e) => upd(fd.key, e.target.checked)} /> Sí</label>
                ) : (
                  <input type={fd.type === 'number' ? 'number' : fd.type || 'text'} step={fd.step || (fd.type === 'number' ? 'any' : undefined)}
                    value={editing[fd.key]} disabled={!isNew && fd.lockOnEdit} onChange={(e) => upd(fd.key, e.target.value)} />
                )}
              </Field>
            ))}
          </div>
          <style>{`.field.full{grid-column:1/-1}`}</style>
        </Modal>
      )}
      {delRow && <ConfirmModal danger title="Eliminar registro" text="¿Seguro que desea eliminar este registro? Esta acción no se puede deshacer." confirmText="Eliminar" onCancel={() => setDelRow(null)} onConfirm={remove} />}
    </>
  )
}

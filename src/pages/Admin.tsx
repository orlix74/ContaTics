import { useState } from 'react'
import { supabase } from '../lib/supabase'
import { PERMISSION_LABEL, ROLE_LABEL, Row, errMsg, rpc, unwrap } from '../lib/api'
import { useAsync } from '../lib/hooks'
import { useAuth } from '../context/Auth'
import { useToast } from '../context/Toast'
import { ActiveBadge, Alert, Empty, Field, Modal, NoAccess, PageHeader, Spinner } from '../components/ui'
import { fdatetime } from '../lib/format'

const ROLES = Object.keys(ROLE_LABEL)

export function Users() {
  const { org, can, session, reloadPerms } = useAuth()
  const toast = useToast()
  const [modal, setModal] = useState<'new' | 'existing' | null>(null)
  const [pw, setPw] = useState<Row | null>(null)
  const [f, setF] = useState<Row>({ email: '', password: '', full_name: '', role: 'assistant' })
  const [newPw, setNewPw] = useState('')
  const [busy, setBusy] = useState(false)
  const { data, loading, reload } = useAsync(async () => {
    const m = unwrap(await supabase.from('organization_members').select('*').eq('organization_id', org!.id)) as Row[]
    const p = m.length ? (unwrap(await supabase.from('profiles').select('id,email,full_name,active').in('id', m.map((x) => x.user_id))) as Row[]) : []
    return m.map((x) => ({ ...x, p: p.find((y) => y.id === x.user_id) })).sort((a, b) => (a.p?.email || '').localeCompare(b.p?.email || ''))
  }, [org?.id], [])
  if (!can('users.manage')) return <NoAccess perm="users.manage" />
  const run = async (fn: () => Promise<any>, ok: string) => { setBusy(true); try { await fn(); toast.ok(ok); reload(); return true } catch (e) { toast.err(errMsg(e)); return false } finally { setBusy(false) } }
  const create = async () => {
    if (modal === 'new') {
      if (!f.email || f.password.length < 8 || !f.full_name) return toast.err('Complete nombre, correo y una contraseña de al menos 8 caracteres.')
      if (await run(() => rpc('admin_create_user', { p_org: org!.id, p_email: f.email, p_password: f.password, p_full_name: f.full_name, p_role: f.role }), 'Usuario creado')) { setModal(null); setF({ email: '', password: '', full_name: '', role: 'assistant' }) }
    } else if (await run(() => rpc('add_member_by_email', { p_org: org!.id, p_email: f.email, p_role: f.role }), 'Usuario agregado a la empresa')) setModal(null)
  }
  return (
    <>
      <PageHeader title="Usuarios de la empresa" sub="Cree usuarios aquí mismo: no necesita volver a Supabase. Entregue la contraseña inicial por un medio seguro.">
        <button className="btn" onClick={() => setModal('existing')}>Agregar usuario existente</button>
        <button className="btn primary" onClick={() => setModal('new')}>+ Nuevo usuario</button>
      </PageHeader>
      <div className="card table-wrap">
        {loading ? <Spinner /> : !data?.length ? <Empty>Sin usuarios.</Empty> : (
          <table className="t"><thead><tr><th>Nombre</th><th>Correo</th><th>Rol</th><th>Estado</th><th /></tr></thead>
            <tbody>{data.map((m) => { const me = m.user_id === session?.user.id; return (
              <tr key={m.user_id}><td>{m.p?.full_name}{me && <span className="badge"> usted</span>}</td><td>{m.p?.email}</td>
                <td><select value={m.role} disabled={me || busy} onChange={(e) => run(() => rpc('set_member_role', { p_org: org!.id, p_user: m.user_id, p_role: e.target.value }), 'Rol actualizado')}>{ROLES.map((r) => <option key={r} value={r}>{ROLE_LABEL[r]}</option>)}</select></td>
                <td><ActiveBadge active={m.active} /></td>
                <td className="nowrap"><button className="btn sm" onClick={() => { setPw(m); setNewPw('') }}>Nueva contraseña</button>{' '}
                  {!me && <button className="btn sm" disabled={busy} onClick={() => run(() => rpc('set_member_active', { p_org: org!.id, p_user: m.user_id, p_active: !m.active }), m.active ? 'Usuario desactivado' : 'Usuario activado')}>{m.active ? 'Desactivar' : 'Activar'}</button>}</td></tr>) })}</tbody></table>)}
      </div>
      {modal && (
        <Modal title={modal === 'new' ? 'Nuevo usuario' : 'Agregar usuario existente'} onClose={() => setModal(null)} footer={<><button className="btn" onClick={() => setModal(null)}>Cancelar</button><button className="btn primary" disabled={busy} onClick={create}>{modal === 'new' ? 'Crear usuario' : 'Agregar'}</button></>}>
          <div className="stack">
            {modal === 'existing' && <Alert kind="info">Para un usuario que ya existe en el sistema (por ejemplo, de otra empresa). Escriba su correo.</Alert>}
            {modal === 'new' && <Field label="Nombre completo *"><input type="text" value={f.full_name} onChange={(e) => setF({ ...f, full_name: e.target.value })} /></Field>}
            <Field label="Correo *"><input type="email" value={f.email} onChange={(e) => setF({ ...f, email: e.target.value })} /></Field>
            {modal === 'new' && <Field label="Contraseña inicial * (mínimo 8 caracteres)"><input type="text" value={f.password} onChange={(e) => setF({ ...f, password: e.target.value })} /></Field>}
            <Field label="Rol *"><select value={f.role} onChange={(e) => setF({ ...f, role: e.target.value })}>{ROLES.map((r) => <option key={r} value={r}>{ROLE_LABEL[r]}</option>)}</select></Field>
          </div>
        </Modal>)}
      {pw && (
        <Modal title={`Nueva contraseña para ${pw.p?.email}`} onClose={() => setPw(null)} footer={<><button className="btn" onClick={() => setPw(null)}>Cancelar</button><button className="btn primary" disabled={busy || newPw.length < 8} onClick={async () => { if (await run(() => rpc('admin_set_password', { p_org: org!.id, p_user: pw.user_id, p_password: newPw }), 'Contraseña cambiada')) { setPw(null); reloadPerms() } }}>Cambiar</button></>}>
          <Field label="Nueva contraseña (mínimo 8 caracteres)"><input type="text" value={newPw} onChange={(e) => setNewPw(e.target.value)} /></Field>
        </Modal>)}
    </>
  )
}

export function Roles() {
  const { org, can, role, reloadPerms } = useAuth()
  const toast = useToast()
  const { data, loading, reload } = useAsync(async () => unwrap(await supabase.from('role_permissions').select('role,permission').eq('organization_id', org!.id)) as Row[], [org?.id], [])
  if (!can('users.manage')) return <NoAccess perm="users.manage" />
  const has = (r: string, p: string) => !!data?.some((x) => x.role === r && x.permission === p)
  const toggle = async (r: string, p: string) => {
    try { await rpc('set_role_permission', { p_org: org!.id, p_role: r, p_perm: p, p_granted: !has(r, p) }); await reload(); if (r === role) reloadPerms() } catch (e) { toast.err(errMsg(e)) }
  }
  return (
    <>
      <PageHeader title="Roles y permisos" sub="Marque qué puede hacer cada rol en esta empresa. Los cambios se aplican de inmediato. El Administrador siempre conserva la gestión de usuarios." />
      <div className="card table-wrap">
        {loading ? <Spinner /> : (
          <table className="t matrix"><thead><tr><th>Permiso</th>{ROLES.map((r) => <th key={r} className="c">{ROLE_LABEL[r]}</th>)}</tr></thead>
            <tbody>{Object.keys(PERMISSION_LABEL).map((p) => (
              <tr key={p}><td>{PERMISSION_LABEL[p]}<div className="muted small">{p}</div></td>
                {ROLES.map((r) => <td key={r} className="c"><input type="checkbox" checked={has(r, p)} disabled={r === 'admin' && p === 'users.manage'} onChange={() => toggle(r, p)} /></td>)}</tr>))}</tbody></table>)}
      </div>
    </>
  )
}

export function AuditLog() {
  const { org, can } = useAuth()
  const [q, setQ] = useState('')
  const [entity, setEntity] = useState('')
  const [view, setView] = useState<Row | null>(null)
  const { data, loading } = useAsync(async () => {
    let query = supabase.from('audit_logs').select('*').eq('organization_id', org!.id).order('created_at', { ascending: false }).limit(500)
    if (entity) query = query.eq('entity_type', entity)
    return unwrap(await query) as Row[]
  }, [org?.id, entity], [])
  if (!can('audit.view')) return <NoAccess perm="audit.view" />
  const types = Array.from(new Set((data || []).map((x) => x.entity_type))).sort()
  const rows = (data || []).filter((r) => !q || `${r.user_email} ${r.action} ${r.entity_type} ${r.comment}`.toLowerCase().includes(q.toLowerCase()))
  return (
    <>
      <PageHeader title="Bitácora de auditoría" sub="Registro inmutable de cambios: nadie puede editarlo ni borrarlo. Se muestran los últimos 500 eventos." />
      <div className="card card-pad row"><input type="search" placeholder="Buscar usuario, acción…" value={q} onChange={(e) => setQ(e.target.value)} />
        <select value={entity} onChange={(e) => setEntity(e.target.value)}><option value="">Todas las tablas</option>{types.map((t) => <option key={t}>{t}</option>)}</select></div>
      <div className="card table-wrap">
        {loading ? <Spinner /> : !rows.length ? <Empty>Sin eventos.</Empty> : (
          <table className="t"><thead><tr><th>Fecha</th><th>Usuario</th><th>Acción</th><th>Entidad</th><th>Detalle</th><th /></tr></thead>
            <tbody>{rows.map((r) => <tr key={r.id}><td className="nowrap">{fdatetime(r.created_at)}</td><td>{r.user_email}</td><td>{r.action}</td><td>{r.entity_type}</td><td>{r.comment}</td><td>{(r.old_data || r.new_data) && <button className="btn sm ghost" onClick={() => setView(r)}>Ver cambios</button>}</td></tr>)}</tbody></table>)}
      </div>
      {view && <Modal wide title="Datos antes / después" onClose={() => setView(null)}><div className="grid g2"><div><h4>Antes</h4><pre className="code">{JSON.stringify(view.old_data, null, 2) || '—'}</pre></div><div><h4>Después</h4><pre className="code">{JSON.stringify(view.new_data, null, 2) || '—'}</pre></div></div></Modal>}
    </>
  )
}

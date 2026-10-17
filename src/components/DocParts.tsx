import { ReactNode, useRef, useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { supabase } from '../lib/supabase'
import { DOC_ROUTE, DOC_TYPE_LABEL, Row, errMsg, rpc, unwrap } from '../lib/api'
import { useAsync } from '../lib/hooks'
import { useAuth } from '../context/Auth'
import { useToast } from '../context/Toast'
import { Alert, ConfirmModal, Empty, Modal, PromptModal, Spinner, StatusBadge, PageHeader, Field } from './ui'
import { fdate, fdatetime } from '../lib/format'

export const isEditable = (status?: string) => !status || status === 'draft' || status === 'rejected'

const ACTION_LABEL: Record<string, string> = {
  submitted: 'Enviado a aprobación', approved_step: 'Aprobación registrada', approved: 'Aprobación completa', rejected: 'Rechazado',
  returned_to_draft: 'Devuelto a borrador', posted: 'Contabilizado', reversed: 'Revertido / anulado',
}

/* ---------- Barra de acciones del flujo ---------- */
export function DocWorkflow({ type, doc, onChange }: { type: string; doc: Row; onChange: () => void }) {
  const { can, session } = useAuth()
  const toast = useToast()
  const [dlg, setDlg] = useState<null | 'approve' | 'reject' | 'return' | 'reverse' | 'post' | 'submit'>(null)
  const status: string = doc.status
  const mine = doc.created_by === session?.user.id

  const call = async (fn: string, args: Row, okMsg: string) => {
    try { await rpc(fn, { p_type: type, p_id: doc.id, ...args }); toast.ok(okMsg); setDlg(null); onChange() }
    catch (e) { toast.err(errMsg(e)); setDlg(null); onChange() }
  }
  const revLabel = type === 'journal_entry' ? 'Revertir asiento' : type === 'bank_reconciliation' ? 'Anular conciliación' : 'Anular documento'
  return (
    <>
      {doc.rejection_reason && status === 'rejected' && <Alert kind="err"><b>Rechazado:</b> {doc.rejection_reason}</Alert>}
      <div className="row no-print">
        {isEditable(status) && can('documents.submit') && <button className="btn gold" onClick={() => setDlg('submit')}>Enviar a aprobación</button>}
        {status === 'pending_approval' && can('documents.approve') && <>
          <button className="btn primary" onClick={() => setDlg('approve')}>Aprobar</button>
          <button className="btn danger" onClick={() => setDlg('reject')}>Rechazar</button></>}
        {(status === 'pending_approval' || status === 'approved') && (can('documents.approve') || mine) && <button className="btn" onClick={() => setDlg('return')}>Devolver a borrador</button>}
        {status === 'approved' && can('documents.post') && <button className="btn gold" onClick={() => setDlg('post')}>Contabilizar</button>}
        {status === 'posted' && can('documents.reverse') && <button className="btn danger" onClick={() => setDlg('reverse')}>{revLabel}</button>}
      </div>
      {dlg === 'submit' && <ConfirmModal title="Enviar a aprobación" text="El documento quedará bloqueado para edición hasta que sea aprobado o rechazado. ¿Continuar?" confirmText="Enviar" onCancel={() => setDlg(null)} onConfirm={() => call('submit_document', {}, 'Enviado a aprobación')} />}
      {dlg === 'approve' && <PromptModal title="Aprobar documento" label="Comentario (opcional)" confirmText="Aprobar" onCancel={() => setDlg(null)} onConfirm={(t) => call('approve_document', { p_comment: t || null }, 'Aprobación registrada')} />}
      {dlg === 'reject' && <PromptModal title="Rechazar documento" label="Motivo del rechazo (obligatorio)" required confirmText="Rechazar" onCancel={() => setDlg(null)} onConfirm={(t) => call('reject_document', { p_comment: t }, 'Documento rechazado')} />}
      {dlg === 'return' && <PromptModal title="Devolver a borrador" label="Motivo (opcional). Se invalidarán las aprobaciones registradas." confirmText="Devolver" onCancel={() => setDlg(null)} onConfirm={(t) => call('return_to_draft', { p_reason: t || null }, 'Devuelto a borrador')} />}
      {dlg === 'post' && <ConfirmModal title="Contabilizar" text="Se generará el asiento contable y los movimientos relacionados. Esta operación es definitiva: para corregirla se usa una reversión autorizada." confirmText="Contabilizar" onCancel={() => setDlg(null)} onConfirm={() => call('post_document', {}, 'Contabilizado correctamente')} />}
      {dlg === 'reverse' && <PromptModal title={revLabel} label="Motivo (obligatorio, mínimo 5 caracteres)" required confirmText="Confirmar" onCancel={() => setDlg(null)} onConfirm={(t) => (t.length < 5 ? (toast.err('Escriba un motivo más descriptivo.'), undefined) : call('reverse_document', { p_reason: t }, 'Operación registrada'))} />}
    </>
  )
}

/* ---------- Historial de aprobación ---------- */
export function DocHistory({ type, id, reloadKey }: { type: string; id: string; reloadKey?: any }) {
  const { data, loading } = useAsync(async () => {
    const h = unwrap(await supabase.from('approval_history').select('*').eq('doc_type', type).eq('doc_id', id).order('created_at', { ascending: false })) as Row[]
    const ids = Array.from(new Set(h.map((x) => x.user_id).filter(Boolean)))
    const p = ids.length ? (unwrap(await supabase.from('profiles').select('id,full_name,email').in('id', ids)) as Row[]) : []
    return h.map((x) => ({ ...x, who: p.find((y) => y.id === x.user_id) }))
  }, [type, id, reloadKey], [])
  if (loading) return <Spinner />
  if (!data?.length) return <Empty>Sin movimientos de aprobación todavía.</Empty>
  return (
    <ul className="timeline">
      {data.map((h) => (
        <li key={h.id}><b>{ACTION_LABEL[h.action] || h.action}</b> — {h.who?.full_name || h.who?.email || 'Sistema'}
          <div className="muted small">{fdatetime(h.created_at)}{h.comment ? ` · “${h.comment}”` : ''}</div></li>
      ))}
    </ul>
  )
}

/* ---------- Adjuntos ---------- */
export function Attachments({ entityType, entityId }: { entityType: string; entityId: string }) {
  const { org, can } = useAuth()
  const toast = useToast()
  const inp = useRef<HTMLInputElement>(null)
  const [busy, setBusy] = useState(false)
  const { data, reload, loading } = useAsync(async () => unwrap(await supabase.from('attachments').select('*').eq('entity_type', entityType).eq('entity_id', entityId).order('created_at', { ascending: false })) as Row[], [entityType, entityId], [])
  const canManage = can('attachments.manage')

  const upload = async (files: FileList | null) => {
    if (!files || !org) return
    setBusy(true)
    try {
      for (const f of Array.from(files)) {
        if (f.size > 15 * 1024 * 1024) { toast.err(`${f.name}: supera 15 MB`); continue }
        const safe = f.name.replace(/[^\w.\-]+/g, '_')
        const path = `${org.id}/${entityType}/${entityId}/${crypto.randomUUID()}-${safe}`
        const up = await supabase.storage.from('attachments').upload(path, f, { contentType: f.type || undefined })
        if (up.error) throw up.error
        const { error } = await supabase.from('attachments').insert({ organization_id: org.id, entity_type: entityType, entity_id: entityId, storage_path: path, file_name: f.name, mime_type: f.type, size_bytes: f.size })
        if (error) { await supabase.storage.from('attachments').remove([path]); throw error }
      }
      toast.ok('Archivo adjuntado'); reload()
    } catch (e) { toast.err(errMsg(e) + ' — ¿Existe el almacenamiento "attachments"? Revise la guía de instalación.') } finally { setBusy(false); if (inp.current) inp.current.value = '' }
  }
  const open = async (a: Row) => {
    const { data: d, error } = await supabase.storage.from('attachments').createSignedUrl(a.storage_path, 120)
    if (error) return toast.err(errMsg(error))
    window.open(d.signedUrl, '_blank', 'noopener')
  }
  const del = async (a: Row) => {
    try {
      unwrap(await supabase.from('attachments').delete().eq('id', a.id).select('id'))
      await supabase.storage.from('attachments').remove([a.storage_path]); reload()
    } catch (e) { toast.err(errMsg(e)) }
  }
  return (
    <div>
      {loading ? <Spinner /> : !data?.length ? <Empty>Sin archivos adjuntos.</Empty> : (
        <table className="t"><tbody>{data.map((a) => (
          <tr key={a.id}><td><button className="btn ghost sm" onClick={() => open(a)}>📎 {a.file_name}</button></td><td className="muted small">{fdate(a.created_at)} · {Math.round((a.size_bytes || 0) / 1024)} KB</td>
            <td style={{ textAlign: 'right' }}>{canManage && <button className="btn sm danger" onClick={() => del(a)}>Quitar</button>}</td></tr>
        ))}</tbody></table>
      )}
      {canManage && (
        <div style={{ marginTop: 10 }}>
          <input ref={inp} type="file" multiple hidden onChange={(e) => upload(e.target.files)} />
          <button className="btn" disabled={busy} onClick={() => inp.current?.click()}>{busy ? 'Subiendo…' : '+ Adjuntar archivos'}</button>
          <span className="muted small"> Facturas, recibos, comprobantes… (máx. 15 MB c/u)</span>
        </div>
      )}
    </div>
  )
}

/* ---------- Marco de un documento ---------- */
export function DocFrame({ type, doc, title, sub, onChange, children, extra, listPath }: {
  type: string; doc?: Row | null; title: string; sub?: ReactNode; onChange: () => void; children: ReactNode; extra?: ReactNode; listPath?: string
}) {
  const nav = useNavigate()
  const [hk, setHk] = useState(0)
  return (
    <>
      <PageHeader title={title} sub={sub}>
        <button className="btn" onClick={() => nav(listPath || DOC_ROUTE[type])}>← Volver al listado</button>
        {doc && <StatusBadge status={doc.status} />}
      </PageHeader>
      <div className="stack">
        {doc && <DocWorkflow type={type} doc={doc} onChange={() => { setHk((x) => x + 1); onChange() }} />}
        {doc && doc.status === 'posted' && doc.journal_entry_id && <Alert kind="ok">Contabilizado. Asiento generado: <Link to={`/contabilidad/asientos/${doc.journal_entry_id}`}>ver asiento contable</Link></Alert>}
        {doc && doc.status === 'approved' && <Alert kind="info">Aprobado. Falta la contabilización definitiva por un usuario autorizado.</Alert>}
        {doc && doc.status === 'pending_approval' && <Alert kind="warn">Esperando aprobación. El documento no puede editarse mientras tanto.</Alert>}
        {children}
        {extra}
        {doc && (
          <div className="grid g2">
            <div className="card card-pad"><h3>Archivos adjuntos</h3><Attachments entityType={type} entityId={doc.id} /></div>
            <div className="card card-pad"><h3>Historial de aprobación</h3><DocHistory type={type} id={doc.id} reloadKey={hk} /></div>
          </div>
        )}
      </div>
    </>
  )
}

/* ---------- Listado de documentos ---------- */
export interface DocCol { label: string; render: (r: Row) => ReactNode; right?: boolean }
export function DocList({ table, type, title, sub, select, columns, createPerm, newPath, dateField, searchText, newLabel }: {
  table: string; type: string; title: string; sub?: ReactNode; select?: string; columns: DocCol[]; createPerm: string; newPath?: string; dateField?: string; searchText: (r: Row) => string; newLabel?: string
}) {
  const { org, can } = useAuth()
  const nav = useNavigate()
  const [status, setStatus] = useState('')
  const [q, setQ] = useState('')
  const [from, setFrom] = useState('')
  const [to, setTo] = useState('')
  const base = DOC_ROUTE[type]
  const { data, loading, error } = useAsync(async () => {
    let query = supabase.from(table).select(select || '*').eq('organization_id', org!.id)
    if (status) query = query.eq('status', status)
    if (dateField && from) query = query.gte(dateField, from)
    if (dateField && to) query = query.lte(dateField, to)
    return unwrap(await query.order('created_at', { ascending: false }).limit(500)) as unknown as Row[]
  }, [org?.id, table, status, from, to], [])
  const rows = (data || []).filter((r) => !q.trim() || searchText(r).toLowerCase().includes(q.trim().toLowerCase()))
  return (
    <>
      <PageHeader title={title} sub={sub}>
        {can(createPerm) && <button className="btn primary" onClick={() => nav(newPath || `${base}/nuevo`)}>+ {newLabel || 'Nuevo'}</button>}
      </PageHeader>
      <div className="toolbar">
        <Field label="Buscar"><input className="search" type="search" placeholder="Número, nombre, referencia…" value={q} onChange={(e) => setQ(e.target.value)} /></Field>
        <Field label="Estado"><select value={status} onChange={(e) => setStatus(e.target.value)}>
          <option value="">Todos</option><option value="draft">Borrador</option><option value="pending_approval">Pendiente de aprobación</option><option value="rejected">Rechazado</option><option value="approved">Aprobado (por contabilizar)</option><option value="posted">Contabilizado</option><option value="voided">Anulado</option></select></Field>
        {dateField && <><Field label="Desde"><input type="date" value={from} onChange={(e) => setFrom(e.target.value)} /></Field><Field label="Hasta"><input type="date" value={to} onChange={(e) => setTo(e.target.value)} /></Field></>}
      </div>
      <div className="card table-wrap">
        {loading && !data?.length ? <Spinner /> : error ? <div className="card-pad"><Alert kind="err">{error}</Alert></div> : rows.length === 0 ? <Empty>No hay {DOC_TYPE_LABEL[type].toLowerCase()}s para mostrar.</Empty> : (
          <table className="t"><thead><tr>{columns.map((c, i) => <th key={i} className={c.right ? 'r' : ''}>{c.label}</th>)}<th>Estado</th></tr></thead>
            <tbody>{rows.map((r) => (
              <tr key={r.id} className="click" onClick={() => nav(`${base}/${r.id}`)}>
                {columns.map((c, i) => <td key={i} className={c.right ? 'num' : ''}>{c.render(r)}</td>)}
                <td><StatusBadge status={r.status} /></td></tr>
            ))}</tbody></table>
        )}
      </div>
      {data && data.length >= 500 && <div className="muted small" style={{ marginTop: 8 }}>Se muestran los 500 documentos más recientes. Use los filtros para acotar.</div>}
    </>
  )
}

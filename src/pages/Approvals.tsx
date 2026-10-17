import { useState } from 'react'
import { Link } from 'react-router-dom'
import { supabase } from '../lib/supabase'
import { DOC_ROUTE, DOC_TYPE_LABEL, Row, errMsg, rpc, unwrap } from '../lib/api'
import { useAsync } from '../lib/hooks'
import { useAuth } from '../context/Auth'
import { useToast } from '../context/Toast'
import { Empty, PageHeader, PromptModal, Spinner } from '../components/ui'
import { fdate, fdatetime } from '../lib/format'

async function withNames(rows: Row[], key: string) {
  const ids = Array.from(new Set(rows.map((r) => r[key]).filter(Boolean)))
  const p = ids.length ? (unwrap(await supabase.from('profiles').select('id,full_name,email').in('id', ids)) as Row[]) : []
  return rows.map((r) => ({ ...r, who: p.find((x) => x.id === r[key]) }))
}
const nm = (p?: Row) => p?.full_name || p?.email || '—'

export function ApprovalInbox() {
  const { org, can, session } = useAuth()
  const toast = useToast()
  const [rej, setRej] = useState<Row | null>(null)
  const { data, loading, reload } = useAsync(async () => {
    const r = unwrap(await supabase.from('approval_requests').select('*').eq('organization_id', org!.id).eq('status', 'pending').order('submitted_at')) as Row[]
    return withNames(r, 'submitted_by')
  }, [org?.id], [])
  const canApprove = can('documents.approve')
  const approve = async (r: Row) => { try { await rpc('approve_document', { p_type: r.doc_type, p_id: r.doc_id }); toast.ok('Documento aprobado'); reload() } catch (e) { toast.err(errMsg(e)) } }
  return (
    <>
      <PageHeader title="Bandeja de aprobaciones" sub="Documentos enviados que esperan una decisión. Un documento aprobado queda listo para contabilizar." />
      <div className="card table-wrap">
        {loading ? <Spinner /> : !data?.length ? <Empty>No hay documentos pendientes de aprobación.</Empty> : (
          <table className="t"><thead><tr><th>Documento</th><th>Tipo</th><th>Enviado por</th><th>Fecha</th><th /></tr></thead>
            <tbody>{data.map((r) => (
              <tr key={r.id}><td><Link to={`${DOC_ROUTE[r.doc_type]}/${r.doc_id}`}><b>{r.doc_label || 'Ver documento'}</b></Link></td><td>{DOC_TYPE_LABEL[r.doc_type]}</td><td>{nm(r.who)}</td><td>{fdatetime(r.submitted_at)}</td>
                <td className="nowrap">
                  <Link className="btn sm" to={`${DOC_ROUTE[r.doc_type]}/${r.doc_id}`}>Revisar</Link>{' '}
                  {canApprove && (r.submitted_by !== session?.user.id || r.allow_self_approval) && <><button className="btn sm primary" onClick={() => approve(r)}>Aprobar</button>{' '}<button className="btn sm danger" onClick={() => setRej(r)}>Rechazar</button></>}
                  {canApprove && r.submitted_by === session?.user.id && !r.allow_self_approval && <span className="muted small">No puede aprobar lo que usted envió</span>}
                </td></tr>))}</tbody></table>)}
      </div>
      {rej && <PromptModal title="Rechazar documento" label="Motivo del rechazo (obligatorio)" required confirmText="Rechazar" onCancel={() => setRej(null)}
        onConfirm={async (t) => { try { await rpc('reject_document', { p_type: rej.doc_type, p_id: rej.doc_id, p_comment: t }); toast.ok('Documento rechazado'); setRej(null); reload() } catch (e) { toast.err(errMsg(e)) } }} />}
    </>
  )
}

const ACT: Record<string, string> = { submit: 'Enviado a aprobación', approve: 'Aprobado', reject: 'Rechazado', return_draft: 'Devuelto a borrador', post: 'Contabilizado', reverse: 'Anulado / revertido' }
export function ApprovalHistory() {
  const { org } = useAuth()
  const { data, loading } = useAsync(async () => {
    const r = unwrap(await supabase.from('approval_history').select('*').eq('organization_id', org!.id).order('created_at', { ascending: false }).limit(300)) as Row[]
    return withNames(r, 'user_id')
  }, [org?.id], [])
  return (
    <>
      <PageHeader title="Historial de aprobaciones" sub="Últimos 300 movimientos del flujo de aprobación." />
      <div className="card table-wrap">
        {loading ? <Spinner /> : !data?.length ? <Empty>Sin movimientos todavía.</Empty> : (
          <table className="t"><thead><tr><th>Fecha</th><th>Acción</th><th>Documento</th><th>Usuario</th><th>Comentario</th></tr></thead>
            <tbody>{data.map((h) => <tr key={h.id}><td className="nowrap">{fdatetime(h.created_at)}</td><td>{ACT[h.action] || h.action}</td><td><Link to={`${DOC_ROUTE[h.doc_type]}/${h.doc_id}`}>{DOC_TYPE_LABEL[h.doc_type]}</Link></td><td>{nm(h.who)}</td><td>{h.comment}</td></tr>)}</tbody></table>)}
      </div>
    </>
  )
}

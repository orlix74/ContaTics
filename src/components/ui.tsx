import { ReactNode, useEffect, useState } from 'react'
import { STATUS_LABEL } from '../lib/api'

export function PageHeader({ title, sub, children }: { title: string; sub?: ReactNode; children?: ReactNode }) {
  return (
    <div className="page-head">
      <div>
        <h1>{title}</h1>
        {sub && <div className="sub">{sub}</div>}
      </div>
      <div className="actions">{children}</div>
    </div>
  )
}

export function StatusBadge({ status }: { status: string }) {
  return <span className={`badge b-${status}`}>{STATUS_LABEL[status] || status}</span>
}

export function ActiveBadge({ active }: { active: boolean }) {
  return <span className={`badge ${active ? 'b-ok' : 'b-off'}`}>{active ? 'Activo' : 'Inactivo'}</span>
}

export function Modal({ title, onClose, children, footer, wide }: { title: string; onClose: () => void; children: ReactNode; footer?: ReactNode; wide?: boolean }) {
  useEffect(() => {
    const h = (e: KeyboardEvent) => e.key === 'Escape' && onClose()
    window.addEventListener('keydown', h)
    return () => window.removeEventListener('keydown', h)
  }, [onClose])
  return (
    <div className="modal-bg" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className={`modal ${wide ? 'wide' : ''}`} role="dialog" aria-modal="true" aria-label={title}>
        <div className="modal-head">
          <h3>{title}</h3>
          <button className="btn ghost sm" onClick={onClose} aria-label="Cerrar">✕</button>
        </div>
        <div className="modal-body">{children}</div>
        {footer && <div className="modal-foot">{footer}</div>}
      </div>
    </div>
  )
}

export function Field({ label, hint, children, className }: { label?: string; hint?: string; children: ReactNode; className?: string }) {
  return (
    <div className={`field ${className || ''}`}>
      {label && <label>{label}</label>}
      {children}
      {hint && <span className="hint">{hint}</span>}
    </div>
  )
}

export function Spinner({ text }: { text?: string }) {
  return (
    <div className="empty">
      <span className="spinner" />
      {text && <div style={{ marginTop: 8 }}>{text}</div>}
    </div>
  )
}

export function Empty({ children }: { children: ReactNode }) {
  return <div className="empty">{children}</div>
}

export function Alert({ kind = 'info', children }: { kind?: 'err' | 'warn' | 'info' | 'ok'; children: ReactNode }) {
  return <div className={`alert ${kind}`}>{children}</div>
}

export function Tabs({ tabs, value, onChange }: { tabs: [string, string][]; value: string; onChange: (v: string) => void }) {
  return (
    <div className="tabs" role="tablist">
      {tabs.map(([k, l]) => (
        <button key={k} role="tab" aria-selected={value === k} className={value === k ? 'on' : ''} onClick={() => onChange(k)}>{l}</button>
      ))}
    </div>
  )
}

/** Cuadro para pedir un texto (motivo/comentario) antes de una acción */
export function PromptModal({ title, label, required, confirmText, onCancel, onConfirm }: {
  title: string; label: string; required?: boolean; confirmText: string; onCancel: () => void; onConfirm: (text: string) => Promise<void> | void
}) {
  const [text, setText] = useState('')
  const [busy, setBusy] = useState(false)
  return (
    <Modal title={title} onClose={onCancel} footer={
      <>
        <button className="btn" onClick={onCancel}>Cancelar</button>
        <button className="btn primary" disabled={busy || (required && text.trim().length < 3)} onClick={async () => { setBusy(true); try { await onConfirm(text.trim()) } finally { setBusy(false) } }}>{confirmText}</button>
      </>
    }>
      <Field label={label}><textarea autoFocus value={text} onChange={(e) => setText(e.target.value)} /></Field>
    </Modal>
  )
}

export function ConfirmModal({ title, text, confirmText, danger, onCancel, onConfirm }: {
  title: string; text: ReactNode; confirmText: string; danger?: boolean; onCancel: () => void; onConfirm: () => Promise<void> | void
}) {
  const [busy, setBusy] = useState(false)
  return (
    <Modal title={title} onClose={onCancel} footer={
      <>
        <button className="btn" onClick={onCancel}>Cancelar</button>
        <button className={`btn ${danger ? 'danger' : 'primary'}`} disabled={busy} onClick={async () => { setBusy(true); try { await onConfirm() } finally { setBusy(false) } }}>{confirmText}</button>
      </>
    }>
      <div>{text}</div>
    </Modal>
  )
}

export function Stat({ k, v, tone }: { k: string; v: ReactNode; tone?: 'ok' | 'err' | 'warn' }) {
  return (
    <div className="card stat">
      <div className="k">{k}</div>
      <div className="v" style={tone ? { color: `var(--${tone})` } : undefined}>{v}</div>
    </div>
  )
}

export function NoAccess({ perm }: { perm?: string }) {
  return <div className="card card-pad"><Alert kind="warn">Su rol no tiene permiso para ver esta sección{perm ? ` (${perm})` : ''}. Pida a un administrador que revise sus permisos.</Alert></div>
}

import { FormEvent, useEffect, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { supabase, isConfigured } from '../lib/supabase'
import { errMsg } from '../lib/api'
import { useAuth } from '../context/Auth'
import { Field } from '../components/ui'

export function Login() {
  const { session, loading } = useAuth()
  const nav = useNavigate()
  const [email, setEmail] = useState('')
  const [pass, setPass] = useState('')
  const [busy, setBusy] = useState(false)
  const [msg, setMsg] = useState<{ k: 'err' | 'ok'; t: string } | null>(null)
  const [forgot, setForgot] = useState(false)

  useEffect(() => { if (session && !loading) nav('/dashboard', { replace: true }) }, [session, loading])

  if (!isConfigured) {
    return (
      <div className="center-screen login-bg">
        <div className="card login-card">
          <h2 style={{ marginBottom: 10 }}>Falta conectar con Supabase</h2>
          <p>Abra el archivo <b>.env</b> del proyecto y escriba sus dos datos de Supabase:</p>
          <pre style={{ background: '#f4f6fb', padding: 12, borderRadius: 8, whiteSpace: 'pre-wrap', wordBreak: 'break-all', fontSize: 12 }}>VITE_SUPABASE_URL=https://xxxx.supabase.co{'\n'}VITE_SUPABASE_ANON_KEY=su-clave-publica</pre>
          <p className="muted small">Después guarde el archivo y vuelva a publicar la aplicación en Netlify.</p>
        </div>
      </div>
    )
  }

  const submit = async (e: FormEvent) => {
    e.preventDefault(); setBusy(true); setMsg(null)
    try {
      if (forgot) {
        const { error } = await supabase.auth.resetPasswordForEmail(email.trim(), { redirectTo: `${window.location.origin}/restablecer` })
        if (error) throw error
        setMsg({ k: 'ok', t: 'Si el correo existe, recibirá un enlace para crear una nueva contraseña.' })
      } else {
        const { error } = await supabase.auth.signInWithPassword({ email: email.trim(), password: pass })
        if (error) throw error
      }
    } catch (e2) { setMsg({ k: 'err', t: errMsg(e2) }) } finally { setBusy(false) }
  }

  return (
    <div className="center-screen login-bg">
      <form className="card login-card stack" onSubmit={submit}>
        <div className="row"><span className="brand" style={{ padding: 0, color: 'var(--navy)' }}><span className="logo">SC</span> Sistema Contable</span></div>
        <div><h2>{forgot ? 'Recuperar acceso' : 'Iniciar sesión'}</h2><div className="muted small">{forgot ? 'Le enviaremos un enlace por correo.' : 'Ingrese con su correo y contraseña.'}</div></div>
        <Field label="Correo electrónico"><input type="email" autoComplete="username" required value={email} onChange={(e) => setEmail(e.target.value)} /></Field>
        {!forgot && <Field label="Contraseña"><input type="password" autoComplete="current-password" required value={pass} onChange={(e) => setPass(e.target.value)} /></Field>}
        {msg && <div className={`alert ${msg.k}`}>{msg.t}</div>}
        <button className="btn primary" disabled={busy} style={{ justifyContent: 'center' }}>{busy ? 'Un momento…' : forgot ? 'Enviar enlace' : 'Ingresar'}</button>
        <button type="button" className="btn ghost sm" onClick={() => { setForgot(!forgot); setMsg(null) }}>{forgot ? 'Volver a iniciar sesión' : 'Olvidé mi contraseña'}</button>
      </form>
    </div>
  )
}

export function ResetPassword() {
  const nav = useNavigate()
  const [p1, setP1] = useState('')
  const [p2, setP2] = useState('')
  const [msg, setMsg] = useState<string | null>(null)
  const [done, setDone] = useState(false)
  const submit = async (e: FormEvent) => {
    e.preventDefault()
    if (p1.length < 8) return setMsg('La contraseña debe tener al menos 8 caracteres.')
    if (p1 !== p2) return setMsg('Las contraseñas no coinciden.')
    const { error } = await supabase.auth.updateUser({ password: p1 })
    if (error) return setMsg(errMsg(error))
    setDone(true); setTimeout(() => nav('/dashboard'), 1200)
  }
  return (
    <div className="center-screen login-bg">
      <form className="card login-card stack" onSubmit={submit}>
        <h2>Nueva contraseña</h2>
        <Field label="Nueva contraseña"><input type="password" required value={p1} onChange={(e) => setP1(e.target.value)} /></Field>
        <Field label="Repetir contraseña"><input type="password" required value={p2} onChange={(e) => setP2(e.target.value)} /></Field>
        {msg && <div className="alert err">{msg}</div>}
        {done && <div className="alert ok">Contraseña actualizada.</div>}
        <button className="btn primary">Guardar contraseña</button>
      </form>
    </div>
  )
}

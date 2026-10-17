import { useState } from 'react'
import { supabase } from '../lib/supabase'
import { errMsg } from '../lib/api'
import { useAuth } from '../context/Auth'
import { useToast } from '../context/Toast'
import { Field, PageHeader } from '../components/ui'

export default function Account() {
  const { profile, reload } = useAuth()
  const toast = useToast()
  const [name, setName] = useState<string>(profile?.full_name || '')
  const [p1, setP1] = useState('')
  const [p2, setP2] = useState('')
  const saveName = async () => {
    const { error } = await supabase.from('profiles').update({ full_name: name }).eq('id', profile?.id)
    if (error) return toast.err(errMsg(error))
    toast.ok('Nombre actualizado'); reload()
  }
  const savePass = async () => {
    if (p1.length < 8) return toast.err('La contraseña debe tener al menos 8 caracteres.')
    if (p1 !== p2) return toast.err('Las contraseñas no coinciden.')
    const { error } = await supabase.auth.updateUser({ password: p1 })
    if (error) return toast.err(errMsg(error))
    toast.ok('Contraseña actualizada'); setP1(''); setP2('')
  }
  return (
    <>
      <PageHeader title="Mi cuenta" sub={profile?.email} />
      <div className="grid g2">
        <div className="card card-pad stack"><h3>Mis datos</h3>
          <Field label="Nombre completo"><input type="text" value={name} onChange={(e) => setName(e.target.value)} /></Field>
          <div><button className="btn primary" onClick={saveName}>Guardar nombre</button></div>
        </div>
        <div className="card card-pad stack"><h3>Cambiar contraseña</h3>
          <Field label="Nueva contraseña" hint="Mínimo 8 caracteres"><input type="password" value={p1} onChange={(e) => setP1(e.target.value)} /></Field>
          <Field label="Repetir contraseña"><input type="password" value={p2} onChange={(e) => setP2(e.target.value)} /></Field>
          <div><button className="btn primary" onClick={savePass}>Cambiar contraseña</button></div>
        </div>
      </div>
    </>
  )
}

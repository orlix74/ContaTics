import { useState } from 'react'
import { NavLink, Outlet, useLocation, useNavigate } from 'react-router-dom'
import { useAuth } from '../context/Auth'
import { ROLE_LABEL } from '../lib/api'
import { Spinner } from './ui'

interface Item { to: string; label: string; perm?: string; platform?: boolean }
const NAV: { title: string; perm?: string; items: Item[] }[] = [
  { title: 'General', items: [{ to: '/dashboard', label: 'Panel principal' }, { to: '/aprobaciones/bandeja', label: 'Bandeja de aprobaciones' }, { to: '/aprobaciones/historial', label: 'Historial de aprobaciones' }] },
  { title: 'Contabilidad', items: [
    { to: '/contabilidad/asientos', label: 'Asientos contables' }, { to: '/contabilidad/plan-cuentas', label: 'Plan de cuentas' },
    { to: '/contabilidad/actividades', label: 'Actividades' }, { to: '/contabilidad/libro-diario', label: 'Libro diario' }, { to: '/contabilidad/libro-mayor', label: 'Libro mayor' } ] },
  { title: 'Compras', items: [{ to: '/compras/proveedores', label: 'Proveedores' }, { to: '/compras/facturas', label: 'Facturas de compra' }, { to: '/compras/pagos', label: 'Pagos a proveedores' }] },
  { title: 'Ventas', items: [{ to: '/ventas/clientes', label: 'Clientes' }, { to: '/ventas/facturas', label: 'Facturas de venta' }, { to: '/ventas/cobros', label: 'Cobros de clientes' }] },
  { title: 'Inventario', items: [{ to: '/inventario/productos', label: 'Productos' }, { to: '/inventario/movimientos', label: 'Movimientos y kardex' }, { to: '/inventario/ajustes', label: 'Ajustes de inventario' }, { to: '/inventario/configuracion', label: 'Valoración' }] },
  { title: 'Tesorería', items: [
    { to: '/tesoreria/cuentas', label: 'Cajas y bancos' }, { to: '/tesoreria/movimientos', label: 'Ingresos, egresos y transferencias' }, { to: '/tesoreria/extractos', label: 'Extractos bancarios' },
    { to: '/tesoreria/conciliaciones', label: 'Conciliaciones' } ] },
  { title: 'Reportes', items: [
    { to: '/reportes/balanza-comprobacion', label: 'Balanza de comprobación' }, { to: '/reportes/estado-situacion-financiera', label: 'Estado de situación' },
    { to: '/reportes/estado-resultados', label: 'Estado de resultados' }, { to: '/reportes/libro-diario', label: 'Libro diario' }, { to: '/reportes/libro-mayor', label: 'Libro mayor' },
    { to: '/reportes/cuentas-por-cobrar', label: 'Cuentas por cobrar' }, { to: '/reportes/cuentas-por-pagar', label: 'Cuentas por pagar' },
    { to: '/reportes/inventarios', label: 'Inventarios' }, { to: '/reportes/conciliaciones', label: 'Conciliaciones' }, { to: '/reportes/por-actividad', label: 'Resultados por actividad' } ] },
  { title: 'Configuración', perm: 'data.view', items: [
    { to: '/configuracion/empresa', label: 'Empresa' }, { to: '/configuracion/monedas', label: 'Monedas y tipos de cambio' }, { to: '/configuracion/impuestos', label: 'Impuestos' },
    { to: '/configuracion/periodos', label: 'Periodos contables' }, { to: '/configuracion/reglas', label: 'Reglas contables' }, { to: '/configuracion/estados-financieros', label: 'Plantillas de estados' },
    { to: '/configuracion/aprobaciones', label: 'Aprobaciones' }, { to: '/configuracion/numeracion', label: 'Numeración y pagos' }, { to: '/configuracion/integraciones', label: 'Integraciones' } ] },
  { title: 'Administración', items: [{ to: '/administracion/usuarios', label: 'Usuarios', perm: 'users.manage' }, { to: '/administracion/roles', label: 'Roles y permisos', perm: 'users.manage' }, { to: '/administracion/auditoria', label: 'Auditoría', perm: 'audit.view' }] },
]

export default function Layout() {
  const { org, orgs, selectOrg, profile, role, signOut, can, loading, isPlatformAdmin } = useAuth()
  const [open, setOpen] = useState(false)
  const loc = useLocation()
  const nav = useNavigate()
  if (loading) return <Spinner text="Cargando…" />
  const email: string = profile?.email || ''
  return (
    <div className="shell">
      <aside className={`sidebar ${open ? 'open' : ''}`}>
        <div className="brand"><span className="logo">SC</span> Sistema Contable</div>
        <nav className="nav" onClick={() => setOpen(false)}>
          <div className="nav-group">
            <div className="nav-title">Empresa</div>
            <NavLink to="/empresas">{isPlatformAdmin ? 'Empresas (crear / cambiar)' : 'Mis empresas'}</NavLink>
          </div>
          {NAV.map((g) => {
            const items = g.items.filter((i) => !i.perm || can(i.perm))
            if (!items.length || !org) return null
            return (
              <div className="nav-group" key={g.title}>
                <div className="nav-title">{g.title}</div>
                {items.map((i) => <NavLink key={i.to} to={i.to} className={({ isActive }) => (isActive ? 'active' : '')}>{i.label}</NavLink>)}
              </div>
            )
          })}
        </nav>
      </aside>
      <div className={`scrim ${open ? 'open' : ''}`} onClick={() => setOpen(false)} />
      <div className="main">
        <header className="topbar">
          <button className="menu-btn" aria-label="Abrir menú" onClick={() => setOpen(true)}>☰</button>
          {orgs.length > 0 ? (
            <select className="org-switch" value={org?.id || ''} onChange={(e) => { selectOrg(e.target.value); nav('/dashboard') }} aria-label="Empresa activa">
              {orgs.map((o) => <option key={o.id} value={o.id}>{o.trade_name || o.legal_name}</option>)}
            </select>
          ) : <span className="muted">Sin empresa activa</span>}
          {org && <span className="badge b-info nowrap">{org.base_currency}</span>}
          <span className="spacer" />
          <div className="user-chip">
            <span className="avatar">{(profile?.full_name || email || '?').slice(0, 1).toUpperCase()}</span>
            <span className="nm"><b>{profile?.full_name || email}</b><br /><span className="muted small">{isPlatformAdmin ? 'Administrador general · ' : ''}{role ? ROLE_LABEL[role] : ''}</span></span>
            <button className="btn sm" onClick={() => nav('/cuenta')}>Mi cuenta</button>
            <button className="btn sm" onClick={signOut}>Salir</button>
          </div>
        </header>
        <main className="content" key={loc.pathname.split('/').slice(0, 3).join('/')}><Outlet /></main>
      </div>
    </div>
  )
}

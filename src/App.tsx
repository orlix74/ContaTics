import { BrowserRouter, Navigate, Route, Routes } from 'react-router-dom'
import { AuthProvider, useAuth } from './context/Auth'
import { CatalogProvider } from './context/Catalog'
import { ToastProvider } from './context/Toast'
import Layout from './components/Layout'
import { Spinner } from './components/ui'
import { Login, ResetPassword } from './pages/Login'
import Account from './pages/Account'
import Orgs from './pages/Orgs'
import Dashboard from './pages/Dashboard'
import { ApprovalSettings, CompanySettings, Currencies, Integrations, InventorySettings, Numbering, Periods, Rules, StatementTemplates, Taxes } from './pages/Config'
import { PurchaseInvoiceForm, PurchaseInvoices, SalesInvoiceForm, SalesInvoices } from './pages/Invoices'
import { JournalForm, JournalList } from './pages/Journal'
import { CustomerReceiptForm, CustomerReceipts, SupplierPaymentForm, SupplierPayments } from './pages/Payments'
import { Accounts, Activities, Customers, Products, Suppliers } from './pages/Masters'
import { AdjustmentForm, AdjustmentList, Movements } from './pages/Inventory'
import { CashAccounts, CashMovementForm, CashMovementList, ReconciliationDetail, ReconciliationList, StatementImport, Statements } from './pages/Treasury'
import { ApprovalHistory, ApprovalInbox } from './pages/Approvals'
import { AuditLog, Roles, Users } from './pages/Admin'
import { BalanceSheet, ByActivity, IncomeStatement, InventoryReport, JournalBook, Ledger, Payables, ReconciliationsReport, Receivables, TrialBalance } from './pages/Reports'

function RequireAuth({ children }: { children: JSX.Element }) {
  const { loading, session } = useAuth()
  if (loading) return <Spinner text="Cargando…" />
  if (!session) return <Navigate to="/login" replace />
  return children
}

export default function App() {
  return (
    <BrowserRouter>
      <ToastProvider>
        <AuthProvider>
          <CatalogProvider>
            <Routes>
              <Route path="/login" element={<Login />} />
              <Route path="/restablecer" element={<ResetPassword />} />
              <Route element={<RequireAuth><Layout /></RequireAuth>}>
                <Route index element={<Navigate to="/dashboard" replace />} />
                <Route path="/dashboard" element={<Dashboard />} />
                <Route path="/cuenta" element={<Account />} />
                <Route path="/empresas" element={<Orgs />} />

                <Route path="/configuracion/empresa" element={<CompanySettings />} />
                <Route path="/configuracion/monedas" element={<Currencies />} />
                <Route path="/configuracion/impuestos" element={<Taxes />} />
                <Route path="/configuracion/periodos" element={<Periods />} />
                <Route path="/configuracion/reglas" element={<Rules />} />
                <Route path="/configuracion/estados-financieros" element={<StatementTemplates />} />
                <Route path="/configuracion/aprobaciones" element={<ApprovalSettings />} />
                <Route path="/configuracion/numeracion" element={<Numbering />} />
                <Route path="/configuracion/integraciones" element={<Integrations />} />

                <Route path="/contabilidad/asientos" element={<JournalList />} />
                <Route path="/contabilidad/asientos/:id" element={<JournalForm />} />
                <Route path="/contabilidad/plan-cuentas" element={<Accounts />} />
                <Route path="/contabilidad/actividades" element={<Activities />} />
                <Route path="/contabilidad/libro-diario" element={<JournalBook />} />
                <Route path="/contabilidad/libro-mayor" element={<Ledger />} />

                <Route path="/compras/proveedores" element={<Suppliers />} />
                <Route path="/compras/facturas" element={<PurchaseInvoices />} />
                <Route path="/compras/facturas/:id" element={<PurchaseInvoiceForm />} />
                <Route path="/compras/pagos" element={<SupplierPayments />} />
                <Route path="/compras/pagos/:id" element={<SupplierPaymentForm />} />

                <Route path="/ventas/clientes" element={<Customers />} />
                <Route path="/ventas/facturas" element={<SalesInvoices />} />
                <Route path="/ventas/facturas/:id" element={<SalesInvoiceForm />} />
                <Route path="/ventas/cobros" element={<CustomerReceipts />} />
                <Route path="/ventas/cobros/:id" element={<CustomerReceiptForm />} />

                <Route path="/inventario/productos" element={<Products />} />
                <Route path="/inventario/movimientos" element={<Movements />} />
                <Route path="/inventario/ajustes" element={<AdjustmentList />} />
                <Route path="/inventario/ajustes/:id" element={<AdjustmentForm />} />
                <Route path="/inventario/configuracion" element={<InventorySettings />} />

                <Route path="/tesoreria/cuentas" element={<CashAccounts />} />
                <Route path="/tesoreria/movimientos" element={<CashMovementList />} />
                <Route path="/tesoreria/movimientos/:id" element={<CashMovementForm />} />
                <Route path="/tesoreria/extractos" element={<Statements />} />
                <Route path="/tesoreria/extractos/importar" element={<StatementImport />} />
                <Route path="/tesoreria/conciliaciones" element={<ReconciliationList />} />
                <Route path="/tesoreria/conciliaciones/:id" element={<ReconciliationDetail />} />

                <Route path="/aprobaciones/bandeja" element={<ApprovalInbox />} />
                <Route path="/aprobaciones/historial" element={<ApprovalHistory />} />

                <Route path="/reportes/balanza-comprobacion" element={<TrialBalance />} />
                <Route path="/reportes/estado-situacion-financiera" element={<BalanceSheet />} />
                <Route path="/reportes/estado-resultados" element={<IncomeStatement />} />
                <Route path="/reportes/libro-diario" element={<JournalBook />} />
                <Route path="/reportes/libro-mayor" element={<Ledger />} />
                <Route path="/reportes/cuentas-por-cobrar" element={<Receivables />} />
                <Route path="/reportes/cuentas-por-pagar" element={<Payables />} />
                <Route path="/reportes/inventarios" element={<InventoryReport />} />
                <Route path="/reportes/conciliaciones" element={<ReconciliationsReport />} />
                <Route path="/reportes/por-actividad" element={<ByActivity />} />

                <Route path="/administracion/usuarios" element={<Users />} />
                <Route path="/administracion/roles" element={<Roles />} />
                <Route path="/administracion/auditoria" element={<AuditLog />} />
                <Route path="*" element={<Navigate to="/dashboard" replace />} />
              </Route>
            </Routes>
          </CatalogProvider>
        </AuthProvider>
      </ToastProvider>
    </BrowserRouter>
  )
}

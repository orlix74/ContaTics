import { supabase } from './supabase'

export type Row = any

const FRIENDLY: [RegExp, string][] = [
  [/purchase_invoice_dup_uk/, 'Ya existe una factura de ese proveedor con ese número.'],
  [/sales_invoice_dup_uk/, 'Ya existe una factura de venta con ese número.'],
  [/suppliers_tax_uk|customers_tax_uk/, 'Ya existe un registro con ese NIT / identificación.'],
  [/accounts_organization_id_code_key/, 'Ya existe una cuenta con ese código.'],
  [/duplicate key value/, 'Ya existe un registro con esos mismos datos.'],
  [/row-level security/, 'No tiene permiso para realizar esta acción.'],
  [/violates foreign key constraint/, 'No se puede completar: el registro está siendo usado por otros datos.'],
  [/invalid input syntax for type (numeric|integer)/, 'Hay un número con formato inválido.'],
  [/invalid input syntax for type date/, 'Hay una fecha inválida.'],
  [/violates check constraint/, 'Hay un dato fuera del rango permitido.'],
  [/violates not-null constraint/, 'Falta completar un dato obligatorio.'],
  [/Invalid login credentials/, 'Correo o contraseña incorrectos.'],
  [/Failed to fetch|NetworkError/, 'No hay conexión con el servidor. Revise su internet y la configuración de Supabase.'],
]

export function errMsg(e: any): string {
  const raw: string = (e && (e.message || e.error_description || e.details)) || String(e)
  for (const [re, txt] of FRIENDLY) if (re.test(raw)) return txt
  return raw
}

export async function rpc<T = any>(fn: string, args?: Row): Promise<T> {
  const { data, error } = await supabase.rpc(fn, args || {})
  if (error) throw new Error(errMsg(error))
  return data as T
}

export function unwrap<T>(res: { data: T | null; error: any }): T {
  if (res.error) throw new Error(errMsg(res.error))
  return res.data as T
}

export const DOC_TYPE_LABEL: Record<string, string> = {
  purchase_invoice: 'Factura de compra',
  sales_invoice: 'Factura de venta',
  supplier_payment: 'Pago a proveedor',
  customer_receipt: 'Cobro de cliente',
  journal_entry: 'Asiento contable',
  inventory_adjustment: 'Ajuste de inventario',
  cash_movement: 'Movimiento de caja/banco',
  bank_reconciliation: 'Conciliación bancaria',
}

export const DOC_ROUTE: Record<string, string> = {
  purchase_invoice: '/compras/facturas',
  sales_invoice: '/ventas/facturas',
  supplier_payment: '/compras/pagos',
  customer_receipt: '/ventas/cobros',
  journal_entry: '/contabilidad/asientos',
  inventory_adjustment: '/inventario/ajustes',
  cash_movement: '/tesoreria/movimientos',
  bank_reconciliation: '/tesoreria/conciliaciones',
}

export const STATUS_LABEL: Record<string, string> = {
  draft: 'Borrador',
  pending_approval: 'Pendiente de aprobación',
  rejected: 'Rechazado',
  approved: 'Aprobado · por contabilizar',
  posted: 'Contabilizado',
  voided: 'Anulado',
}

export const ROLE_LABEL: Record<string, string> = {
  admin: 'Administrador',
  accountant: 'Contador',
  assistant: 'Auxiliar contable',
  purchasing: 'Compras',
  auditor: 'Auditor (solo lectura)',
}

export const PERMISSION_LABEL: Record<string, string> = {
  'data.view': 'Consultar información',
  'config.manage': 'Configuración general',
  'users.manage': 'Usuarios y roles',
  'audit.view': 'Ver auditoría',
  'accounts.manage': 'Plan de cuentas, actividades y plantillas',
  'masters.manage': 'Proveedores, clientes, productos y cuentas de caja/banco',
  'purchases.create': 'Registrar facturas de compra',
  'sales.create': 'Registrar facturas de venta',
  'payments.create': 'Preparar pagos a proveedores',
  'receipts.create': 'Preparar cobros de clientes',
  'treasury.create': 'Movimientos de caja/banco',
  'journal.create': 'Registrar asientos manuales',
  'inventory.create': 'Ajustes de inventario',
  'documents.submit': 'Enviar documentos a aprobación',
  'documents.approve': 'Aprobar / rechazar documentos',
  'documents.post': 'Contabilizar documentos aprobados',
  'documents.reverse': 'Anular / revertir documentos',
  'periods.close': 'Cerrar periodos',
  'periods.reopen': 'Reabrir periodos',
  'bank.import': 'Importar extractos bancarios',
  'bank.reconcile': 'Conciliar bancos',
  'reports.export': 'Exportar reportes',
  'attachments.manage': 'Adjuntar y eliminar archivos',
}

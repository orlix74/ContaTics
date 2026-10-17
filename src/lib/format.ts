export const round2 = (n: number) => Math.round((n + Number.EPSILON) * 100) / 100

export const num = (v: any): number => {
  if (v === null || v === undefined || v === '') return 0
  const n = typeof v === 'number' ? v : parseFloat(String(v).replace(',', '.'))
  return Number.isFinite(n) ? n : 0
}

const nf = new Intl.NumberFormat('es-BO', { minimumFractionDigits: 2, maximumFractionDigits: 2 })
export const money = (v: any) => nf.format(num(v))
export const qty = (v: any, d = 4) =>
  new Intl.NumberFormat('es-BO', { minimumFractionDigits: 0, maximumFractionDigits: d }).format(num(v))

export const today = () => {
  const d = new Date()
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
}
export const firstOfYear = () => `${new Date().getFullYear()}-01-01`
export const firstOfMonth = () => today().slice(0, 8) + '01'

export const fdate = (s?: string | null) => {
  if (!s) return ''
  const [y, m, d] = s.slice(0, 10).split('-')
  return `${d}/${m}/${y}`
}
export const fdatetime = (s?: string | null) => {
  if (!s) return ''
  const d = new Date(s)
  return d.toLocaleString('es-BO', { dateStyle: 'short', timeStyle: 'short' })
}

export const addDays = (s: string, days: number) => {
  const d = new Date(s + 'T00:00:00')
  d.setDate(d.getDate() + days)
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
}

export const daysBetween = (a: string, b: string) =>
  Math.round((new Date(b + 'T00:00:00').getTime() - new Date(a + 'T00:00:00').getTime()) / 86400000)

export async function sha256(file: File): Promise<string> {
  const buf = await file.arrayBuffer()
  const h = await crypto.subtle.digest('SHA-256', buf)
  return Array.from(new Uint8Array(h)).map((b) => b.toString(16).padStart(2, '0')).join('')
}

import writeXlsxFile from 'write-excel-file/browser'
import { jsPDF } from 'jspdf'
import autoTable from 'jspdf-autotable'
import { money, qty, fdate, num } from './format'

export interface ReportCol {
  key: string
  label: string
  type?: 'text' | 'money' | 'qty' | 'date'
}
export interface ReportMeta {
  title: string
  company: string
  taxId?: string | null
  period?: string
  currency?: string
  filters?: string[]
}
type R = Record<string, any>

const fmtCell = (c: ReportCol, v: any): string => {
  if (v === null || v === undefined) return ''
  if (c.type === 'money') return money(v)
  if (c.type === 'qty') return qty(v)
  if (c.type === 'date') return fdate(v)
  return String(v)
}

const safeName = (s: string) => s.replace(/[^\w\-áéíóúñÁÉÍÓÚÑ ]+/g, '').trim().replace(/\s+/g, '_')

function headerLines(meta: ReportMeta): string[] {
  const l = [meta.company]
  if (meta.taxId) l.push(`NIT / ID tributario: ${meta.taxId}`)
  l.push(meta.title)
  if (meta.period) l.push(`Periodo: ${meta.period}`)
  if (meta.currency) l.push(`Moneda: ${meta.currency}`)
  if (meta.filters && meta.filters.length) l.push(`Filtros: ${meta.filters.join(' · ')}`)
  l.push(`Generado: ${new Date().toLocaleString('es-BO')}`)
  return l
}

export async function exportExcel(meta: ReportMeta, cols: ReportCol[], rows: R[], totals?: R) {
  const data: any[][] = []
  headerLines(meta).forEach((t, i) => data.push([{ value: t, type: String, fontWeight: i === 0 || i === 2 ? 'bold' : undefined }]))
  data.push([])
  data.push(cols.map((c) => ({ value: c.label, type: String, fontWeight: 'bold', backgroundColor: '#E8ECF4' })))
  const cell = (c: ReportCol, v: any): any => {
    if (c.type === 'money') return { value: num(v), type: Number, format: '#,##0.00' }
    if (c.type === 'qty') return { value: num(v), type: Number, format: '#,##0.####' }
    return { value: fmtCell(c, v), type: String }
  }
  rows.forEach((r) => data.push(cols.map((c) => cell(c, r[c.key]))))
  if (totals) {
    data.push(cols.map((c, i) => {
      const cc = cell(c, totals[c.key])
      return { ...cc, fontWeight: 'bold', ...(i === 0 && !totals[c.key] ? { value: 'TOTALES', type: String } : {}) }
    }))
  }
  await writeXlsxFile(data, { columns: cols.map((c, i) => ({ width: i === 0 ? 18 : c.type === 'text' || !c.type ? 34 : 16 })) } as any).toFile(
    `${safeName(meta.title)}_${new Date().toISOString().slice(0, 10)}.xlsx`
  )
}

export function exportPdf(meta: ReportMeta, cols: ReportCol[], rows: R[], totals?: R) {
  const landscape = cols.length > 6
  const doc = new jsPDF({ orientation: landscape ? 'landscape' : 'portrait', unit: 'pt', format: 'a4' })
  const lines = headerLines(meta)
  doc.setFont('helvetica', 'bold'); doc.setFontSize(13); doc.text(lines[0], 40, 42)
  doc.setFont('helvetica', 'normal'); doc.setFontSize(9)
  let y = 58
  lines.slice(1).forEach((t, i) => {
    if (i === (meta.taxId ? 1 : 0)) { doc.setFont('helvetica', 'bold'); doc.setFontSize(11) }
    doc.text(t, 40, y)
    doc.setFont('helvetica', 'normal'); doc.setFontSize(9)
    y += 13
  })
  const body = rows.map((r) => cols.map((c) => fmtCell(c, r[c.key])))
  const foot = totals ? [cols.map((c, i) => (totals[c.key] !== undefined && totals[c.key] !== '' ? fmtCell(c, totals[c.key]) : i === 0 ? 'TOTALES' : ''))] : undefined
  const align = (c: ReportCol) => (c.type === 'money' || c.type === 'qty' ? 'right' : 'left')
  autoTable(doc, {
    startY: y + 6,
    head: [cols.map((c) => c.label)],
    body,
    foot,
    styles: { fontSize: 8, cellPadding: 3 },
    headStyles: { fillColor: [20, 33, 61] },
    footStyles: { fillColor: [232, 236, 244], textColor: 20, fontStyle: 'bold' },
    columnStyles: Object.fromEntries(cols.map((c, i) => [i, { halign: align(c) }])),
    didDrawPage: () => {
      const n = doc.getNumberOfPages()
      doc.setFontSize(8)
      doc.text(`Página ${n}`, doc.internal.pageSize.getWidth() - 70, doc.internal.pageSize.getHeight() - 20)
    },
  })
  doc.save(`${safeName(meta.title)}_${new Date().toISOString().slice(0, 10)}.pdf`)
}

import { createContext, useCallback, useContext, useState, ReactNode } from 'react'

type T = { id: number; kind: 'ok' | 'err' | 'info'; text: string }
const Ctx = createContext<{ ok: (t: string) => void; err: (t: string) => void; info: (t: string) => void }>({
  ok: () => {}, err: () => {}, info: () => {},
})
export const useToast = () => useContext(Ctx)

export function ToastProvider({ children }: { children: ReactNode }) {
  const [items, setItems] = useState<T[]>([])
  const push = useCallback((kind: T['kind'], text: string) => {
    const id = Date.now() + Math.random()
    setItems((x) => [...x, { id, kind, text }])
    setTimeout(() => setItems((x) => x.filter((i) => i.id !== id)), kind === 'err' ? 7000 : 3500)
  }, [])
  const api = {
    ok: (t: string) => push('ok', t),
    err: (t: string) => push('err', t),
    info: (t: string) => push('info', t),
  }
  return (
    <Ctx.Provider value={api}>
      {children}
      <div className="toasts" role="status" aria-live="polite">
        {items.map((i) => (
          <div key={i.id} className={`toast ${i.kind}`} onClick={() => setItems((x) => x.filter((y) => y.id !== i.id))}>
            {i.text}
          </div>
        ))}
      </div>
    </Ctx.Provider>
  )
}

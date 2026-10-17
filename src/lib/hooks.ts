import { useCallback, useEffect, useRef, useState } from 'react'
import { errMsg } from './api'

export function useAsync<T>(fn: () => Promise<T>, deps: any[], initial?: T) {
  const [data, setData] = useState<T | undefined>(initial)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const seq = useRef(0)
  const run = useCallback(async () => {
    const my = ++seq.current
    setLoading(true)
    try {
      const r = await fn()
      if (my === seq.current) { setData(r); setError(null) }
    } catch (e) {
      if (my === seq.current) setError(errMsg(e))
    } finally {
      if (my === seq.current) setLoading(false)
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps)
  useEffect(() => { run() }, [run])
  return { data, loading, error, reload: run, setData }
}

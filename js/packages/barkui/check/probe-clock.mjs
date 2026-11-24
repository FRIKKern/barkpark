// Throwaway timing probe: where a part's seconds go. Not for main.
export const clock = new Map()
export const tick = (k, ms) => {
  const c = clock.get(k) ?? { n: 0, ms: 0 }
  c.n++
  c.ms += ms
  clock.set(k, c)
}
export const timed = async (k, p) => {
  const t = performance.now()
  try {
    return await p
  } finally {
    tick(k, performance.now() - t)
  }
}
export const clockLine = () => [...clock].map(([k, c]) => `${k} ${c.n}x ${(c.ms / 1000).toFixed(1)}s`).join('; ')
export const clockReset = () => clock.clear()

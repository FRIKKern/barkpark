// The corpus graph, Astro-island edition: the SAME zero-dependency Canvas2D
// renderer (public/bp-graph.js, byte-identical mirror) over a corpus BAKED at
// build into graph.json — instant load, no runtime token, no API round-trip.
import { useEffect, useRef } from 'react'

declare global {
  interface Window {
    BarkparkGraphRenderer?: new (el: HTMLElement, opts: Record<string, unknown>) => {
      update(corpus: unknown): void
      destroy(): void
    }
  }
}

export default function GraphIsland({ base }: { base: string }) {
  const ref = useRef<HTMLDivElement>(null)
  useEffect(() => {
    let renderer: { update(c: unknown): void; destroy(): void } | null = null
    let cancelled = false
    const boot = async () => {
      if (!window.BarkparkGraphRenderer) {
        await new Promise<void>((resolve, reject) => {
          const s = document.createElement('script')
          s.src = base + 'bp-graph.js'
          s.onload = () => resolve()
          s.onerror = () => reject(new Error('bp-graph.js failed to load'))
          document.head.appendChild(s)
        })
      }
      if (cancelled || !ref.current || !window.BarkparkGraphRenderer) return
      const theme = document.documentElement.dataset.theme === 'dark' ? 'dark' : 'light'
      renderer = new window.BarkparkGraphRenderer(ref.current, { theme })
      const corpus = await fetch(base + 'graph.json').then((r) => r.json())
      if (!cancelled) renderer.update(corpus)
    }
    boot().catch((e) => console.error('[graph]', e))
    return () => {
      cancelled = true
      renderer?.destroy()
    }
  }, [base])
  return <div ref={ref} style={{ position: 'absolute', inset: 0 }} aria-label="Corpus graph" />
}

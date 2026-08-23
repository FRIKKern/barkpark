// @vitest-environment happy-dom
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// The theme-FLIP half of mermaid theming.
//
// `activeMermaidTheme` (tests/client-theme.test.ts) already pins the theme a
// diagram is FIRST painted with. This file pins what happens AFTERWARDS: the
// `<pre class="mermaid">` stashes `data-bp-src` with a comment promising "a
// palette re-render", and until now nothing kept that promise — flipping a
// page to dark left every already-rendered diagram on the light palette,
// because mermaid bakes its colours into the emitted SVG and exposes no
// restyle API.
//
// The mermaid module is mocked, so `mermaid.run` never really produces an SVG.
// That mock could easily DEFUSE the thing under test, so every assertion here
// is about state the SOURCE owns, not state the mock owns:
//   • the theme passed to `initialize` (the source computes it);
//   • the node's `textContent` at run time (the source restores it from
//     `data-bp-src` — a mock cannot);
//   • the `data-processed` stamp at run time (the source clears it — a run
//     that still sees `"true"` is the real mermaid's no-op path).
// Each is mutation-proven in the PR body.

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'

interface RunCall {
  theme: unknown
  sources: string[]
  processedStamps: Array<string | null>
}

const runCalls: RunCall[] = []
let lastTheme: unknown

vi.mock('mermaid', () => ({
  default: {
    initialize(config: { theme?: unknown }) {
      lastTheme = config.theme
    },
    run({ nodes }: { nodes: HTMLElement[] }) {
      runCalls.push({
        theme: lastTheme,
        sources: nodes.map((n) => n.textContent ?? ''),
        processedStamps: nodes.map((n) => n.getAttribute('data-processed')),
      })
      // The real mermaid stamps each node it processed; mirror that so the
      // idempotency guard under test behaves as it does in a browser.
      for (const n of nodes) n.setAttribute('data-processed', 'true')
    },
  },
}))

const { hydratePortableDoc, watchMermaidTheme, stopMermaidThemeWatch } =
  await import('../src/client')

/** A media-query object whose `matches` we can flip, with real listeners. */
function installMatchMedia(initialDark: boolean) {
  const listeners = new Set<(e: unknown) => void>()
  const mq = {
    matches: initialDark,
    addEventListener: (_: string, fn: (e: unknown) => void) => {
      listeners.add(fn)
    },
    removeEventListener: (_: string, fn: (e: unknown) => void) => {
      listeners.delete(fn)
    },
  }
  ;(window as unknown as { matchMedia: unknown }).matchMedia = (q: string) =>
    q.includes('dark') ? mq : { ...mq, matches: false }
  return {
    flip(dark: boolean) {
      mq.matches = dark
      for (const fn of listeners) fn({ matches: dark })
    },
    listenerCount: () => listeners.size,
  }
}

// Built through `textContent`, not `innerHTML`: the Phoenix/React emitters
// HTML-ESCAPE the diagram source, so `A-->B` reaches the DOM as text. Writing
// the raw arrow through `innerHTML` instead lets the parser eat it (measured:
// happy-dom returned `graph TD; Agraph TD; A-->B;`) — a fixture artefact that
// has nothing to do with what ships.
function mountDiagram(source = 'graph TD; A-->B;'): HTMLElement {
  document.body.innerHTML = ''
  const pre = document.createElement('pre')
  pre.className = 'mermaid'
  pre.textContent = source
  document.body.appendChild(pre)
  return pre
}

/** Let the MutationObserver microtask and the async repaint settle. */
async function settle() {
  for (let i = 0; i < 4; i++) await Promise.resolve()
  await new Promise((r) => setTimeout(r, 0))
}

beforeEach(() => {
  runCalls.length = 0
  lastTheme = undefined
  stopMermaidThemeWatch(document)
  document.documentElement.removeAttribute('data-theme')
  document.body.innerHTML = ''
})

afterEach(() => {
  stopMermaidThemeWatch(document)
})

describe('theme flip → repaint', () => {
  it('a data-theme flip re-renders processed diagrams from data-bp-src', async () => {
    installMatchMedia(false)
    const pre = mountDiagram('graph TD; A-->B;')

    await hydratePortableDoc(document)
    expect(runCalls).toHaveLength(1)
    expect(runCalls[0]!.theme).toBe('default')
    expect(pre.dataset.bpSrc).toBe('graph TD; A-->B;')
    expect(pre.getAttribute('data-processed')).toBe('true')

    // Whatever mermaid left in the <pre> is NOT the diagram source any more.
    pre.textContent = '<svg>light palette</svg>'

    document.documentElement.setAttribute('data-theme', 'dark')
    await settle()

    expect(runCalls, 'the flip must trigger a second run').toHaveLength(2)
    const repaint = runCalls[1]!
    expect(repaint.theme).toBe('dark')
    // The source — restored from data-bp-src, not the SVG the first run left.
    expect(repaint.sources).toEqual(['graph TD; A-->B;'])
    // Cleared before the run: the real mermaid.run SKIPS a processed node, so
    // a repaint that leaves the stamp on is a silent no-op.
    expect(repaint.processedStamps).toEqual([null])
    // Re-stamped afterwards — idempotency survives the repaint.
    expect(pre.getAttribute('data-processed')).toBe('true')
  })

  it('an OS prefers-color-scheme flip repaints when no stamp is present', async () => {
    const mm = installMatchMedia(false)
    mountDiagram()
    await hydratePortableDoc(document)
    expect(runCalls[0]!.theme).toBe('default')

    mm.flip(true)
    await settle()

    expect(runCalls).toHaveLength(2)
    expect(runCalls[1]!.theme).toBe('dark')
  })

  it('an OS flip UNDER an explicit stamp repaints nothing — the stamp wins', async () => {
    const mm = installMatchMedia(false)
    document.documentElement.setAttribute('data-theme', 'light')
    mountDiagram()
    await hydratePortableDoc(document)
    expect(runCalls).toHaveLength(1)

    mm.flip(true)
    await settle()

    expect(runCalls, 'data-theme="light" outranks the OS preference').toHaveLength(1)
  })

  it('a stamp change that resolves to the SAME theme repaints nothing', async () => {
    installMatchMedia(false)
    document.documentElement.setAttribute('data-theme', 'light')
    mountDiagram()
    await hydratePortableDoc(document)
    expect(runCalls).toHaveLength(1)

    // light → sepia: both are "not dark", so mermaid's theme is unchanged.
    document.documentElement.setAttribute('data-theme', 'sepia')
    await settle()
    expect(runCalls).toHaveLength(1)

    // …and dark still repaints, proving the guard is on the RESOLVED theme
    // rather than on "we already fired once".
    document.documentElement.setAttribute('data-theme', 'dark')
    await settle()
    expect(runCalls).toHaveLength(2)
    expect(runCalls[1]!.theme).toBe('dark')
  })
})

describe('the watch is installed exactly once, and only when it can pay off', () => {
  it('a diagram-free page installs NO listeners', async () => {
    const mm = installMatchMedia(false)
    document.body.innerHTML = '<p>no diagrams here</p>'
    await hydratePortableDoc(document)
    expect(runCalls).toHaveLength(0)
    expect(mm.listenerCount()).toBe(0)
  })

  it('repeated hydration does not stack watches', async () => {
    const mm = installMatchMedia(false)
    mountDiagram('graph TD; A---B;')
    await hydratePortableDoc(document)
    expect(runCalls).toHaveLength(1)
    expect(mm.listenerCount()).toBe(1)

    // The stream-delta case the module's own doc comment names: new diagrams
    // arrive, so hydrateMermaid reaches the install site a SECOND time. A
    // re-hydrate over an already-processed node cannot exercise this — it
    // short-circuits on `nodes.length === 0` and never gets there.
    const second = document.createElement('pre')
    second.className = 'mermaid'
    second.textContent = 'graph TD; C---D;'
    document.body.appendChild(second)
    await hydratePortableDoc(document)
    expect(runCalls).toHaveLength(2)

    // The listener count is the deterministic witness: a second watch means a
    // second `prefers-color-scheme` subscription, and every later flip is
    // handled twice — a duplicated repaint of the whole page per diagram
    // batch, growing without bound on a streaming surface.
    expect(mm.listenerCount(), 'exactly one watch per document').toBe(1)

    document.documentElement.setAttribute('data-theme', 'dark')
    await settle()
    expect(runCalls).toHaveLength(3)
  })

  it('the disposer stops repaints and is safe to call twice', async () => {
    installMatchMedia(false)
    mountDiagram()
    await hydratePortableDoc(document)

    stopMermaidThemeWatch(document)
    stopMermaidThemeWatch(document)

    document.documentElement.setAttribute('data-theme', 'dark')
    await settle()
    expect(runCalls).toHaveLength(1)
  })

  it('watchMermaidTheme can be driven directly and returns an unsubscribe', async () => {
    installMatchMedia(false)
    const pre = mountDiagram('graph TD; X-->Y;')
    pre.dataset.bpSrc = 'graph TD; X-->Y;'
    pre.setAttribute('data-processed', 'true')

    const stop = watchMermaidTheme(document)
    document.documentElement.setAttribute('data-theme', 'dark')
    await settle()
    expect(runCalls).toHaveLength(1)
    expect(runCalls[0]!.theme).toBe('dark')

    stop()
    document.documentElement.removeAttribute('data-theme')
    await settle()
    expect(runCalls).toHaveLength(1)
  })
})

describe('this package never stamps data-theme itself', () => {
  it('hydration leaves <html data-theme> exactly as the consumer set it', async () => {
    installMatchMedia(true)
    mountDiagram()
    await hydratePortableDoc(document)
    expect(document.documentElement.hasAttribute('data-theme')).toBe(false)

    document.documentElement.setAttribute('data-theme', 'light')
    await settle()
    expect(document.documentElement.getAttribute('data-theme')).toBe('light')
  })
})

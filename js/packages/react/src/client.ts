// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// @barkpark/react/client — framework-free MEDIA + TAB hydration for
// PortableDoc's static mount points (charter D5 / W4).
//
// `PortableDoc` (the canonical renderer) emits the two media blocks as INERT
// mount points, byte-exact to the Phoenix emitter (`figures.ex`):
//
//   diagram   → <pre class="mermaid">…source…</pre>
//   asciicast → <div class="bp-asciicast" data-cast-src="…"></div>
//
// and the two I1 tab blocks as a server-painted shell with EVERY panel
// visible (compose.ex's `tabs` / `code-tabs` :article legs — NO-JS DEGRADE
// is every panel stacked, never a blank tab):
//
//   tabs      → <div class="bp-tabs">…strip + N visible .bp-tabs__panel…</div>
//   code-tabs → <div class="bp-code-tabs">…strip + N visible .bp-code-tabs__panel…</div>
//
// Rendering the SVG / mounting the terminal player / collapsing the tab
// panels to one is a CONSUMING-APP concern — exactly as `bulldocs.html.heex`
// (not `compose.ex`) owns hydration in Phoenix. `hydratePortableDoc(root)` is
// that consumer-side hook, reshaped off the LiveView `PaperMermaid` hook's
// `runMermaid` / `runAsciicast` (mermaid/asciicast) and duplicated afresh for
// the tab pair (I1 — the SAME framework-free DOM-scan shape, no shared
// runtime with the Phoenix hook by design; see bulldocs.html.heex). It is:
//
//   • framework-free — no React, no hooks, plain DOM: call it from a Next
//     `useEffect`, an Astro `<script>`, or any place the mount points are live.
//   • lazy — `mermaid` and `asciinema-player` are `import()`-ed ONLY when a
//     matching mount point exists, so a media-free page pays nothing and neither
//     library lands in `dist/client.mjs` (both are `external` + dynamic). The
//     tab hydration is plain DOM (no dynamic import) — it costs nothing extra.
//   • idempotent — `data-processed` (mermaid) / `data-asciicast-done` /
//     `data-hydrated` (tabs, code-tabs) guard re-runs, so it is safe to call
//     on every render / stream delta.

// A minimal window into the two runtimes' surfaces we actually touch. Both
// packages ship their own `.d.ts`, but declaring the exact call shape here keeps
// this module honest about what it depends on and survives a major bump that
// only widens the API.
interface MermaidLike {
  initialize(config: { startOnLoad?: boolean; [k: string]: unknown }): void
  run(opts: { nodes: HTMLElement[] }): Promise<void> | void
}
interface AsciinemaLike {
  create(src: string, el: HTMLElement, opts?: Record<string, unknown>): unknown
}

// `:not([data-processed="true"])` mirrors the Phoenix hook: mermaid stamps
// `data-processed="true"` on a `<pre>` once rendered, so re-selecting skips it.
const MERMAID_SELECTOR = 'pre.mermaid:not([data-processed="true"])'
// A mount point is only live once it carries `data-cast-src`; the `done` guard
// is our own idempotency stamp (mirrors the LiveView hook).
const ASCIICAST_SELECTOR = 'div.bp-asciicast[data-cast-src]:not([data-asciicast-done="true"])'
// `data-hydrated` is this module's own idempotency stamp for the tab pair
// (there is no server-side equivalent of mermaid's `data-processed` — the
// shell never marks a panel active, so hydration owns the whole guard).
const CODE_TABS_SELECTOR = 'div.bp-code-tabs:not([data-hydrated="true"])'
const TABS_SELECTOR = 'div.bp-tabs:not([data-hydrated="true"])'

/** Per-call tally of what actually hydrated — lets a caller/test assert work. */
export interface HydrateResult {
  /** Diagrams rendered into SVGs this call. */
  mermaid: number
  /** Asciinema players mounted this call. */
  asciicast: number
  /** `code-tabs` containers wired to a click-to-switch strip this call. */
  codeTabs: number
  /** `tabs` containers wired to a click-to-switch strip this call. */
  tabs: number
}

/**
 * Hydrate every un-processed PortableDoc media/tab mount point under `root`
 * into a live diagram / player / tab strip. Framework-free and idempotent —
 * drop it in a Next `useEffect(() => { hydratePortableDoc(ref.current) }, [])`,
 * an Astro island `<script>`, or call it after any DOM update that adds
 * `diagram`/`asciicast`/`tabs`/`code-tabs` blocks.
 *
 * @param root  The subtree to scan (defaults to `document`).
 * @returns     Counts of diagrams/players/tab-containers actually hydrated
 *              this call.
 */
export async function hydratePortableDoc(
  root: ParentNode = document,
): Promise<HydrateResult> {
  const [mermaid, asciicast] = await Promise.all([
    hydrateMermaid(root),
    hydrateAsciicast(root),
  ])
  const codeTabs = hydrateCodeTabs(root)
  const tabs = hydrateTabs(root)
  return { mermaid, asciicast, codeTabs, tabs }
}

/**
 * The mermaid theme for the ACTIVE color mode. Mermaid bakes its palette into
 * the rendered SVG (it never reads CSS custom properties), so an un-themed
 * `initialize` paints light-palette diagrams that are illegible on a dark
 * `.bp-paper-surface`. Resolution order mirrors how `paper-surface.css` itself
 * resolves dark mode: an explicit `data-theme` stamp on `<html>` wins (the
 * Studio/blog-starter toggle contract — `dark` → dark, any other stamp → light),
 * else the OS `prefers-color-scheme` decides (the Phoenix reader hooks'
 * `matchMedia` leg in bulldocs.html.heex / bp-paper-mermaid.js).
 *
 * Exported for tests; safe anywhere `document` exists.
 */
export function activeMermaidTheme(
  doc: Document = document,
): 'dark' | 'default' {
  const stamped = doc.documentElement?.getAttribute('data-theme')
  if (stamped === 'dark') return 'dark'
  if (stamped != null && stamped !== '') return 'default'
  const win = doc.defaultView
  return typeof win?.matchMedia === 'function' &&
    win.matchMedia('(prefers-color-scheme: dark)').matches
    ? 'dark'
    : 'default'
}

async function hydrateMermaid(root: ParentNode): Promise<number> {
  const nodes = Array.from(
    root.querySelectorAll<HTMLElement>(MERMAID_SELECTOR),
  )
  if (nodes.length === 0) return 0

  // Stash the raw source before the first run — mermaid replaces the `<pre>`'s
  // text with the rendered SVG, and a palette re-render needs the original
  // (mirrors the Phoenix hook's `data-bp-src`).
  for (const n of nodes) {
    if (n.dataset.bpSrc == null) n.dataset.bpSrc = n.textContent ?? ''
  }

  const mermaid = (await import('mermaid')).default as unknown as MermaidLike
  // Manual mode (`startOnLoad:false`): we drive rendering, mirroring the hook —
  // `mermaid.run` marks each processed node `data-processed="true"`. Theme
  // derives from the active mode so dark-surface diagrams stay legible.
  mermaid.initialize({ startOnLoad: false, theme: activeMermaidTheme() })
  await mermaid.run({ nodes })
  return nodes.length
}

// asciinema-player's stylesheet is loaded at most once per document. The import
// is a side-effect module a bundler (Vite/webpack/Next) injects as a `<style>`;
// a bundler that cannot handle a CSS import simply no-ops (players still work,
// unstyled) — cosmetics never fail hydration.
let stylesRequested = false
async function ensureAsciinemaStyles(): Promise<void> {
  if (stylesRequested) return
  stylesRequested = true
  try {
    await import('asciinema-player/dist/bundle/asciinema-player.css')
  } catch {
    /* CSS is cosmetic — swallow so a diagram-only bundler never breaks. */
  }
}

async function hydrateAsciicast(root: ParentNode): Promise<number> {
  const nodes = Array.from(
    root.querySelectorAll<HTMLElement>(ASCIICAST_SELECTOR),
  )
  if (nodes.length === 0) return 0

  const [player] = await Promise.all([
    import('asciinema-player') as Promise<unknown> as Promise<AsciinemaLike>,
    ensureAsciinemaStyles(),
  ])

  let mounted = 0
  for (const el of nodes) {
    const src = el.dataset.castSrc
    if (!src) continue
    // Same options the Phoenix `runAsciicast` mounts with. `poster` is the ONE
    // per-block option: the emitter writes `data-cast-poster` only when the
    // block names a resting frame (an npt timestamp, or `end`), so an unset
    // one falls back to `npt:0:1` and nothing changes for existing content. A
    // recording that opens on a banner + a reading pause is near-empty black at
    // t=1s; naming a later frame makes the resting state show real terminal.
    player.create(src, el, {
      fit: 'width',
      poster: el.dataset.castPoster || 'npt:0:1',
      idleTimeLimit: 2,
      theme: 'asciinema',
    })
    el.dataset.asciicastDone = 'true'
    mounted += 1
  }
  return mounted
}

// ── code-tabs (I1 hydration) ────────────────────────────────────────────────
// `syncKey` seam: a picked language persists to `localStorage` and is applied
// to every OTHER hydrated code-tabs container sharing the key — the "choose
// npm once, every code-tabs block follows" pitch. Matching is by `data-lang`
// (not index — two blocks can list languages in different orders), so a
// container missing the stored language just keeps its own first tab active.

/** Show the panel/tab whose `data-lang` matches; falls back to the first
 * panel's language when `lang` matches nothing in this container. */
function selectCodeTabsLang(container: HTMLElement, lang: string): void {
  const panels = Array.from(container.querySelectorAll<HTMLElement>('.bp-code-tabs__panel'))
  const buttons = Array.from(container.querySelectorAll<HTMLElement>('.bp-code-tabs__tab'))
  const target = panels.some((p) => p.dataset.lang === lang) ? lang : (panels[0]?.dataset.lang ?? '')

  for (const btn of buttons) {
    const active = btn.dataset.lang === target
    btn.setAttribute('aria-selected', String(active))
    btn.classList.toggle('bp-code-tabs__tab--active', active)
  }
  for (const panel of panels) {
    if (panel.dataset.lang === target) panel.removeAttribute('hidden')
    else panel.setAttribute('hidden', '')
  }
}

function codeTabsStorageKey(syncKey: string): string {
  return `bp-code-tabs:${syncKey}`
}

function readStoredLang(syncKey: string): string | null {
  try {
    return window.localStorage.getItem(codeTabsStorageKey(syncKey))
  } catch {
    return null // storage unavailable (private mode, SSR) — no persisted choice
  }
}

function writeStoredLang(syncKey: string, lang: string): void {
  try {
    window.localStorage.setItem(codeTabsStorageKey(syncKey), lang)
  } catch {
    /* storage unavailable — the choice just doesn't persist */
  }
}

function hydrateCodeTabs(root: ParentNode): number {
  const containers = Array.from(root.querySelectorAll<HTMLElement>(CODE_TABS_SELECTOR))
  if (containers.length === 0) return 0

  for (const container of containers) {
    const syncKey = container.dataset.syncKey ?? ''
    const firstPanel = container.querySelector<HTMLElement>('.bp-code-tabs__panel')
    const stored = syncKey === '' ? null : readStoredLang(syncKey)
    selectCodeTabsLang(container, stored ?? firstPanel?.dataset.lang ?? '')

    for (const btn of Array.from(container.querySelectorAll<HTMLElement>('.bp-code-tabs__tab'))) {
      btn.addEventListener('click', () => {
        const lang = btn.dataset.lang ?? ''
        selectCodeTabsLang(container, lang)
        if (syncKey === '') return

        writeStoredLang(syncKey, lang)
        for (const other of Array.from(
          document.querySelectorAll<HTMLElement>('.bp-code-tabs[data-hydrated="true"]'),
        )) {
          if (other !== container && other.dataset.syncKey === syncKey) selectCodeTabsLang(other, lang)
        }
      })
    }
    container.dataset.hydrated = 'true'
  }
  return containers.length
}

// ── tabs (I1 hydration) ─────────────────────────────────────────────────────
// Position-indexed (no cross-block sync — `tabs` has no `syncKey` in its
// data shape; each container's active panel is independent).

function selectTabIndex(container: HTMLElement, index: number): void {
  const panels = Array.from(container.querySelectorAll<HTMLElement>('.bp-tabs__panel'))
  const buttons = Array.from(container.querySelectorAll<HTMLElement>('.bp-tabs__tab'))
  if (panels.length === 0) return
  const clamped = Math.max(0, Math.min(index, panels.length - 1))

  buttons.forEach((btn, i) => {
    const active = i === clamped
    btn.setAttribute('aria-selected', String(active))
    btn.classList.toggle('bp-tabs__tab--active', active)
  })
  panels.forEach((panel, i) => {
    if (i === clamped) panel.removeAttribute('hidden')
    else panel.setAttribute('hidden', '')
  })
}

function hydrateTabs(root: ParentNode): number {
  const containers = Array.from(root.querySelectorAll<HTMLElement>(TABS_SELECTOR))
  if (containers.length === 0) return 0

  for (const container of containers) {
    selectTabIndex(container, 0)
    Array.from(container.querySelectorAll<HTMLElement>('.bp-tabs__tab')).forEach((btn, i) => {
      btn.addEventListener('click', () => selectTabIndex(container, i))
    })
    container.dataset.hydrated = 'true'
  }
  return containers.length
}

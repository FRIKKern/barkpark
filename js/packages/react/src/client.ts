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
  /**
   * Asciinema players that MOUNTED **and LOADED** their recording this call.
   *
   * Mounting is not loading: `player.create` returns before the `fetch()` of
   * `data-cast-src` resolves, so a blocked/404/CORS-refused recording used to
   * be counted here exactly like a working one. A caller reading this field
   * (`{asciicast: 1}`) was told a terminal recording is on the page when the
   * reader is looking at asciinema's bare 💥 box. This is now the TRUTHFUL
   * count: `asciicast + asciicastFailed === asciicastMounted`.
   */
  asciicast: number
  /** Mount points a player was attempted on this call — loaded or not. */
  asciicastMounted: number
  /**
   * Mount points whose recording could not be loaded and now carry the honest
   * fallback (message + link) instead of the player's emoji box.
   */
  asciicastFailed: number
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
  const [mermaid, casts] = await Promise.all([
    hydrateMermaid(root),
    hydrateAsciicast(root),
  ])
  const codeTabs = hydrateCodeTabs(root)
  const tabs = hydrateTabs(root)
  return {
    mermaid,
    asciicast: casts.loaded,
    asciicastMounted: casts.mounted,
    asciicastFailed: casts.failed,
    codeTabs,
    tabs,
  }
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

  const doc = ownerDocument(root)
  const mermaid = (await import('mermaid')).default as unknown as MermaidLike
  // Manual mode (`startOnLoad:false`): we drive rendering, mirroring the hook —
  // `mermaid.run` marks each processed node `data-processed="true"`. Theme
  // derives from the active mode so dark-surface diagrams stay legible.
  mermaid.initialize({ startOnLoad: false, theme: activeMermaidTheme(doc) })
  await mermaid.run({ nodes })
  // A diagram exists on this page now, so a LATER theme flip has something to
  // repaint. Installing the watch here (rather than in `hydratePortableDoc`)
  // keeps a diagram-free page at zero listeners.
  ensureMermaidThemeWatch(root)
  return nodes.length
}

/** Every diagram whose source we stashed — processed or not. */
const MERMAID_STASHED_SELECTOR = 'pre.mermaid[data-bp-src]'

/**
 * Repaint every stashed diagram under `root` at `theme`.
 *
 * Mermaid bakes its palette into the emitted SVG and exposes no restyle API, so
 * "re-theme" means "render again from source". That is exactly what
 * `data-bp-src` was stashed for at first hydration — the `<pre>`'s own
 * `textContent` is the SVG by then, not the diagram source.
 *
 * The `data-processed` stamp is cleared before the run and re-applied by
 * `mermaid.run` itself, so idempotency survives: a `hydratePortableDoc` call
 * that interleaves with a repaint still sees a correctly-stamped node.
 */
async function rerenderMermaid(
  root: ParentNode,
  theme: 'dark' | 'default',
): Promise<number> {
  const nodes = Array.from(
    root.querySelectorAll<HTMLElement>(MERMAID_STASHED_SELECTOR),
  )
  if (nodes.length === 0) return 0

  for (const n of nodes) {
    n.textContent = n.dataset.bpSrc ?? ''
    // `mermaid.run` SKIPS a node still marked processed — without this the
    // repaint is a silent no-op and the diagram keeps the stale palette.
    n.removeAttribute('data-processed')
  }

  const mermaid = (await import('mermaid')).default as unknown as MermaidLike
  mermaid.initialize({ startOnLoad: false, theme })
  await mermaid.run({ nodes })
  return nodes.length
}

/** `root`'s document — `root` may be the document itself, or an element in it. */
function ownerDocument(root: ParentNode): Document {
  const asDoc = root as Partial<Document>
  if (typeof asDoc.createElement === 'function') return root as Document
  return (root as Element).ownerDocument ?? document
}

// One watch per document. `hydrateMermaid` may run on every render/stream
// delta, and stacking an observer per call would repaint N times per flip.
const themeWatches = new WeakMap<Document, () => void>()

/**
 * Repaint this page's diagrams whenever the colour mode changes.
 *
 * Two sources, because `activeMermaidTheme` reads two:
 *   • a `MutationObserver` on `<html data-theme>` — the explicit consumer
 *     toggle (Studio / blog-starter);
 *   • the `prefers-color-scheme` media query — the OS-level flip that matters
 *     only while no explicit stamp is present.
 *
 * This package NEVER stamps `data-theme` itself: which element carries the
 * colour mode is the consuming app's contract, and we are strictly a reader.
 *
 * Repaints are guarded on the RESOLVED theme, not on the event: flipping
 * `data-theme` from `light` to `sepia`, or an OS flip underneath an explicit
 * stamp, both resolve to the same mermaid theme and repaint nothing.
 *
 * @param root  The subtree whose diagrams get repainted (defaults to `document`).
 * @returns     An unsubscribe function. Calling it twice is safe.
 */
export function watchMermaidTheme(root: ParentNode = document): () => void {
  const doc = ownerDocument(root)
  const win = doc.defaultView
  let applied = activeMermaidTheme(doc)

  const onChange = (): void => {
    const next = activeMermaidTheme(doc)
    if (next === applied) return
    applied = next
    void rerenderMermaid(root, next)
  }

  const observer =
    typeof win?.MutationObserver === 'function'
      ? new win.MutationObserver(onChange)
      : null
  if (observer && doc.documentElement) {
    observer.observe(doc.documentElement, {
      attributes: true,
      attributeFilter: ['data-theme'],
    })
  }

  const mq =
    typeof win?.matchMedia === 'function'
      ? win.matchMedia('(prefers-color-scheme: dark)')
      : null
  mq?.addEventListener?.('change', onChange)

  let stopped = false
  const stop = (): void => {
    if (stopped) return
    stopped = true
    observer?.disconnect()
    mq?.removeEventListener?.('change', onChange)
    if (themeWatches.get(doc) === stop) themeWatches.delete(doc)
  }
  return stop
}

function ensureMermaidThemeWatch(root: ParentNode): void {
  const doc = ownerDocument(root)
  if (themeWatches.has(doc)) return
  themeWatches.set(doc, watchMermaidTheme(doc))
}

/**
 * Tear down the theme watch `hydratePortableDoc` installed on `doc`. Rarely
 * needed in an app (the listeners die with the document) — it exists so a
 * long-lived test environment, or a consumer unmounting a whole surface, has a
 * way back to zero listeners.
 */
export function stopMermaidThemeWatch(doc: Document = document): void {
  const stop = themeWatches.get(doc)
  if (!stop) return
  themeWatches.delete(doc)
  stop()
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

/**
 * The asciinema-player theme for the ACTIVE color mode. Like mermaid, the player
 * bakes its palette into inline CSS custom properties on the mount point (it does
 * NOT read `.bp-paper-surface`'s tokens), so a fixed `theme:'asciinema'` paints a
 * near-black terminal on a light paper — the one embed on the page that ignores
 * the reader's mode.
 *
 * It DELEGATES to {@link activeMermaidTheme} rather than re-deriving: one
 * theme-derivation seam means the two lazy embeds on a page can never disagree
 * about which mode is active (a `data-theme` stamp read twice, by two slightly
 * different readers, is exactly how a diagram goes dark while a cast stays light).
 *
 * The names are asciinema-player 3.x BUILT-INS, not custom CSS: the shipped
 * stylesheet (node_modules/asciinema-player/dist/bundle/asciinema-player.css)
 * defines `.asciinema-player-theme-{asciinema,dracula,gruvbox-dark,monokai,nord,
 * seti,solarized-dark,solarized-light,tango}`, and `solarized-light`
 * (`--term-color-background: #fdf6e3`) is the ONLY one of the nine with a light
 * background — every other built-in backgrounds between #002b36 and #2e3440.
 *
 * Exported for tests; safe anywhere `document` exists.
 */
export function activeAsciicastTheme(
  doc: Document = document,
): 'asciinema' | 'solarized-light' {
  return activeMermaidTheme(doc) === 'dark' ? 'asciinema' : 'solarized-light'
}

/**
 * asciinema-player's OWN failure surface. On a recording it cannot fetch
 * (404, blocked by CSP/CORS, an air-gapped reader) the player paints
 * `div.ap-overlay-error` whose entire content is a 💥 glyph — a bordered box
 * with an emoji in it and nothing else, which is precisely the empty box the
 * komposisjon law forbids. asciinema-player 3.x exposes no `error` event
 * (`create()`'s handle carries play/pause/ended/input/marker only), so its own
 * DOM IS the error channel: this selector is the detector.
 */
const ASCIICAST_ERROR_SELECTOR = '.ap-overlay-error'
/**
 * Either marker means the player got its recording and painted: `.ap-terminal`
 * is the rendered screen, `.ap-overlay-start` the poster/play overlay a
 * `poster:` mount rests on. Seeing one ends the probe early — a loaded cast
 * never waits out the deadline.
 */
const ASCIICAST_READY_SELECTOR = '.ap-terminal, .ap-overlay-start'
/** Poll step and ceiling for the post-mount probe. */
const ASCIICAST_PROBE_STEP_MS = 25
const ASCIICAST_PROBE_TIMEOUT_MS = 4000

/** The honest fallback's copy (jf-backlog-asciicast-empty-box). */
const ASCIICAST_FALLBACK_MESSAGE = 'Opptaket kunne ikke lastes.'
const ASCIICAST_FALLBACK_LINK = 'Åpne opptaket direkte'

/** What one hydrate pass did to the `asciicast` mount points under `root`. */
interface AsciicastTally {
  /** Mount points a player was ATTEMPTED on — loaded or not. */
  mounted: number
  /** Players whose recording painted. */
  loaded: number
  /** Mount points swapped to the honest fallback. */
  failed: number
}

/**
 * Watch one mount point until its player either paints or faults.
 *
 * Resolves `'failed'` ONLY on asciinema's own error overlay — never on a
 * timeout. A player that shows neither marker inside the ceiling is left
 * alone and counted as loaded: replacing a slow-but-working player with a
 * "could not be loaded" card would be its own lie, and the honest-fallback law
 * is about the box the reader is actually staring at.
 */
async function probeCast(el: HTMLElement): Promise<'loaded' | 'failed'> {
  const deadline = Date.now() + ASCIICAST_PROBE_TIMEOUT_MS
  for (;;) {
    if (el.querySelector(ASCIICAST_ERROR_SELECTOR)) return 'failed'
    if (el.querySelector(ASCIICAST_READY_SELECTOR)) return 'loaded'
    if (Date.now() >= deadline) return 'loaded'
    await new Promise((r) => setTimeout(r, ASCIICAST_PROBE_STEP_MS))
  }
}

/**
 * `href` for the raw recording, or `null` when the mount's `data-cast-src` is
 * not a fetchable web URL. Deliberately NOT `inline.tsx`'s `safeUrl`: that one
 * returns an ATTRIBUTE-ESCAPED string for HTML interpolation (and would drag
 * the React emitter into this framework-free entry), while this fallback is
 * built with DOM APIs. Same allow-list shape though — http(s) or a same-origin
 * path, protocol-relative and every other scheme (`javascript:`, `data:`)
 * refused, so a hostile `data-cast-src` degrades to message-only.
 */
function castHref(src: string): string | null {
  const trimmed = src.replace(/^[\x00-\x20]+/, '')
  if (/^https?:\/\//i.test(trimmed)) return trimmed
  if (trimmed.startsWith('/') && !/^\/[/\\]/.test(trimmed)) return trimmed
  return null
}

/**
 * Replace a faulted player with the honest fallback.
 *
 * The CAPTION is untouched by construction: the emitters
 * (`figures.ex` / `blocks/core.ts`) put `<figcaption class="bp-figcaption">`
 * NEXT TO the mount point inside the `<figure>`, so emptying the mount div
 * cannot reach it — the test pins that, because a future markup change could.
 */
function renderCastFallback(el: HTMLElement, src: string): void {
  const doc = el.ownerDocument
  // Drops asciinema's 💥 overlay wholesale — the box the reader sees is ours.
  el.textContent = ''

  const box = doc.createElement('div')
  box.className = 'bp-asciicast__fallback'
  box.setAttribute(
    'style',
    'padding:0.9rem 1rem;color:var(--paper-ink-soft, #5b6b64);font-size:0.9em;line-height:1.5',
  )

  const message = doc.createElement('p')
  message.className = 'bp-asciicast__fallback-message'
  message.setAttribute('style', 'margin:0')
  message.textContent = ASCIICAST_FALLBACK_MESSAGE
  box.appendChild(message)

  const href = castHref(src)
  if (href !== null) {
    const link = doc.createElement('a')
    link.className = 'bp-asciicast__fallback-link'
    link.setAttribute('style', 'display:inline-block;margin-top:0.35rem')
    link.setAttribute('href', href)
    link.textContent = ASCIICAST_FALLBACK_LINK
    box.appendChild(link)
  }

  el.appendChild(box)
  // A second stamp beside `data-asciicast-done`: the mount stays skipped by the
  // idempotency guard, and a consumer (or a screenshot test) can select the
  // faulted casts on a page without parsing our copy.
  el.dataset.asciicastFailed = 'true'
}

async function hydrateAsciicast(root: ParentNode): Promise<AsciicastTally> {
  const nodes = Array.from(
    root.querySelectorAll<HTMLElement>(ASCIICAST_SELECTOR),
  )
  if (nodes.length === 0) return { mounted: 0, loaded: 0, failed: 0 }

  // Resolved ONCE per hydrate pass, not per node: every player on a page shares
  // the one active mode, and re-reading `data-theme` mid-loop could straddle a
  // flip and mount two casts in different palettes.
  const theme = activeAsciicastTheme(ownerDocument(root))

  const [player] = await Promise.all([
    import('asciinema-player') as Promise<unknown> as Promise<AsciinemaLike>,
    ensureAsciinemaStyles(),
  ])

  /** Mount points a player was created on, with the src the fallback links to. */
  const created: Array<{ el: HTMLElement; src: string }> = []
  let failed = 0
  for (const el of nodes) {
    const src = el.dataset.castSrc
    if (!src) continue
    // Stamped BEFORE the outcome is known: the guard is about re-entrancy (a
    // stream delta re-running hydration mid-probe), not about success.
    el.dataset.asciicastDone = 'true'
    try {
      // Same options the Phoenix `runAsciicast` mounts with. `poster` is the ONE
      // per-block option: the emitter writes `data-cast-poster` only when the
      // block names a resting frame (an npt timestamp, or `end`), so an unset
      // one falls back to `npt:0:1` and nothing changes for existing content. A
      // recording that opens on a banner + a reading pause is near-empty black at
      // t=1s; naming a later frame makes the resting state show real terminal.
      player.create(src, el, {
        fit: 'width',
        poster: el.dataset.castPoster || 'npt:0:1',
        rows: el.dataset.castRows ? Number(el.dataset.castRows) : undefined,
        idleTimeLimit: 2,
        theme,
      })
      created.push({ el, src })
    } catch {
      // A create() that throws never painted anything — straight to the card.
      renderCastFallback(el, src)
      failed += 1
    }
  }

  // Probed in PARALLEL: three casts on a page settle in the time of the
  // slowest, not the sum, and each resolves the moment its own DOM answers.
  const outcomes = await Promise.all(created.map(({ el }) => probeCast(el)))
  let loaded = 0
  outcomes.forEach((outcome, i) => {
    if (outcome === 'loaded') {
      loaded += 1
      return
    }
    const { el, src } = created[i]!
    renderCastFallback(el, src)
    failed += 1
  })

  // `mounted` counts every mount point a player was ATTEMPTED on (a create()
  // that threw included), so the identity `loaded + failed === mounted` holds
  // and a caller can never read a "loaded" count that quietly swallowed one.
  return { mounted: loaded + failed, loaded, failed }
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

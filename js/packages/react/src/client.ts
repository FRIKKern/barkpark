// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// @barkpark/react/client — framework-free MEDIA hydration for PortableDoc's
// static mount points (charter D5 / W4).
//
// `PortableDoc` (the canonical renderer) emits the two media blocks as INERT
// mount points, byte-exact to the Phoenix emitter (`figures.ex`):
//
//   diagram   → <pre class="mermaid">…source…</pre>
//   asciicast → <div class="bp-asciicast" data-cast-src="…"></div>
//
// Rendering the SVG / mounting the terminal player is a CONSUMING-APP concern —
// exactly as `bulldocs.html.heex` (not `compose.ex`) owns hydration in Phoenix.
// `hydratePortableDoc(root)` is that consumer-side hook, reshaped off the
// LiveView `PaperMermaid` hook's `runMermaid` / `runAsciicast`. It is:
//
//   • framework-free — no React, no hooks, plain DOM: call it from a Next
//     `useEffect`, an Astro `<script>`, or any place the mount points are live.
//   • lazy — `mermaid` and `asciinema-player` are `import()`-ed ONLY when a
//     matching mount point exists, so a media-free page pays nothing and neither
//     library lands in `dist/client.mjs` (both are `external` + dynamic).
//   • idempotent — `data-processed` (mermaid) / `data-asciicast-done` guard
//     re-runs, so it is safe to call on every render / stream delta.

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

/** Per-call tally of what actually hydrated — lets a caller/test assert work. */
export interface HydrateResult {
  /** Diagrams rendered into SVGs this call. */
  mermaid: number
  /** Asciinema players mounted this call. */
  asciicast: number
}

/**
 * Hydrate every un-processed PortableDoc media mount point under `root` into a
 * live diagram / player. Framework-free and idempotent — drop it in a Next
 * `useEffect(() => { hydratePortableDoc(ref.current) }, [])`, an Astro island
 * `<script>`, or call it after any DOM update that adds `diagram`/`asciicast`
 * blocks.
 *
 * @param root  The subtree to scan (defaults to `document`).
 * @returns     Counts of diagrams + players actually hydrated this call.
 */
export async function hydratePortableDoc(
  root: ParentNode = document,
): Promise<HydrateResult> {
  const [mermaid, asciicast] = await Promise.all([
    hydrateMermaid(root),
    hydrateAsciicast(root),
  ])
  return { mermaid, asciicast }
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
  // `mermaid.run` marks each processed node `data-processed="true"`.
  mermaid.initialize({ startOnLoad: false })
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
    // Same options the Phoenix `runAsciicast` mounts with.
    player.create(src, el, {
      fit: 'width',
      poster: 'npt:0:1',
      idleTimeLimit: 2,
      theme: 'asciinema',
    })
    el.dataset.asciicastDone = 'true'
    mounted += 1
  }
  return mounted
}

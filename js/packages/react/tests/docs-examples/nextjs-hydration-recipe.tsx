// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// PINNED DOCUMENTATION EXAMPLE — README.md's "Hydrating media & tabs" §
// Next.js recipe is a verbatim copy of this file's exported component.
// `tsc --noEmit` (the package's `typecheck` script, run in CI) type-checks
// this file against the package's REAL public exports on every change, so a
// renamed export, a widened `Block` type, or a `hydratePortableDoc` signature
// change breaks the build here BEFORE the README snippet goes silently stale.
// Not a vitest test (no `.test.` in the filename — vitest's default include
// glob skips it) — this file exists to be TYPE-CHECKED, not run.
//
// Mirrors the shipped reference: create-barkpark-app's blog-starter
// `app/posts/[slug]/portable-doc-surface.tsx`, which is the same shape,
// wired to a real scaffold and covered end-to-end by
// rpu-w6-blog-hydration-proof's Playwright mount.

'use client'

import { useEffect, useRef } from 'react'
import { renderPortableDocument, type Block } from '@barkpark/react'
import { hydratePortableDoc } from '@barkpark/react/client'

interface PortableDocSurfaceProps {
  /** The canonical, type-keyed PortableDocument block array (Barkpark grammar). */
  blocks: Block[]
  /** Extra class(es) appended to the `bp-paper-surface` root. */
  className?: string
}

/**
 * The ONE canonical PortableDoc surface for a Next.js App Router page.
 *
 * SERVER/CLIENT BOUNDARY: `renderPortableDocument(blocks)` is a pure string
 * emitter — it produces the exact HTML the Phoenix `/papers` reader and the Go
 * TUI render, with zero client JS for the static blocks. A Server Component
 * can call it directly. What CANNOT live in a Server Component is the DOM
 * `ref` hydration needs — refs are a client-only API — so this file is the
 * boundary: a `'use client'` island that owns exactly the ref and nothing
 * else. `<PortableDoc>` (the RSC-safe component export) intentionally has no
 * ref of its own for this reason; this wrapper re-implements its one-line
 * body (`renderPortableDocument` into a `.bp-paper-surface` div) so the ref
 * can attach.
 *
 * AVOIDING DOUBLE HYDRATION: `hydratePortableDoc` stamps `data-processed` /
 * `data-asciicast-done` / `data-hydrated` on every mount point it touches, so
 * calling it twice on the same DOM is a no-op the second time — safe under
 * React 19 Strict Mode's deliberate double-invoke of effects in dev, and safe
 * if a parent re-renders this component for an unrelated reason. The `[blocks]`
 * dependency re-runs hydration only when the content itself changes (e.g. a
 * draft-preview edit swaps in new blocks with fresh, un-hydrated mount points).
 *
 * ERROR BEHAVIOR: media hydration is a progressive enhancement over
 * server-rendered, readable content (a `<pre>` with the raw Mermaid source, a
 * `<div>` with a poster-frame data attribute) — a failed `import('mermaid')`
 * or a network hiccup loading `asciinema-player` must never surface as a
 * broken page. The `.catch(() => {})` is deliberate: the fallback IS the
 * pre-hydration markup, which already degrades to something legible.
 *
 * CLEANUP: no `useEffect` cleanup function is needed, and deliberately none
 * is written. Hydration is one-shot DOM mutation (swap a `<pre>` for an SVG,
 * mount a player, wire a click handler) — not a subscription, timer, or
 * listener registered against anything outside this DOM subtree — so there is
 * nothing to unregister on unmount. Removing the node removes everything
 * hydration attached to it. A rejected `hydratePortableDoc` promise racing an
 * unmount is already inert: `.catch(() => {})` discards the error and no
 * state update follows it, so there is no "set state after unmount" hazard
 * to guard against either.
 */
export function PortableDocSurface({ blocks, className }: PortableDocSurfaceProps) {
  const ref = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (ref.current) void hydratePortableDoc(ref.current).catch(() => {})
  }, [blocks])

  const cls = className ? `bp-paper-surface ${className}` : 'bp-paper-surface'
  return (
    <div
      ref={ref}
      className={cls}
      dangerouslySetInnerHTML={{ __html: renderPortableDocument(blocks) }}
    />
  )
}

// ── The server page that mounts it (type-checked shape only — no `next`
// dependency in this package, so this models the call site as a plain
// function rather than importing next's Metadata/page types) ──────────────
export interface ServerPageDeps {
  fetchBlocks(): Promise<Block[]>
}

/**
 * `app/posts/[slug]/page.tsx` (a Server Component — no `'use client'`): fetch
 * server-side, then hand the blocks to the client island above. Everything
 * except the island itself — data fetching, layout, `<head>` — stays server
 * work with zero extra client JS.
 */
export async function ExamplePostPage({ fetchBlocks }: ServerPageDeps) {
  const blocks = await fetchBlocks()
  return <PortableDocSurface blocks={blocks} />
}

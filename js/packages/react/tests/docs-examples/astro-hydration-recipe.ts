// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// PINNED DOCUMENTATION EXAMPLE — README.md's "Hydrating media & tabs" §
// Astro recipe is a verbatim copy of this file's exported function. `tsc
// --noEmit` (the package's `typecheck` script, run in CI) type-checks this
// file against the package's REAL public exports on every change, so drift
// against `hydratePortableDoc`'s actual signature breaks the build here
// before the README goes stale. Not a vitest test (no `.test.` in the
// filename) — this file exists to be type-checked, not run.
//
// No `astro` import: `@barkpark/react` takes no dependency on any framework
// (README: "Zero `next/*` imports — use from any React 19 host"), and this
// recipe needs none either — `renderPortableDocument` is a pure string
// emitter and `hydratePortableDoc` is plain DOM, so nothing here is
// React-specific. This is the SAME module Next's client island (see
// nextjs-hydration-recipe.tsx) imports from — one hydration codepath, two
// framework wrappers.

import { renderPortableDocument, type Block } from '@barkpark/react'
import { hydratePortableDoc } from '@barkpark/react/client'

/**
 * `src/pages/posts/[slug].astro` frontmatter (runs server-side, Astro's
 * default — no directive needed): produce the exact `.bp-paper-surface` HTML
 * server-side and inject it with `set:html`.
 *
 * ```astro
 * ---
 * import { renderSurfaceHtml } from '../../../lib/portable-doc-recipe'
 * const post = await getPost(Astro.params.slug)
 * const surfaceHtml = renderSurfaceHtml(post.content)
 * ---
 * <div id="post-surface" class="bp-paper-surface" set:html={surfaceHtml} />
 * <script>
 *   import { hydratePostSurface } from '../../../lib/portable-doc-recipe'
 *   hydratePostSurface()
 * </script>
 * ```
 *
 * SERVER/CLIENT BOUNDARY: everything up to and including `renderSurfaceHtml`
 * runs at build/request time in the `.astro` frontmatter — genuinely zero
 * client JS for the static blocks, no React runtime shipped at all. The
 * `<script>` block is Astro's own client boundary (bundled and deduped
 * per-page by Astro, not a component framework island) — it is the ONLY
 * client-side code this page ships, and it does exactly one thing: hydrate
 * media/tabs.
 */
export function renderSurfaceHtml(blocks: Block[]): string {
  return renderPortableDocument(blocks)
}

/**
 * The `<script>` body (a plain ES module, no Astro-specific API): find the
 * server-rendered surface and hydrate it.
 *
 * AVOIDING DOUBLE HYDRATION: same idempotency contract as the Next recipe —
 * `hydratePortableDoc` stamps every mount point it touches, so a second call
 * (Astro View Transitions re-running page scripts on `astro:page-load`, for
 * example) is a safe no-op. Query the surface by a stable id rather than
 * `document` to avoid re-scanning unrelated `.bp-paper-surface` nodes if more
 * than one is ever mounted on a page.
 *
 * ERROR BEHAVIOR: identical contract to the Next recipe — the pre-hydration
 * server markup (raw Mermaid source in a `<pre>`, a poster-frame data
 * attribute on the asciicast mount) is already valid, readable output, so a
 * failed dynamic import or network error is swallowed rather than surfaced.
 *
 * CLEANUP: none needed, for the same reason as the Next recipe — hydration
 * only mutates the DOM it is scanning; it registers no listener or timer
 * outside that subtree for a page-navigation to leak.
 */
export function hydratePostSurface(doc: Document = document): void {
  const root = doc.getElementById('post-surface')
  if (root) void hydratePortableDoc(root).catch(() => {})
}

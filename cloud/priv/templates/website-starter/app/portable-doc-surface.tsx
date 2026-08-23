'use client'

import { useEffect, useRef } from 'react'
import { renderPortableDocument, type Block } from '@barkpark/react'
import { hydratePortableDoc } from '@barkpark/react/client'

interface Props {
  /** The canonical, type-keyed PortableDocument block array (Barkpark grammar). */
  blocks: Block[]
  /** Extra class(es) appended to the `bp-paper-surface` root. */
  className?: string
}

/**
 * The one canonical PortableDocument surface for the site — shared by the
 * about, pricing, and post pages (every `richText` field renders through it).
 *
 * The body HTML is produced by `renderPortableDocument` — the same string
 * emitter that skins Phoenix's `/papers` reader and the Go TUI — so this runs
 * during SSR (a Server Component renders this island to HTML with zero client
 * work for the static blocks). It mounts inside `.bp-paper-surface`, whose
 * skin ships from `@barkpark/react/paper-surface.css` (imported once per
 * route, in each page that renders this surface).
 *
 * The only client work is MEDIA hydration: `hydratePortableDoc(ref.current)`
 * turns any inert mount points the renderer emits into live views —
 * `<pre class="mermaid">` → an SVG diagram, `<div class="bp-asciicast">` → a
 * terminal player. Images are static `<img>`; they need no hydration. The hook
 * is idempotent (it stamps `data-processed` / `data-asciicast-done`), so a
 * re-render is safe to call again.
 */
export function PortableDocSurface({ blocks, className }: Props) {
  const ref = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (ref.current) void hydratePortableDoc(ref.current)
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

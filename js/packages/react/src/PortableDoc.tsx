// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// PortableDoc — the canonical, type-keyed PortableDocument renderer.
//
// It renders Barkpark's OWN `type`-keyed block AST (heading / paragraph / list /
// table / callout / code / … plus the data-viz, forms, and chat families) — the
// same grammar the Phoenix reader and the Go TUI render — NOT Sanity-shaped
// PortableText (that stays the legacy `PortableText` shim, untouched). It emits
// the exact `bp-*` class vocabulary Phoenix's `Render.Walk` emits at
// `style=:article`, so ONE stylesheet (`paper-surface.css`) skins Next, Astro,
// and Phoenix identically (charter D1).
//
// The block tree is a pure STRING emitter (`./blocks/registry`), mirroring the
// Elixir/Go string renderers, then mounted into a single `.bp-paper-surface`
// container via `dangerouslySetInnerHTML` — the same escape-hatch model `walk.ex`
// uses for its `_raw` nodes. Every author string is escaped at the leaf
// (`escapeHtml`/`escapeAttr`/`safeUrl`), the same security posture as Phoenix.
//
// CONTEXT-FREE by design: no hooks, no `createContext`, no client-only APIs — so
// it ships from BOTH the client entry (`index.ts`) and the RSC-safe entry
// (`server.ts`) and drops into a Server Component untouched (charter D2/D3).

import type { Block } from './inline'
import { renderBlocks } from './blocks/registry'

export type { Block, Inline } from './inline'

export interface PortableDocProps {
  /** The type-keyed PortableDocument block array (Barkpark's block grammar). */
  value: Block[] | null | undefined
  /** Extra class(es) appended to the `bp-paper-surface` root. */
  className?: string
}

/**
 * Render a type-keyed PortableDocument block array to Phoenix-faithful HTML,
 * wrapped in the canonical `.bp-paper-surface` container. Drop this into a
 * Next/Astro surface where you want the same output the Phoenix `/papers` reader
 * produces. Ship `@barkpark/react/paper-surface.css` (or your own copy of
 * `api/assets/paper-surface/paper-surface.css`) to skin it.
 */
export function PortableDoc({ value, className }: PortableDocProps) {
  const blocks = Array.isArray(value) ? value : []
  const cls = className ? `bp-paper-surface ${className}` : 'bp-paper-surface'
  return <div className={cls} dangerouslySetInnerHTML={{ __html: renderBlocks(blocks) }} />
}

/**
 * The pure string form of {@link PortableDoc}'s inner HTML — the joined block
 * markup WITHOUT the `.bp-paper-surface` wrapper. Framework-free (no React), so
 * an Astro `set:html` / a non-React SSR surface can consume it directly, and the
 * cross-surface parity harness can compare it against the Elixir/Go golden.
 */
export function renderPortableDocument(value: Block[] | null | undefined): string {
  return renderBlocks(Array.isArray(value) ? value : [])
}

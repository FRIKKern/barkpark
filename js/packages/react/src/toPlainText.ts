// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import type { PortableTextBlock, PortableTextNode } from './PortableText'
import { type Block, str, isMap, asList } from './inline'

/**
 * Extracts the plain text from a PortableDocument value — the utility behind
 * excerpts, SEO meta descriptions, reading-time estimates, and search indexing.
 *
 * TWO input shapes are supported, decided per node so a mixed array is safe:
 *
 * 1. **Legacy Sanity Portable Text** (`_type: 'block'`, `children[].text`). Each
 *    such block contributes the concatenation of its spans' `text`; non-`block`
 *    Sanity nodes (images, embeds, …) contribute nothing. This path is UNCHANGED
 *    from the original implementation.
 * 2. **Barkpark's type-keyed AST** (`type: '<name>'`) — the block grammar the
 *    canonical `@barkpark/react` renderer walks. A type-keyed node contributes
 *    the readable body prose of its type (heading/paragraph/list/callout/table/
 *    figure/card/… — see {@link blockText}); data-viz, forms, chat, media and
 *    purely-structural types deliberately contribute nothing (they carry labels,
 *    numeric series or chrome, not reading-flow prose).
 *
 * Blocks are separated by a blank line (`\n\n`), the Portable Text ecosystem
 * convention; a block that contributes no text injects no stray separator.
 * Malformed input — a missing/non-array `children`, a non-string span `text`, a
 * nullish value — is skipped rather than throwing, the same fail-soft posture as
 * the renderer.
 *
 * Pure and dependency-free (it imports only the renderer's pure scalar-coercion
 * helpers), so it runs in a Server Component (e.g. Next.js `generateMetadata`) as
 * happily as on the client.
 *
 * @example
 * import { toPlainText } from '@barkpark/react'
 *
 * export function generateMetadata({ post }) {
 *   return { description: toPlainText(post.body).slice(0, 160) }
 * }
 */
export function toPlainText(
  value: PortableTextNode | PortableTextNode[] | Block | Block[] | null | undefined,
): string {
  if (value == null) return ''
  const nodes = Array.isArray(value) ? value : [value]
  const parts: string[] = []
  for (const node of nodes) {
    if (!node || typeof node !== 'object') continue
    const rec = node as Record<string, unknown>
    if (rec._type === 'block') {
      // ── legacy Sanity Portable Text path (UNCHANGED) ──────────────────────
      const block = node as PortableTextBlock
      if (!Array.isArray(block.children)) continue
      let text = ''
      for (const child of block.children) {
        if (child && typeof child.text === 'string') text += child.text
      }
      parts.push(text)
    } else if (typeof rec.type === 'string') {
      // ── type-keyed PortableDocument path (additive) ───────────────────────
      // Skip a block that contributes no prose so it never injects a stray
      // separator into an otherwise-clean excerpt.
      const text = blockText(rec as Block)
      if (text !== '') parts.push(text)
    }
    // Any other node (a non-block Sanity node, an untyped map) contributes
    // nothing — no push, no separator.
  }
  return parts.join('\n\n')
}

/* ──────────────────────────────────────────────────────────────────────────────
 * Type-keyed extraction
 *
 * `blockText` is a type-keyed dispatch over Barkpark's block grammar. Every
 * PROSE-bearing type has its own clause returning that type's readable body
 * text; every intentionally-textless type falls through to the `default` and
 * returns `''`. The pd-golden per-type test (`toPlainText.typekeyed.test.ts`)
 * pins each type's output against a JS-owned golden map AND enforces an explicit
 * textless SKIP allow-list — so a type silently dropping to `''` that is not on
 * the list fails (silent-drop ≠ intentional-skip), and reverting any prose clause
 * flips its golden to `''` (anti-vacuous-green).
 *
 * Reading order and joining mirror the canonical renderer (blocks/*.ts): inline
 * runs concatenate with no separator; block-level pieces (a callout title + body,
 * a figure child + caption, card slots, section/column children) join with a
 * blank line, exactly as the top-level walker does.
 * ────────────────────────────────────────────────────────────────────────────── */

/** Join block-level fragments with a blank line, dropping empties (no stray gap). */
function joinBlocks(parts: string[]): string {
  return parts.filter((s) => s !== '').join('\n\n')
}

/** Concatenate an inline content run's readable text — the `{type:'text',value}`
 * nodes paragraph/list/table cells carry, recursing through mark wrappers. Marks
 * are style metadata and contribute no text (twin of the renderer dropping them
 * to plain text). Fail-soft on non-arrays. */
function inlineText(nodes: unknown): string {
  if (typeof nodes === 'string') return nodes
  if (typeof nodes === 'number') return String(nodes)
  if (!Array.isArray(nodes)) return ''
  let out = ''
  for (const n of nodes) {
    if (typeof n === 'string') {
      out += n
      continue
    }
    if (typeof n === 'number') {
      out += String(n)
      continue
    }
    if (!isMap(n)) continue
    if (typeof n.value === 'string') out += n.value
    else if (typeof n.text === 'string') out += n.text
    if (Array.isArray(n.children)) out += inlineText(n.children)
  }
  return out
}

/** Prose block body: the `content` inline run, or the legacy flat `text`
 * fallback (mirrors the renderer's `paragraphInline`). */
function proseContent(b: Block): string {
  if (Array.isArray(b.content) && b.content.length) return inlineText(b.content)
  return str(b.text)
}

/** A table/list cell: an inline run, a nested block, or a bare scalar. */
function cellText(cell: unknown): string {
  if (Array.isArray(cell)) return inlineText(cell)
  if (isMap(cell) && typeof cell.type === 'string') return blockText(cell as Block)
  return str(cell)
}

/** Recurse a slot / column / section child list to its joined prose. */
function childrenText(list: unknown): string {
  return joinBlocks(
    asList(list).map((x) => (isMap(x) && typeof x.type === 'string' ? blockText(x as Block) : '')),
  )
}

/** One note/notes row: `label`, then the bold run-in `lead` + `text` body —
 * mirroring the renderer's `noteItemHtml` reading order. */
function noteText(m: unknown): string {
  const rec = isMap(m) ? m : {}
  const body = [str(rec.lead).trim(), str(rec.text)].filter((s) => s !== '').join(' ')
  return [str(rec.label), body].filter((s) => s !== '').join(' ')
}

function listText(b: Block): string {
  return asList(b.items)
    .map((it) => cellText(it))
    .filter((s) => s !== '')
    .join('\n')
}

function tableText(b: Block): string {
  const headRaw = b.head ?? b.header
  const head = Array.isArray(headRaw) ? headRaw : []
  const lines: string[] = []
  const headLine = head
    .map((c) => cellText(c))
    .filter((s) => s !== '')
    .join(' ')
  if (headLine !== '') lines.push(headLine)
  for (const row of asList(b.rows)) {
    const rowLine = asList(row)
      .map((c) => cellText(c))
      .filter((s) => s !== '')
      .join(' ')
    if (rowLine !== '') lines.push(rowLine)
  }
  return lines.join('\n')
}

function cardsText(b: Block): string {
  return joinBlocks(
    asList(b.items).map((it) => {
      const m = isMap(it) ? it : {}
      return joinBlocks([str(m.title), str(m.text)])
    }),
  )
}

function cardText(b: Block): string {
  // Renderer slot order: media, title, body, action. media (images) + action
  // (CTA controls) contribute no prose, so effectively title + body.
  return joinBlocks(
    ['media', 'title', 'body', 'action'].map((slot) =>
      childrenText(isMap(b.slots) ? b.slots[slot] : undefined),
    ),
  )
}

/** Extract the readable body prose of one type-keyed block. Intentionally-textless
 * types (data-viz / forms / chat / media / structural) fall to `default → ''`. */
function blockText(b: Block): string {
  switch (b.type) {
    // ── headings / roles ──────────────────────────────────────────────────
    case 'heading':
    case 'eyebrow':
      return str(b.text)
    case 'byline':
      return Array.isArray(b.items) ? b.items.map((i) => str(i)).join(' · ') : str(b.text)
    // ── prose runs ────────────────────────────────────────────────────────
    case 'paragraph':
    case 'ingress':
    case 'pullquote':
      return proseContent(b)
    case 'list':
      return listText(b)
    case 'callout':
      return joinBlocks([str(b.title), proseContent(b)])
    case 'code':
      return str(b.value)
    // ── code-story blocks (starter parity: the `text` attr the scaffold wraps;
    //    grow slices refine to the diff body / tree lines) ───────────────────
    case 'diff':
    case 'filetree':
      return str(b.text)
    // ── annotation rows ───────────────────────────────────────────────────
    case 'note':
      return noteText(b)
    case 'notes':
      return joinBlocks(asList(b.items).map((it) => noteText(it)))
    // ── tables ────────────────────────────────────────────────────────────
    case 'table':
      return tableText(b)
    // ── containers (recurse) ──────────────────────────────────────────────
    case 'figure':
      return joinBlocks([isMap(b.child) ? blockText(b.child as Block) : '', str(b.caption)])
    case 'card':
      return cardText(b)
    case 'cards':
      return cardsText(b)
    case 'columns':
      return joinBlocks(asList(b.columns).map((col) => childrenText(col)))
    case 'section':
      return childrenText(b.blocks)
    case 'terminal':
      return childrenText(b.children ?? b.blocks)
    // ── data-viz / forms / chat / media / structural → textless ───────────
    default:
      return ''
  }
}

// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// The block dispatcher — one entry per registered type, assembled from the
// per-family emitter maps. `renderBlock` is the JS twin of compose_block/2 +
// walk at style=:article: it routes a type-keyed block to its emitter, degrading
// an unknown/malformed block to the same visible `bp-unknown-block` placeholder
// the Elixir renderer emits (never throwing). Container blocks (section, columns,
// terminal, card, figure) recurse back through here.

import { type Block, escapeHtml, str, isMap } from '../inline'
import { coreEmitters } from './core'
import { datavizEmitters } from './dataviz'
import { formsEmitters } from './forms'
import { chatEmitters } from './chat'
import { tableEmitters } from './table'
import { sheetEmitters } from './sheet'
import { taskboardEmitters } from './taskboard'
import { mathEmitters } from './math'

type Emit = (block: Block) => string

const DISPATCH: Record<string, Emit> = {
  ...coreEmitters,
  ...datavizEmitters,
  ...formsEmitters,
  ...chatEmitters,
  ...tableEmitters,
  ...sheetEmitters,
  ...taskboardEmitters,
  ...mathEmitters,
}

/** The full set of registered block types this renderer handles — every key in
 * the emitter maps above, including canonical types AND authoring-drift aliases
 * (bulletList / bullet_list / bulleted-list / bulleted_list / numbered_list /
 * quote / h1 / h2 / h3 / ordered-list). Do NOT trust a hand-counted literal
 * here — `Object.keys(DISPATCH)` IS the count (the PortableDoc suite pins the
 * exact number and asserts CASES ≡ this set). Used by the self-proof harness. */
export const REGISTERED_TYPES: string[] = Object.keys(DISPATCH)

/** Render one type-keyed block to an HTML string (article surface). */
export function renderBlock(block: Block): string {
  if (!isMap(block)) return `<div class="bp-unknown-block">invalid block</div>`
  const type = str(block.type)
  const emit = DISPATCH[type]
  if (emit) return emit(block)
  // Unknown/unregistered type → degrade, never throw (compose.ex unknown_block_node/1).
  return `<div class="bp-unknown-block">Unsupported block: ${escapeHtml(type)}</div>`
}

/** Render a block array to a joined HTML string. */
export function renderBlocks(blocks: unknown): string {
  if (!Array.isArray(blocks)) return ''
  return blocks.map((b) => renderBlock(b as Block)).join('')
}

// The block dispatcher — the RN sibling of js/packages/react/src/blocks/
// registry.ts (charter D49): BLOCK_RENDERERS assembled from the per-family
// spreads in ./blocks/, plus the unknown-block degrade and the ONE dispatch
// entry point. Coverage is corpus-driven — a 100-paper census of live
// production (2026-07-25) puts the registered types at >99% of all blocks;
// everything else renders the honest labeled fallback (never a crash, never a
// silent hole, logged once per type).
//
// Metro TDZ law (D49): family modules import `renderBlockNative` ONLY — it is
// a HOISTED function declaration (react's core.ts:24 precedent), so it exists
// before this module's body runs. BLOCK_RENDERERS is a const assembled from
// spreads and is undefined while the family modules evaluate — a family module
// that touched it would crash at bundle eval.
import type { ReactNode } from 'react'
import { Text, View } from 'react-native'

import { scale } from '../../ui/typography'
import { coreCodeRenderers } from './blocks/core-code'
import { coreContainerRenderers } from './blocks/core-container'
import { coreDocRenderers } from './blocks/core-doc'
import { coreMediaRenderers } from './blocks/core-media'
import { coreProseRenderers } from './blocks/core-prose'
import { datavizRenderers } from './blocks/dataviz'
import { formsRenderers } from './blocks/forms'
import { mathRenderers } from './blocks/math'
import { sheetRenderers } from './blocks/sheet'
import { tableRenderers } from './blocks/table'
import { taskboardRenderers } from './blocks/taskboard'
import { CHAT_RENDERERS } from './chat'
import { isMap, str, type Block } from './model'
import type { BlockCtx, Render } from './register'

/* ── unknown-block degrade — honest, labeled, logged ONCE per type ──────────── */

const warnedTypes = new Set<string>()

/** Test seam: reset the once-per-type unknown-block log. */
export function resetUnknownBlockLog(): void {
  warnedTypes.clear()
}

function unknownBlock(type: string, ctx: BlockCtx, key: number): ReactNode {
  const label = type === '' ? 'untyped block' : type
  if (!warnedTypes.has(label)) {
    warnedTypes.add(label)
    console.warn(`[barkpark-mobile] paper renderer: unsupported block type "${label}" — rendering labeled fallback`)
  }
  return (
    <View
      key={key}
      style={{
        borderWidth: 1,
        borderStyle: 'dashed',
        borderColor: ctx.theme.border,
        borderRadius: 6,
        padding: 10,
        marginVertical: 6,
      }}
    >
      <Text style={{ ...scale.xs, color: ctx.theme.textMuted, fontStyle: 'italic' }}>
        Unsupported block: {label}
      </Text>
    </View>
  )
}

/* ── the dispatcher ─────────────────────────────────────────────────────────── */

export const BLOCK_RENDERERS: Record<string, Render> = {
  ...coreProseRenderers,
  ...coreMediaRenderers,
  ...coreContainerRenderers,
  ...coreDocRenderers,
  ...coreCodeRenderers,
  ...datavizRenderers,
  ...formsRenderers,
  ...mathRenderers,
  ...sheetRenderers,
  ...tableRenderers,
  ...taskboardRenderers,
  // The six typed chat-* rows (charter D25/D35). Spread rather than dispatched
  // separately so they inherit ONE dispatcher: the unknown-block degrade, the
  // per-type render guard, and the registry tripwire all cover them for free —
  // an unregistered chat-x still hits unknownBlock like any other stray type.
  ...CHAT_RENDERERS,
}

/** Render one type-keyed block to a ReactNode. Unknown/malformed blocks
 * degrade to the labeled fallback — never a throw, never a silent hole
 * (registry.ts renderBlock twin). */
export function renderBlockNative(block: unknown, ctx: BlockCtx, key: number): ReactNode {
  if (!isMap(block)) return unknownBlock('invalid block', ctx, key)
  const type = str(block.type)
  const render = BLOCK_RENDERERS[type]
  if (render) {
    try {
      return render(block as Block, ctx, key)
    } catch (err) {
      // A malformed instance of a known type must not take the reader down.
      console.warn(`[barkpark-mobile] paper renderer: "${type}" block failed to render:`, String(err))
      return unknownBlock(type, ctx, key)
    }
  }
  return unknownBlock(type, ctx, key)
}

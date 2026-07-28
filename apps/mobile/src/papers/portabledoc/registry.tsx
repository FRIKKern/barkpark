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

/* ── the degrade-only set (charter D47) ─────────────────────────────────────── */

/** A renderer carrying the degrade-card marker. The property name is written
 * out LITERALLY inside the two functions below rather than hoisted into a
 * module const, because of the same Metro TDZ law as `renderBlockNative`: a
 * family module calls `degradeCard()` while ITS OWN module body evaluates,
 * which is before this module's body has run. A `function` declaration exists
 * at that moment; a `const` does not. */
interface DegradeMarked {
  readonly __bpDegradeCard?: true
}

/** Mark a renderer as a DEGRADE CARD — a labeled box that states its ceiling
 * instead of playing the content (video, asciicast; core-media.tsx carries the
 * doctrine). The mark is what `DEGRADE_ONLY` is derived FROM, so wrapping a new
 * card here is the whole registration: nothing else needs editing, and nothing
 * else can go stale. Read the DEGRADE_ONLY comment before adding a third — a
 * degrade card counts as UNrenderable at turn level, which is a deliberate
 * subtraction and not an oversight. */
export function degradeCard<R extends Render>(render: R): R {
  Object.defineProperty(render, '__bpDegradeCard', { value: true })
  return render
}

/** Does this renderer carry the degrade-card marker? */
export function isDegradeCard(render: Render | undefined): boolean {
  return (render as (Render & DegradeMarked) | undefined)?.__bpDegradeCard === true
}

/** The registered types whose renderer is a DEGRADE CARD rather than a render:
 * a labeled box that states its ceiling (`video`, `asciicast` — D46d). They ARE
 * in BLOCK_RENDERERS, so a block of one still draws its card wherever the
 * document path is taken — that part is right and stays.
 *
 * WHAT THIS SET EXISTS TO PREVENT. `anyRenderableBlocks` (ChatSessionScreen)
 * asks one question per TURN — is there a single block worth entering the
 * document path for? — and it derives the answer from THIS registry. So the act
 * of registering a card silently changes an unrelated decision: a chat turn made
 * of nothing but video/asciicast blocks answers "no" today and renders the full
 * `source_markdown` the answer arrived with; the moment those types have
 * renderers it answers "yes" and paints two summary cards INSTEAD of that
 * markdown. A card is strictly less than the prose it would replace, so shipping
 * the renderers without this subtraction would have DELETED information from
 * turns that render fine now — the one regression in this whole family that no
 * per-block test could see.
 *
 * Subtracting the set at TURN level and nowhere else keeps both halves: a
 * degrade-only turn stays on the text path, and a MIXED turn takes the document
 * path and draws the card next to the prose. Gating the dispatch instead would
 * have been the worse fix — the mixed turn would lose its card to an
 * "Unsupported block" box, which is a lie about a type we support.
 *
 * DERIVED, not hand-kept. A two-literal Set said nothing about the renderers it
 * claimed to describe: a THIRD degrade card could be written and registered
 * without touching this line, and the turn-level subtraction would silently
 * stop covering it — the exact information-loss regression this set exists to
 * prevent, reintroduced by omission. The marker rides the renderer itself, so
 * the set cannot be out of date with the register. */
export const DEGRADE_ONLY: ReadonlySet<string> = new Set(
  Object.entries(BLOCK_RENDERERS)
    .filter(([, render]) => isDegradeCard(render))
    .map(([type]) => type),
)

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

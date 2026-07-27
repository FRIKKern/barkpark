// Live-corpus drift guard for the h1/h2/h3 + ordered-list alias family
// (charter D57). These four spellings are registered in NO renderer on ANY
// surface before this slice, so 20 blocks in live production papers unknown-box
// on web, TUI and mobile simultaneously — the same bug class as the bulletList
// family that was fixed for 77 blocks.
//
// The inputs below are the REAL live blocks, copied byte-for-byte out of the
// production corpus (`ctx-compression-wave-2026-07-24` and
// `task-quality-standard-chrono-wave-1-2026-07-18`, censused 2026-07-27 across
// all 553 published papers). Synthetic inputs would have missed the load-bearing
// detail: SIX of the 18 drifted headings (1 h2 + all 5 h3s) carry NO `level`
// field, so a naive `h3: heading` alias renders them at headingLevel's default
// of 2. The TYPE is the level authority — that is what these tests pin.
import type { ReactElement, ReactNode } from 'react'

import { renderBlockNative, type BlockCtx } from '../src/papers/portabledoc/blocks'
import { spec } from '../src/papers/portabledoc/register'
import { light, type Theme } from '../src/ui/theme'

// The webview TurboModule trap: MermaidIsland reaches react-native-webview
// through the registry barrel, which jest cannot resolve natively.
jest.mock('react-native-webview', () => ({ WebView: () => null }))

const theme: Theme = light
const paper: BlockCtx = { theme }
const chat: BlockCtx = { theme, register: 'chat' }

/* ── element walking (the house-local pattern; 8 sibling precedents) ─────────── */

interface Walk {
  text: string
  styles: Record<string, unknown>[]
}

function isElement(node: unknown): node is ReactElement {
  return !!node && typeof node === 'object' && 'props' in (node as object) && '$$typeof' in (node as object)
}

function walkNode(node: ReactNode, acc: Walk): void {
  if (node === null || node === undefined || typeof node === 'boolean') return
  if (typeof node === 'string' || typeof node === 'number') {
    acc.text += String(node)
    return
  }
  if (Array.isArray(node)) {
    for (const child of node) walkNode(child as ReactNode, acc)
    return
  }
  if (isElement(node)) {
    const props = node.props as Record<string, unknown>
    const raw = props.style
    if (raw !== undefined) {
      const parts = Array.isArray(raw) ? raw : [raw]
      acc.styles.push(Object.assign({}, ...parts.filter((p) => !!p)) as Record<string, unknown>)
    }
    walkNode(props.children as ReactNode, acc)
  }
}

function walk(node: ReactNode): Walk {
  const acc: Walk = { text: '', styles: [] }
  walkNode(node, acc)
  return acc
}

/* ── the real live blocks ───────────────────────────────────────────────────── */

const LIVE_H1 = {
  id: 'w1-002',
  level: 1,
  text: 'The manifest goes brief — killing the 95.7 KB session-start tax',
  type: 'h1',
} as const

const LIVE_H2_WITH_LEVEL = { id: 'w1-010', level: 2, text: 'The wish (verbatim)', type: 'h2' } as const

// No `level` key — the shape a naive alias renders at the wrong size.
const LIVE_H2_NO_LEVEL = {
  id: 'w1-d00',
  text: 'DEBRIEF — wave closed (Review, 2026-07-24)',
  type: 'h2',
} as const

const LIVE_H3_NO_LEVEL = { id: 'w1-d02', text: 'Shipped', type: 'h3' } as const

// The map-shaped items (`{content:[…]}`) are the corpus's dominant list-item
// shape — itemInlines already normalizes them; this pins that the ORDERED
// marker arrives, which is the part `ordered-list` was losing.
const LIVE_ORDERED_LIST = {
  id: 'queue',
  items: [
    { content: [{ type: 'text', value: 'Count a criterion as met only when met=true and evidence is non-empty.' }] },
    { content: [{ type: 'text', value: 'Sort by effective unmet criteria ascending.' }] },
    { content: [{ type: 'text', value: 'Add 100 for foreign-held claims; never steal them.' }] },
  ],
  type: 'ordered-list',
} as const

const LIVE_BLOCKS = [
  LIVE_H1,
  LIVE_H2_WITH_LEVEL,
  LIVE_H2_NO_LEVEL,
  LIVE_H3_NO_LEVEL,
  LIVE_ORDERED_LIST,
] as const

function render(block: unknown, ctx: BlockCtx = paper) {
  return walk(renderBlockNative(block, ctx, 0))
}

describe('h1/h2/h3 + ordered-list live drift (charter D57)', () => {
  it('every drifted live block renders WITHOUT the unknown-block fallback', () => {
    for (const ctx of [paper, chat]) {
      for (const block of LIVE_BLOCKS) {
        const out = render(block, ctx)
        expect(`${block.type}: ${out.text}`).not.toContain('Unsupported block')
        expect(out.text.length).toBeGreaterThan(0)
      }
    }
  })

  it('the heading aliases take their level from the TYPE, not from `level`', () => {
    // spec(paper).heading[n].step is the only level-distinguishing paint on a
    // mobile heading, so it is what proves an h3 is not silently a level 2.
    const fontSizeOf = (block: unknown): unknown => {
      const { styles } = render(block)
      const withSize = styles.find((s) => s.fontSize !== undefined)
      return withSize?.fontSize
    }
    const sizeAtLevel = (level: 1 | 2 | 3): unknown => spec(paper).heading[level].step.fontSize

    expect(fontSizeOf(LIVE_H1)).toBe(sizeAtLevel(1))
    expect(fontSizeOf(LIVE_H2_WITH_LEVEL)).toBe(sizeAtLevel(2))
    // The two level-less blocks are the whole point of the type-authority law.
    expect(fontSizeOf(LIVE_H2_NO_LEVEL)).toBe(sizeAtLevel(2))
    expect(fontSizeOf(LIVE_H3_NO_LEVEL)).toBe(sizeAtLevel(3))

    // Mutation proof that the assertion above can FAIL: strip the type alias's
    // level authority by feeding the same body through the canonical `heading`
    // with no level, and the h3 size must NOT survive.
    expect(fontSizeOf({ type: 'heading', text: 'Shipped' })).not.toBe(sizeAtLevel(3))
  })

  it('a contradicting `level` loses to the type (h3 with level:1 is still level 3)', () => {
    const { styles } = render({ type: 'h3', level: 1, text: 'contradiction' })
    const size = styles.find((s) => s.fontSize !== undefined)?.fontSize
    expect(size).toBe(spec(paper).heading[3].step.fontSize)
  })

  it('ordered-list numbers its items; the unordered `list` still bullets', () => {
    expect(render(LIVE_ORDERED_LIST).text).toContain('1.')
    expect(render(LIVE_ORDERED_LIST).text).toContain('2.')
    expect(render(LIVE_ORDERED_LIST).text).not.toContain('•')
    // The map-shaped item bodies survive too — `itemInlines` already normalizes
    // `{content:[…]}` here, which is why mobile shows the text the Elixir and Go
    // surfaces still drop (charter D38, task-993d136b0fbf2fd1).
    expect(render(LIVE_ORDERED_LIST).text).toContain('Count a criterion as met')
    expect(render(LIVE_ORDERED_LIST).text).toContain('never steal them')
    // The canonical sibling is untouched — this alias adds ordering, it does not
    // make every list ordered.
    expect(render({ type: 'list', items: ['a'] }).text).toContain('•')
  })

  it('the drifted heading text survives verbatim (content||text law)', () => {
    expect(render(LIVE_H1).text).toContain('killing the 95.7 KB session-start tax')
    expect(render(LIVE_H3_NO_LEVEL).text).toContain('Shipped')
    // The `content[]` shape routes through the same law.
    expect(render({ type: 'h2', content: [{ type: 'text', value: 'inline shape' }] }).text).toContain(
      'inline shape',
    )
  })
})

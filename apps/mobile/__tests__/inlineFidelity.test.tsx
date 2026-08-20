// Inline fidelity catch-up (charter D52, task mob-zb-s2-inline-fidelity).
//
// Two shapes the live corpus persists that the RN inline renderer dropped
// while its react and Elixir twins already carried them:
//
//   1. a BARE ARRAY where an inline node was expected (`content: [[{text…}]]`,
//      flattened one level too shallow by an upstream author path) — react
//      wraps it in a span and recurses (inline.tsx:407), Elixir composes it
//      into a PdText (inline.ex:186); RN returned null and the text VANISHED.
//   2. inline `code` authored with `children` inline nodes rather than a flat
//      `value` — react's law is `str(node.value) || inlineText(children)`
//      (inline.tsx:435): inline code is a TEXT leaf, so children fold to
//      concatenated PLAIN text, never nested markup.
//
// The suite walks the element trees the PURE inline/block renderers return —
// no native host — the same technique as paperRenderer.test.tsx.
import type { ReactElement, ReactNode } from 'react'

import { renderBlockNative, type BlockCtx } from '../src/papers/portabledoc/blocks'
import {
  inlineCodeStyle,
  renderInlineNode,
  renderInlineNodes,
  type InlineCtx,
} from '../src/papers/portabledoc/inlines'
import type { Inline } from '../src/papers/portabledoc/model'
import { light, type Theme } from '../src/ui/theme'

// react-native-webview is a native TurboModule with no jest mock of its own;
// nothing here renders the island. jest hoists this above the imports.
jest.mock('react-native-webview', () => ({ WebView: () => null }))

const theme: Theme = light
const blockCtx: BlockCtx = { theme }
const ctx: InlineCtx = { theme }

/* ── element-tree walker ────────────────────────────────────────────────────── */

interface Walk {
  /** every string leaf, concatenated in tree order */
  text: string
  /** flattened style objects seen on elements, in tree order */
  styles: Record<string, unknown>[]
  /** count of elements of any kind */
  elements: number
}

function isElement(node: unknown): node is ReactElement {
  return !!node && typeof node === 'object' && 'props' in (node as object) && '$$typeof' in (node as object)
}

function walkNode(node: ReactNode, acc: Walk): void {
  if (node === null || node === undefined || typeof node === 'boolean') return
  if (typeof node === 'string') {
    acc.text += node
    return
  }
  if (typeof node === 'number') {
    acc.text += String(node)
    return
  }
  if (Array.isArray(node)) {
    for (const child of node) walkNode(child as ReactNode, acc)
    return
  }
  if (isElement(node)) {
    acc.elements += 1
    const props = node.props as Record<string, unknown>
    const style = props.style
    if (style && typeof style === 'object' && !Array.isArray(style)) {
      acc.styles.push(style as Record<string, unknown>)
    }
    walkNode(props.children as ReactNode, acc)
  }
}

function walk(node: ReactNode): Walk {
  const acc: Walk = { text: '', styles: [], elements: 0 }
  walkNode(node, acc)
  return acc
}

const inline = (node: unknown): Walk => walk(renderInlineNode(node as Inline, ctx, 0))
const inlines = (nodes: unknown): Walk => walk(renderInlineNodes(nodes, ctx))
const block = (b: unknown): Walk => walk(renderBlockNative(b, blockCtx, 0))

/* ── defect 1: bare-array inline nodes (react inline.tsx:407, inline.ex:186) ── */

describe('bare-array inline node', () => {
  it('renders its children instead of vanishing', () => {
    const w = inline([{ type: 'text', value: 'shallow' }])
    expect(w.text).toBe('shallow')
  })

  it('paints inside a paragraph authored as content: [[{text…}]]', () => {
    const w = block({
      type: 'paragraph',
      content: [[{ type: 'text', value: 'one level too shallow' }]],
    })
    expect(w.text).toContain('one level too shallow')
  })

  it('keeps marks and siblings inside the bare array', () => {
    const w = inlines([
      'before ',
      [
        { type: 'text', value: 'bold', marks: [{ type: 'bold' }] },
        { type: 'text', value: ' plain' },
      ],
      ' after',
    ])
    expect(w.text).toBe('before bold plain after')
    expect(w.styles).toContainEqual({ fontWeight: 'bold' })
  })

  it('recurses through a doubly-nested bare array', () => {
    expect(inline([[{ type: 'text', value: 'deep' }]]).text).toBe('deep')
  })

  it('renders an empty bare array as no text, without crashing', () => {
    expect(inline([]).text).toBe('')
  })
})

/* ── defect 2: inline code children fallback (react inline.tsx:435) ─────────── */

describe('inline code', () => {
  it('falls back to the concatenated children text when value is absent', () => {
    const w = inline({ type: 'code', children: [{ type: 'text', value: 'npm run dev' }] })
    expect(w.text).toBe('npm run dev')
    expect(w.styles).toContainEqual(inlineCodeStyle(ctx))
  })

  it('concatenates several children with no separator and no nested markup', () => {
    const w = inline({
      type: 'code',
      children: [
        { type: 'text', value: 'bp ' },
        { type: 'text', value: 'task', marks: [{ type: 'bold' }] },
        ' show',
      ],
    })
    expect(w.text).toBe('bp task show')
    // TEXT leaf law: the mark on a child must NOT produce a bold run.
    expect(w.styles).not.toContainEqual({ fontWeight: 'bold' })
  })

  it('folds children-of-children to their text', () => {
    const w = inline({
      type: 'code',
      children: [{ type: 'strong', children: [{ type: 'text', value: 'nested' }] }],
    })
    expect(w.text).toBe('nested')
  })

  it('lets value win when both value and children are present', () => {
    const w = inline({
      type: 'code',
      value: 'from-value',
      children: [{ type: 'text', value: 'from-children' }],
    })
    expect(w.text).toBe('from-value')
  })

  it('still renders the flat value shape in the code style', () => {
    const w = inline({ type: 'code', value: 'flat' })
    expect(w.text).toBe('flat')
    expect(w.styles).toContainEqual(inlineCodeStyle(ctx))
  })

  it('renders an empty code span (no value, no children) without text', () => {
    const w = inline({ type: 'code' })
    expect(w.text).toBe('')
    expect(w.elements).toBe(1)
  })

  it('agrees with the chat register fence surface', () => {
    const chatCtx: InlineCtx = { theme, register: 'chat' }
    const w = walk(renderInlineNode({ type: 'code', children: ['x'] } as Inline, chatCtx, 0))
    expect(w.text).toBe('x')
    expect(w.styles).toContainEqual(inlineCodeStyle(chatCtx))
  })
})

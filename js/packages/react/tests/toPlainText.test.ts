// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import { describe, it, expect } from 'vitest'
import { toPlainText } from '../src/toPlainText'
import type { PortableTextNode } from '../src/PortableText'

describe('toPlainText', () => {
  it('concatenates a block’s spans', () => {
    const value: PortableTextNode[] = [
      { _type: 'block', children: [{ _type: 'span', text: 'Hello ' }, { _type: 'span', text: 'world' }] },
    ]
    expect(toPlainText(value)).toBe('Hello world')
  })

  it('separates blocks with a blank line', () => {
    const value: PortableTextNode[] = [
      { _type: 'block', children: [{ _type: 'span', text: 'One' }] },
      { _type: 'block', children: [{ _type: 'span', text: 'Two' }] },
    ]
    expect(toPlainText(value)).toBe('One\n\nTwo')
  })

  it('ignores marks — text only', () => {
    const value: PortableTextNode[] = [
      { _type: 'block', children: [{ _type: 'span', text: 'bold', marks: ['strong'] }] },
    ]
    expect(toPlainText(value)).toBe('bold')
  })

  it('skips non-block custom nodes (no stray separators)', () => {
    const value: PortableTextNode[] = [
      { _type: 'block', children: [{ _type: 'span', text: 'a' }] },
      { _type: 'image', url: '/x.jpg' } as unknown as PortableTextNode,
      { _type: 'block', children: [{ _type: 'span', text: 'b' }] },
    ]
    expect(toPlainText(value)).toBe('a\n\nb')
  })

  it('accepts a single block (not wrapped in an array)', () => {
    const value: PortableTextNode = { _type: 'block', children: [{ _type: 'span', text: 'solo' }] }
    expect(toPlainText(value)).toBe('solo')
  })

  it('returns empty string for null / undefined', () => {
    expect(toPlainText(null)).toBe('')
    expect(toPlainText(undefined)).toBe('')
    expect(toPlainText([])).toBe('')
  })

  it('is fail-soft on malformed blocks (missing / non-array children, non-string text)', () => {
    const missing = [{ _type: 'block' }] as unknown as PortableTextNode[]
    expect(toPlainText(missing)).toBe('')

    const notArray = [{ _type: 'block', children: 'oops' }] as unknown as PortableTextNode[]
    expect(toPlainText(notArray)).toBe('')

    const badText = [
      { _type: 'block', children: [{ _type: 'span', text: 42 }, { _type: 'span', text: 'ok' }] },
    ] as unknown as PortableTextNode[]
    expect(toPlainText(badText)).toBe('ok')
  })
})

// Shapes the extractor previously SILENTLY DROPPED (returned '' although the
// canonical renderer paints their text) — each row pins the words back into
// excerpts/search. Table-driven: one row per formerly-dropped authored shape,
// mirroring the renderer's own normalization (`paragraphInline` for heading/
// eyebrow content[], `itemInlines`/`normalizeListItem` for list items,
// `cellContent` for table cells, `renderBlocks` recursion for expandable).
describe('toPlainText — formerly-dropped type-keyed shapes', () => {
  const cases: Array<{ name: string; input: unknown; expected: string }> = [
    {
      name: 'heading persisted as content[] (the capstone-heading shape)',
      input: { type: 'heading', level: 2, content: [{ type: 'text', value: 'The render path' }] },
      expected: 'The render path',
    },
    {
      name: 'eyebrow persisted as content[]',
      input: { type: 'eyebrow', content: [{ type: 'text', value: 'Dispatches' }] },
      expected: 'Dispatches',
    },
    {
      name: 'list item as an untyped map with content[] (the dominant authored shape)',
      input: { type: 'list', items: [{ content: [{ type: 'text', value: 'map item' }] }] },
      expected: 'map item',
    },
    {
      name: 'list item as an untyped map with bare text',
      input: { type: 'list', items: [{ text: 'bare text item' }] },
      expected: 'bare text item',
    },
    {
      name: 'list item as a JSON-encoded inline array (drifted bullet_list authoring)',
      input: { type: 'list', items: ['[{"type":"text","value":"json item"}]'] },
      expected: 'json item',
    },
    {
      name: 'list mixing every item shape keeps them all, in order',
      input: {
        type: 'list',
        items: [
          [{ type: 'text', value: 'inline run' }],
          { content: [{ type: 'text', value: 'map item' }] },
          'plain string',
        ],
      },
      expected: 'inline run\nmap item\nplain string',
    },
    {
      name: 'table cell as an untyped map with bare text',
      input: { type: 'table', rows: [[{ text: 'cell one' }, { text: 'cell two' }]] },
      expected: 'cell one cell two',
    },
    {
      name: 'table cell as an untyped map with content[]',
      input: { type: 'table', rows: [[{ content: [{ type: 'text', value: 'rich cell' }] }]] },
      expected: 'rich cell',
    },
    {
      name: 'expandable summary + nested blocks (collapsed content is reading content)',
      input: {
        type: 'expandable',
        summary: 'Show the full trace',
        blocks: [{ type: 'paragraph', content: [{ type: 'text', value: 'Hidden detail.' }] }],
      },
      expected: 'Show the full trace\n\nHidden detail.',
    },
    {
      name: 'expandable authored with children instead of blocks',
      input: {
        type: 'expandable',
        summary: 'Trace',
        children: [{ type: 'paragraph', text: 'Body.' }],
      },
      expected: 'Trace\n\nBody.',
    },
    {
      name: 'callout body as a content[] inline array (guard — the live-corpus shape)',
      input: {
        type: 'callout',
        title: 'Heads up',
        content: [{ type: 'text', value: 'A content-array body.' }],
      },
      expected: 'Heads up\n\nA content-array body.',
    },
  ]

  for (const c of cases) {
    it(c.name, () => {
      expect(toPlainText([c.input] as never)).toBe(c.expected)
    })
  }
})

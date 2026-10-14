// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// The JS leg of the inline object parity lock (task-85fee859cf3bfef6).
//
// An inline object is a childless inline node `{type, ...fields}` with no
// built-in renderer, such as a schema's `blocks.inline` type. Three engines
// read ONE fixture, `api/test/support/fixtures/inline-object-text.json`:
//
//   Elixir  render/inline.ex inline_object_text/1, render/walk.ex
//           — api/test/barkpark/portable_doc/render/inline_object_parity_test.exs
//   JS      src/inline-object.ts inlineObjectText, src/inline.tsx — tested HERE
//   Go      internal/pdrender/inline.go inlineObjectText
//           — internal/pdrender/inline_object_parity_test.go
//
// Before this, the node rendered as nothing, so post-11's Sanity chip read
// "Status , written with Ada.".
import { readFileSync } from 'node:fs'
import { renderToString } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { escapeHtml, inlineObjectText, renderInline } from '../src/inline'
import { renderPortableDocument } from '../src/PortableDoc'
import { PortableText } from '../src/PortableText'
import type { PortableTextNode } from '../src/PortableText'

const FIXTURE_URL = new URL(
  '../../../../api/test/support/fixtures/inline-object-text.json',
  import.meta.url,
)

interface Case {
  name: string
  node: Record<string, unknown>
  text: string
}

const fixture = JSON.parse(readFileSync(FIXTURE_URL, 'utf8')) as { cases: Case[] }

const para = (node: Record<string, unknown>) => [
  { type: 'paragraph', content: [{ type: 'text', value: 'A ' }, node] },
]

describe('inline object text contract (shared fixture)', () => {
  it('carries every recorded case (a shrunken fixture cannot pass vacuously)', () => {
    expect(fixture.cases.length).toBeGreaterThanOrEqual(10)
  })

  for (const c of fixture.cases) {
    it(`inlineObjectText: ${c.name}`, () => {
      expect(inlineObjectText(c.node)).toBe(c.text)
    })

    it(`renderInline: ${c.name}`, () => {
      // A textless node keeps an empty marked span: never dropped silently.
      const want = `<span class="bp-inline-object" data-inline-type="${escapeHtml(String(c.node.type))}">${escapeHtml(c.text)}</span>`
      expect(renderInline(c.node as never)).toBe(want)
    })
  }
})

describe('registered inline object renderers', () => {
  const node = { type: 'status', text: 'Reviewed', tone: 'positive' }

  it('a registered renderer gets the stored node and owns the markup', () => {
    const html = renderPortableDocument(para(node), {
      inlineObjects: {
        status: (n) => `<mark data-tone="${escapeHtml(n.tone)}">${escapeHtml(n.text)}</mark>`,
      },
    })
    expect(html).toContain('<mark data-tone="positive">Reviewed</mark>')
    expect(html).not.toContain('bp-inline-object')
  })

  it('the registration ends with the render', () => {
    renderPortableDocument(para(node), { inlineObjects: { status: () => '<mark></mark>' } })
    expect(renderPortableDocument(para(node))).toContain(
      '<span class="bp-inline-object" data-inline-type="status">Reviewed</span>',
    )
  })

  it('a renderer that throws falls back to the span', () => {
    const html = renderPortableDocument(para(node), {
      inlineObjects: {
        status: () => {
          throw new Error('boom')
        },
      },
    })
    expect(html).toContain(
      '<span class="bp-inline-object" data-inline-type="status">Reviewed</span>',
    )
  })

  it('built-in inline types keep their own renderers', () => {
    const html = renderPortableDocument(para({ type: 'chip', text: 'Reviewed', tone: 'success' }), {
      inlineObjects: { chip: () => '<mark></mark>' },
    })
    expect(html).toContain('bp-chip')
    expect(html).not.toContain('<mark>')
  })
})

describe('PortableText shim: Sanity inline objects', () => {
  // post-11 as Sanity stores it: the chip is a sibling of the spans.
  const value = [
    {
      _type: 'block',
      children: [
        { _type: 'span', text: 'Status ' },
        { _type: 'chip', _key: 'k1', text: 'Reviewed', tone: 'positive' },
        { _type: 'span', text: ', written with Ada.' },
      ],
    },
  ] as unknown as PortableTextNode[]

  it('renders an inline object through components.types with isInline', () => {
    const html = renderToString(
      <PortableText
        value={value}
        components={{
          types: {
            chip: ({ value: v, isInline }) => (
              <b data-inline={String(isInline)}>{String(v.text)}</b>
            ),
          },
        }}
      />,
    )
    expect(html).toBe('<p>Status <b data-inline="true">Reviewed</b>, written with Ada.</p>')
  })

  it('without a component the spans still render and nothing throws', () => {
    // React separates adjacent text nodes with an empty comment.
    expect(renderToString(<PortableText value={value} />).replace(/<!-- -->/g, '')).toBe(
      '<p>Status , written with Ada.</p>',
    )
  })
})

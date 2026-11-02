import { describe, expect, it } from 'vitest'
import { createElement } from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
import { Window } from 'happy-dom'
import {
  diffShapes,
  loadLimits,
  shapeOf,
} from '../../../../api/priv/portable_doc/conformance/conformance.mjs'
import { PortableDoc } from '../src/index'

const render = (block: unknown) =>
  renderToStaticMarkup(createElement(PortableDoc, { value: [block] } as never))

function nodesOf(html: string): NodeList {
  const doc = new Window().document
  doc.body.innerHTML = html
  const only = doc.body.children.length === 1 ? doc.body.children[0] : null
  return (only?.classList.contains('bp-paper-surface')
    ? only.childNodes
    : doc.body.childNodes) as unknown as NodeList
}

const { edges, docs } = loadLimits()

describe('@barkpark/react answers each render limit like the reference', () => {
  it.each(edges.map((e) => [e.name, e] as const))('edge: %s', (_name, edge) => {
    expect(
      diffShapes(shapeOf(nodesOf(render(edge.input))), shapeOf(nodesOf(edge.expectedHtml))),
    ).toEqual([])
  })

  it.each(docs.map((d) => [d.name, d.doc] as const))(
    'worst case %s renders in under a second',
    (_name, doc) => {
      const started = process.cpuUsage()
      render(doc)
      const { user, system } = process.cpuUsage(started)
      expect((user + system) / 1000).toBeLessThan(1000)
    },
  )
})

const recordTable = (keys: number, rows: number) => ({
  type: 'table',
  columns: Array.from({ length: keys }, () => ({ key: 'k' })),
  rows: Array.from({ length: rows }, () => ({ k: 'v' })),
})

const nest = (depth: number, leaf: unknown): unknown =>
  Array.from({ length: depth }).reduce((inner) => ({ type: 'section', blocks: [inner] }), leaf)

const strongText = (depth: number) => ({
  type: 'paragraph',
  content: [
    Array.from({ length: depth }).reduce((inner) => ({ type: 'strong', children: [inner] }), {
      type: 'text',
      value: 'leaf',
    }),
  ],
})

describe('@barkpark/react render limits at their boundaries', () => {
  it('draws a record table of exactly the cell cap and refuses one cell row past it', () => {
    expect(render(recordTable(100, 100))).not.toContain('Table too large to show')
    expect(render(recordTable(101, 100))).toContain('<span>Table too large to show</span>')
  })

  it('counts a plain table with text columns as no record table', () => {
    const table = {
      ...recordTable(101, 100),
      columns: recordTable(101, 1).columns.map((c) => ({ ...c, text: 'K' })),
    }
    expect(render(table)).not.toContain('Table too large to show')
  })

  it('reads a toc deeper than six as six', () => {
    const doc = (depth: unknown) => [
      { type: 'toc', depth },
      ...[1, 2, 3, 4, 5, 6].map((level) => ({ type: 'heading', level, text: `h${level}` })),
    ]
    const html = (depth: unknown) =>
      renderToStaticMarkup(createElement(PortableDoc, { value: doc(depth) } as never))
    expect(html(7)).toBe(html(6))
    expect(html(1e9)).toBe(html(6))
    expect(html(0)).toBe(html(2))
    expect(html(2.5)).toBe(html(2))
  })

  it('shows a block one level above the limit and the notice at it', () => {
    const leaf = { type: 'paragraph', text: 'leaf' }
    expect(render(nest(99, leaf))).toContain('leaf')
    expect(render(nest(100, leaf))).not.toContain('leaf')
    expect(render(nest(100, leaf))).toContain('Nested too deep to show')
  })

  it('shows inline text one level above the limit and the notice at it', () => {
    expect(render(strongText(99))).toContain('leaf')
    expect(render(strongText(100))).not.toContain('leaf')
    expect(render(strongText(100))).toContain('Nested too deep to show')
  })

  it('counts marks toward the inline depth', () => {
    const marked = (n: number) => ({
      type: 'paragraph',
      content: [{ type: 'text', value: 'leaf', marks: Array.from({ length: n }, () => 'strong') }],
    })
    expect(render(marked(99))).toContain('leaf')
    expect(render(marked(100))).toContain('Nested too deep to show')
  })

  it('never puts a link inside a link', () => {
    const html = render({
      type: 'paragraph',
      content: [
        {
          type: 'link',
          href: 'https://a.example',
          children: [{ type: 'link', href: 'https://b.example', children: ['x'] }],
        },
      ],
    })
    expect(html.match(/<a /g)).toHaveLength(1)
  })

  it('says each notice in the reader language', () => {
    const strings = {
      'Nested too deep to show': 'For dypt nestet',
      'Table too large to show': 'Tabellen er for stor',
    }
    const html = (block: unknown) =>
      renderToStaticMarkup(createElement(PortableDoc, { value: [block], strings } as never))
    expect(html(nest(100, { type: 'paragraph', text: 'leaf' }))).toContain('For dypt nestet')
    expect(html(strongText(100))).toContain('For dypt nestet')
    expect(html(recordTable(101, 100))).toContain('Tabellen er for stor')
  })
})

const SLOTS: Array<[string, Array<string | 0>]> = [
  ['section', ['blocks', 0]],
  ['columns', ['columns', 0, 0]],
  ['terminal', ['blocks', 0]],
  ['terminal', ['children', 0]],
  ['expandable', ['blocks', 0]],
  ['expandable', ['children', 0]],
  ['tabs', ['tabs', 0, 'blocks', 0]],
  ['steps', ['steps', 0, 'blocks', 0]],
  ['steps', ['steps', 0, 'children', 0]],
  ['figure', ['child']],
  ['card', ['slots', 'action', 0]],
  ['card', ['slots', 'body', 0]],
  ['card', ['slots', 'media', 0]],
  ['card', ['slots', 'title', 0]],
]

const LISTS = [
  'list',
  'ordered-list',
  'numbered_list',
  'bulletList',
  'bullet_list',
  'bulleted-list',
  'bulleted_list',
]

function at(path: Array<string | 0>, value: unknown): unknown {
  if (path.length === 0) return value
  const [head, ...rest] = path as [string | 0, ...Array<string | 0>]
  return head === 0 ? [at(rest, value)] : { title: 't', label: 't', [head]: at(rest, value) }
}

describe('@barkpark/react caps every nested block slot', () => {
  it.each(SLOTS.map(([type, path]) => [`${type} ${path.join('.')}`, type, path] as const))(
    '%s counts toward the depth',
    (_name, type, path) => {
      const inside = (depth: number) => ({
        type,
        title: 't',
        summary: 's',
        ...(at(path, nest(depth, { type: 'paragraph', text: 'leaf' })) as object),
      })
      expect(render(inside(98))).toContain('leaf')
      expect(render(inside(99))).not.toContain('leaf')
      expect(render(inside(99))).toContain('Nested too deep to show')
    },
  )

  it.each(LISTS)('%s item children count toward the depth', (type) => {
    const lists = (depth: number): unknown =>
      Array.from({ length: depth }).reduce(
        (inner) => ({ type, items: [{ text: 'i', children: [inner] }] }),
        {
          type,
          items: ['leaf'],
        },
      )
    expect(render(lists(99))).toContain('leaf')
    expect(render(lists(100))).not.toContain('leaf')
  })
})

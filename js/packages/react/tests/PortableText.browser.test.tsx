// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import { renderToString } from 'react-dom/server'
import { describe, it, expect, vi } from 'vitest'
import { PortableText } from '../src/PortableText'
import type { PortableTextNode } from '../src/PortableText'

describe('PortableText', () => {
  it('renders empty array as empty string', () => {
    expect(renderToString(<PortableText value={[]} />)).toBe('')
  })

  it('renders a normal paragraph', () => {
    const value: PortableTextNode[] = [
      { _type: 'block', style: 'normal', children: [{ _type: 'span', text: 'hello' }] },
    ]
    expect(renderToString(<PortableText value={value} />)).toContain('<p>hello</p>')
  })

  it('renders headings', () => {
    const value: PortableTextNode[] = [
      { _type: 'block', style: 'h2', children: [{ _type: 'span', text: 'hi' }] },
    ]
    expect(renderToString(<PortableText value={value} />)).toContain('<h2>hi</h2>')
  })

  it('renders built-in marks (strong)', () => {
    const value: PortableTextNode[] = [
      {
        _type: 'block',
        children: [{ _type: 'span', text: 'bold', marks: ['strong'] }],
      },
    ]
    expect(renderToString(<PortableText value={value} />)).toContain('<strong>bold</strong>')
  })

  it('renders custom markDef link via components.mark', () => {
    const value: PortableTextNode[] = [
      {
        _type: 'block',
        markDefs: [{ _type: 'link', _key: 'k1', href: 'https://x.test' }],
        children: [{ _type: 'span', text: 'link', marks: ['k1'] }],
      },
    ]
    const html = renderToString(
      <PortableText
        value={value}
        components={{
          mark: {
            link: ({ children, value }) => (
              <a href={(value as { href: string }).href}>{children}</a>
            ),
          },
        }}
      />,
    )
    expect(html).toContain('<a href="https://x.test">link</a>')
  })

  it('nests marks inside-out (strong outside, em inside)', () => {
    const value: PortableTextNode[] = [
      {
        _type: 'block',
        children: [{ _type: 'span', text: 'x', marks: ['strong', 'em'] }],
      },
    ]
    expect(renderToString(<PortableText value={value} />)).toContain(
      '<strong><em>x</em></strong>',
    )
  })

  it('groups consecutive bullet listItems into a single <ul>', () => {
    const value: PortableTextNode[] = [
      { _type: 'block', listItem: 'bullet', children: [{ _type: 'span', text: 'a' }] },
      { _type: 'block', listItem: 'bullet', children: [{ _type: 'span', text: 'b' }] },
    ]
    const html = renderToString(<PortableText value={value} />)
    expect(html.match(/<ul>/g)?.length).toBe(1)
    expect(html).toContain('<li>a</li>')
    expect(html).toContain('<li>b</li>')
  })

  it('nests list items by level — a level-2 item becomes a nested list inside the parent <li>', () => {
    const value: PortableTextNode[] = [
      { _type: 'block', listItem: 'bullet', level: 1, children: [{ _type: 'span', text: 'a' }] },
      { _type: 'block', listItem: 'bullet', level: 2, children: [{ _type: 'span', text: 'b' }] },
      { _type: 'block', listItem: 'bullet', level: 1, children: [{ _type: 'span', text: 'c' }] },
    ]
    const html = renderToString(<PortableText value={value} />)
    // outer list + one nested list
    expect(html.match(/<ul>/g)?.length).toBe(2)
    // `b` is nested inside `a`'s <li>; `c` is back at the top level
    expect(html).toContain('a<ul><li>b</li></ul>')
    expect(html).toContain('<li>c</li>')
  })

  it('renders a block with missing/invalid children gracefully (no crash)', () => {
    // Loosely-typed query/migration data — a block missing its `children` array.
    // Without the guard, `block.children.map` throws and the whole render dies.
    const missing = [{ _type: 'block', style: 'normal' }] as unknown as PortableTextNode[]
    expect(renderToString(<PortableText value={missing} />)).toBe('<p></p>')

    const notArray = [
      { _type: 'block', style: 'normal', children: 'oops' },
    ] as unknown as PortableTextNode[]
    expect(renderToString(<PortableText value={notArray} />)).toBe('<p></p>')
  })

  it('renders custom block types via components.types', () => {
    const value: PortableTextNode[] = [{ _type: 'callout', text: 'note' }]
    const html = renderToString(
      <PortableText
        value={value}
        components={{
          types: {
            callout: ({ value }) => <aside>{(value as unknown as { text: string }).text}</aside>,
          },
        }}
      />,
    )
    expect(html).toContain('<aside>note</aside>')
  })

  it('falls back for unknown block style and calls onMissingComponent', () => {
    const miss = vi.fn()
    const value: PortableTextNode[] = [
      { _type: 'block', style: 'mystery', children: [{ _type: 'span', text: 'q' }] },
    ]
    const html = renderToString(
      <PortableText value={value} onMissingComponent={miss} />,
    )
    expect(html).toContain('q')
    expect(miss).toHaveBeenCalledTimes(1)
    expect(miss).toHaveBeenCalledWith(expect.objectContaining({ _type: 'mystery' }))
  })

  it('renders raw text for unknown mark and calls onMissingComponent', () => {
    const miss = vi.fn()
    const value: PortableTextNode[] = [
      {
        _type: 'block',
        children: [{ _type: 'span', text: 'raw', marks: ['unicorn'] }],
      },
    ]
    const html = renderToString(
      <PortableText value={value} onMissingComponent={miss} />,
    )
    expect(html).toContain('raw')
    expect(html).not.toContain('<unicorn')
    expect(miss).toHaveBeenCalledWith(expect.objectContaining({ markType: 'unicorn' }))
  })

  it('renders a newline inside a span as <br/> (hard break, default on)', () => {
    const value: PortableTextNode[] = [
      { _type: 'block', children: [{ _type: 'span', text: 'line one\nline two' }] },
    ]
    const html = renderToString(<PortableText value={value} />)
    expect(html).toContain('line one<br/>line two')
  })

  it('collapses multiple newlines into consecutive <br/> and composes with marks', () => {
    const value: PortableTextNode[] = [
      { _type: 'block', children: [{ _type: 'span', text: 'a\nb', marks: ['strong'] }] },
    ]
    const html = renderToString(<PortableText value={value} />)
    expect(html).toContain('<strong>a<br/>b</strong>')
  })

  it('hardBreak: false keeps the newline as raw text (no <br/>)', () => {
    const value: PortableTextNode[] = [
      { _type: 'block', children: [{ _type: 'span', text: 'a\nb' }] },
    ]
    const html = renderToString(<PortableText value={value} components={{ hardBreak: false }} />)
    expect(html).not.toContain('<br/>')
    expect(html).toContain('a\nb')
  })

  it('custom hardBreak component overrides the default <br/>', () => {
    const value: PortableTextNode[] = [
      { _type: 'block', children: [{ _type: 'span', text: 'a\nb' }] },
    ]
    const html = renderToString(
      <PortableText value={value} components={{ hardBreak: () => <span className="brk" /> }} />,
    )
    expect(html).toContain('class="brk"')
    expect(html).not.toContain('<br/>')
  })

  it('accepts a single block (not wrapped in array)', () => {
    const value: PortableTextNode = {
      _type: 'block',
      children: [{ _type: 'span', text: 'one' }],
    }
    expect(renderToString(<PortableText value={value} />)).toContain('<p>one</p>')
  })
})

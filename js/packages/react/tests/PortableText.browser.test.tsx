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

  it('accepts a single block (not wrapped in array)', () => {
    const value: PortableTextNode = {
      _type: 'block',
      children: [{ _type: 'span', text: 'one' }],
    }
    expect(renderToString(<PortableText value={value} />)).toContain('<p>one</p>')
  })
})

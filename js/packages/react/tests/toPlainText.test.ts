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

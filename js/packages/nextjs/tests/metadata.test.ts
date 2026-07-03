// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import { describe, it, expect } from 'vitest'
import { barkparkMetadata } from '../src/metadata'

describe('barkparkMetadata', () => {
  it('builds an OG article with publishedTime from a dated doc', () => {
    const md = barkparkMetadata({
      title: 'Hello',
      excerpt: 'A summary',
      publishedAt: '2026-01-02T00:00:00Z',
      _type: 'post',
    })
    expect(md.title).toBe('Hello')
    expect(md.description).toBe('A summary')
    expect(md.openGraph).toMatchObject({
      type: 'article',
      title: 'Hello',
      description: 'A summary',
      publishedTime: '2026-01-02T00:00:00Z',
    })
  })

  it('is an OG website (no publishedTime) when the doc has no publishedAt', () => {
    const md = barkparkMetadata({ title: 'About', description: 'The about page' })
    expect(md.openGraph).toMatchObject({ type: 'website', title: 'About' })
    expect('publishedTime' in (md.openGraph as Record<string, unknown>)).toBe(false)
  })

  it('falls back title→name and description→excerpt→description', () => {
    expect(barkparkMetadata({ name: 'Ada' }).title).toBe('Ada')
    expect(barkparkMetadata({ description: 'd' }).description).toBe('d')
    expect(barkparkMetadata({ excerpt: 'e', description: 'd' }).description).toBe('e')
  })

  it('overrides win over doc fields', () => {
    const md = barkparkMetadata(
      { title: 'Doc title', excerpt: 'Doc desc' },
      { title: '#tag', description: 'Override desc' },
    )
    expect(md.title).toBe('#tag')
    expect(md.description).toBe('Override desc')
  })

  it('omits blank/whitespace description (never emits "")', () => {
    const md = barkparkMetadata({ title: 'T', excerpt: '   ' })
    expect(md.description).toBeUndefined()
    expect('description' in (md.openGraph as Record<string, unknown>)).toBe(false)
  })

  it('degrades gracefully on a null/undefined doc', () => {
    expect(barkparkMetadata(null)).toEqual({ openGraph: { type: 'website' } })
    expect(barkparkMetadata(undefined)).toEqual({ openGraph: { type: 'website' } })
  })
})

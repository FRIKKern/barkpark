import { describe, it, expect } from 'vitest'
import { imageUrl } from '../src/image-url'
import { createClient } from '../src/client'

describe('imageUrl', () => {
  const base = 'https://cdn.example.com'

  it('builds a rendition URL from a preset', () => {
    expect(imageUrl({ _id: 'abc' }, { preset: 'hero', baseUrl: base })).toBe(
      'https://cdn.example.com/media/renditions/abc/hero',
    )
    // a {_ref} reference resolves the same way
    expect(imageUrl({ _ref: 'xyz' }, { preset: 'thumb', baseUrl: base })).toBe(
      'https://cdn.example.com/media/renditions/xyz/thumb',
    )
  })

  it('preset wins over an inline url (the inline url is the original)', () => {
    expect(
      imageUrl({ _id: 'abc', url: '/media/files/abc.jpg' }, { preset: 'preview', baseUrl: base }),
    ).toBe('https://cdn.example.com/media/renditions/abc/preview')
  })

  it('without a preset returns the original (inline url, else /images/<id>)', () => {
    expect(imageUrl({ _id: 'abc', url: '/media/files/abc.jpg' }, { baseUrl: base })).toBe(
      'https://cdn.example.com/media/files/abc.jpg',
    )
    expect(imageUrl({ _ref: 'abc' }, { baseUrl: base })).toBe('https://cdn.example.com/images/abc')
  })

  it('passes through a bare URL string; a preset cannot apply (no id)', () => {
    expect(imageUrl('https://other.example.com/x.jpg')).toBe('https://other.example.com/x.jpg')
    // no id to build a rendition → falls back to the string itself
    expect(imageUrl('https://other.example.com/x.jpg', { preset: 'hero', baseUrl: base })).toBe(
      'https://other.example.com/x.jpg',
    )
  })

  it('returns null for a nullish asset or an unresolvable one', () => {
    expect(imageUrl(null)).toBeNull()
    expect(imageUrl(undefined)).toBeNull()
    expect(imageUrl({})).toBeNull()
  })

  it('trims a trailing slash on baseUrl', () => {
    expect(imageUrl({ _id: 'a' }, { preset: 'og', baseUrl: 'https://cdn.example.com/' })).toBe(
      'https://cdn.example.com/media/renditions/a/og',
    )
  })

  it('client.imageUrl defaults baseUrl to projectUrl', () => {
    const bp = createClient({
      projectUrl: 'https://api.example.com',
      dataset: 'production',
      apiVersion: '2026-04-17',
    })
    expect(bp.imageUrl({ _id: 'abc' }, { preset: 'hero' })).toBe(
      'https://api.example.com/media/renditions/abc/hero',
    )
    // explicit baseUrl overrides the projectUrl default
    expect(bp.imageUrl({ _id: 'abc' }, { baseUrl: 'https://cdn.example.com' })).toBe(
      'https://cdn.example.com/images/abc',
    )
  })
})

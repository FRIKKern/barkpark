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

  it('URL-encodes a reserved-char id in the path (rendition + /images fallback)', () => {
    // id with a space and a slash → must not break the <img src> path
    expect(imageUrl({ _id: 'a b/c' }, { preset: 'hero', baseUrl: base })).toBe(
      'https://cdn.example.com/media/renditions/a%20b%2Fc/hero',
    )
    expect(imageUrl({ _ref: 'a b/c' }, { baseUrl: base })).toBe(
      'https://cdn.example.com/images/a%20b%2Fc',
    )
    // other reserved chars (# and ?) that would otherwise truncate the URL
    expect(imageUrl({ _id: 'x#y?z' }, { preset: 'thumb', baseUrl: base })).toBe(
      'https://cdn.example.com/media/renditions/x%23y%3Fz/thumb',
    )
  })

  it('URL-encodes a reserved-char preset (the open union accepts arbitrary strings)', () => {
    // a caller-supplied preset with a space/# must not break or truncate the src
    expect(imageUrl({ _id: 'abc' }, { preset: 'a b#c', baseUrl: base })).toBe(
      'https://cdn.example.com/media/renditions/abc/a%20b%23c',
    )
    // a known preset encodes to itself → behavior-preserving for the common case
    expect(imageUrl({ _id: 'abc' }, { preset: 'hero', baseUrl: base })).toBe(
      'https://cdn.example.com/media/renditions/abc/hero',
    )
  })

  it('trims a trailing slash on baseUrl', () => {
    expect(imageUrl({ _id: 'a' }, { preset: 'og', baseUrl: 'https://cdn.example.com/' })).toBe(
      'https://cdn.example.com/media/renditions/a/og',
    )
  })

  it('prepends pathPrefix to the rendition and /images paths', () => {
    // scoped rendition route — the flat one is pinned to the Default workspace
    expect(
      imageUrl({ _id: 'abc' }, { preset: 'hero', baseUrl: base, pathPrefix: '/w/acme/p/blog' }),
    ).toBe('https://cdn.example.com/w/acme/p/blog/media/renditions/abc/hero')
    // id-only asset, no preset → scoped /images fallback
    expect(imageUrl({ _ref: 'abc' }, { baseUrl: base, pathPrefix: '/w/acme/p/blog' })).toBe(
      'https://cdn.example.com/w/acme/p/blog/images/abc',
    )
  })

  it('ignores pathPrefix for an inline url (the original is served as-is)', () => {
    expect(
      imageUrl({ _id: 'abc', url: '/media/files/abc.jpg' }, { baseUrl: base, pathPrefix: '/w/acme/p/blog' }),
    ).toBe('https://cdn.example.com/media/files/abc.jpg')
  })

  it('without pathPrefix output is byte-identical to the unscoped paths', () => {
    expect(imageUrl({ _id: 'abc' }, { preset: 'hero', baseUrl: base })).toBe(
      'https://cdn.example.com/media/renditions/abc/hero',
    )
    expect(imageUrl({ _ref: 'abc' }, { baseUrl: base })).toBe('https://cdn.example.com/images/abc')
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

  it('scoped client emits scope-prefixed rendition URLs; unscoped is unchanged', () => {
    const scoped = createClient({
      projectUrl: 'https://api.example.com',
      dataset: 'production',
      apiVersion: '2026-04-17',
      workspace: 'acme',
      project: 'blog',
    })
    expect(scoped.imageUrl({ _id: 'abc' }, { preset: 'hero' })).toBe(
      'https://api.example.com/w/acme/p/blog/media/renditions/abc/hero',
    )
    expect(scoped.imageUrl({ _ref: 'abc' })).toBe(
      'https://api.example.com/w/acme/p/blog/images/abc',
    )

    // a flat (unscoped) client is byte-identical to before — scopePrefix() is ''
    const flat = createClient({
      projectUrl: 'https://api.example.com',
      dataset: 'production',
      apiVersion: '2026-04-17',
    })
    expect(flat.imageUrl({ _id: 'abc' }, { preset: 'hero' })).toBe(
      'https://api.example.com/media/renditions/abc/hero',
    )
  })
})

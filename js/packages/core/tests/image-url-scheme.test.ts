// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

// `imageUrl()` is a public export that hands the caller a string to put in
// markup. Its inline-url branch returned the stored field VERBATIM, so anyone
// who can write an image field controlled that string — including its SCHEME.
//
// Severity, stated honestly: the only sink traced in this repo is `<img src>`,
// where a `javascript:` URL does NOT execute. So this is a latent API-contract
// defect, not a proven XSS. It becomes one at any consumer that puts the result
// in an `<a href>`, and `imageUrl` is exported from index.ts carrying no such
// warning. The fix is the allowlist the package already applies to webhook
// delivery urls: an absolute url must be http(s).

import { describe, it, expect } from 'vitest'
import { imageUrl } from '../src/image-url'

const base = 'https://cdn.example.com'

describe('imageUrl rejects non-http(s) schemes', () => {
  it('drops a javascript: url carried on the asset', () => {
    expect(imageUrl({ _id: 'a1', url: 'javascript:alert(document.domain)' })).toBeNull()
  })

  it('drops a javascript: bare string, with and without a preset', () => {
    expect(imageUrl('javascript:alert(1)')).toBeNull()
    // A bare string has no id, so `preset` cannot apply — the preset branch is
    // not a rescue path, and never was.
    expect(imageUrl('javascript:alert(1)', { preset: 'hero', baseUrl: base })).toBeNull()
  })

  it('drops data: and vbscript: urls', () => {
    expect(imageUrl({ _id: 'a1', url: 'data:text/html,<script>alert(1)</script>' })).toBeNull()
    expect(imageUrl({ _id: 'a1', url: 'vbscript:msgbox(1)' })).toBeNull()
  })

  it('drops whitespace-obfuscated schemes (no leading-only strip hazard)', () => {
    expect(imageUrl('java\tscript:alert(1)')).toBeNull()
    expect(imageUrl('java\nscript:alert(1)')).toBeNull()
    expect(imageUrl('  javascript:alert(1)')).toBeNull()
    expect(imageUrl('JaVaScRiPt:alert(1)')).toBeNull()
  })

  it('drops a protocol-relative url (it escapes the origin when no baseUrl is set)', () => {
    expect(imageUrl('//evil.example/x.jpg')).toBeNull()
    expect(imageUrl({ _id: 'a1', url: '//evil.example/x.jpg' }, { baseUrl: base })).toBeNull()
  })

  // Subject present: the function still does its job, so deleting it does not
  // turn this file green.
  it('still returns http(s) urls and relative paths unchanged', () => {
    expect(imageUrl('https://cdn.example.com/a.jpg')).toBe('https://cdn.example.com/a.jpg')
    expect(imageUrl('http://cdn.example.com/a.jpg')).toBe('http://cdn.example.com/a.jpg')
    expect(imageUrl({ _id: 'a1', url: '/media/files/a1.jpg' }, { baseUrl: base })).toBe(
      'https://cdn.example.com/media/files/a1.jpg',
    )
    expect(imageUrl({ _id: 'abc' }, { preset: 'hero', baseUrl: base })).toBe(
      'https://cdn.example.com/media/renditions/abc/hero',
    )
    expect(imageUrl({ _id: 'abc' }, { baseUrl: base })).toBe('https://cdn.example.com/images/abc')
    expect(imageUrl(null)).toBeNull()
  })
})

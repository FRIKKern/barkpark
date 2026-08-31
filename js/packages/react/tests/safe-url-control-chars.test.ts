// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// `safeUrl` (src/inline.tsx) is the scheme allow-list every CMS-authored link
// passes through before it is spliced into an `<a href="…">` — the live sinks
// are the `link` MARK and the `link` NODE emitters in this same file. It used
// to strip ASCII control characters LEADING-ONLY and then test position 1 for
// the protocol-relative `//` or `/\` form.
//
// The WHATWG URL parser DELETES every ASCII tab (0x09), LF (0x0A) and CR (0x0D)
// from a URL string BEFORE parsing it. Probed across 0x00-0x20 against
// `new URL(raw, base)`, exactly those three collapse and every other C0 byte is
// percent-encoded into the path. So `/<TAB>/evil.example/phish` is not a path
// segment named "<TAB>" — the browser resolves it as `//evil.example/phish`,
// i.e. `https://evil.example/phish`, an off-site navigation from a link the
// allow-list said was root-relative and safe.
//
// These cases assert the RESOLVED URL, not just the returned string.
// Resolution is where the harm lands, and a return value that still LOOKS
// root-relative is exactly how this hid for as long as it did.
//
// Twin: web/lib/safe-href.ts (`safeHref`), fixed in lockstep — a duplicated
// sanitizer with one copy fixed is a defect, not a fix.

import { describe, expect, it } from 'vitest'
import { renderInlines, safeUrl } from '../src/inline'

/** Where a browser would actually navigate for this href on a reader page. */
const BASE = 'https://demo.barkpark.cloud/d/paper/x'
const resolves = (href: string) => new URL(href, BASE).href

/** `safeUrl` attribute-escapes its output; undo that to get the raw href a
 *  browser would parse out of the emitted markup. */
const unescapeAttr = (s: string) =>
  s
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&gt;/g, '>')
    .replace(/&lt;/g, '<')
    .replace(/&amp;/g, '&')

describe('safeUrl — subject presence', () => {
  it('is the exported guard and has not degraded to a pass-through', () => {
    expect(typeof safeUrl).toBe('function')
    expect(safeUrl('javascript:alert(1)')).toBe('#')
    expect(safeUrl('//evil.example/phish')).toBe('#')
    expect(safeUrl('/\\evil.example')).toBe('#')
  })
})

describe('safeUrl — embedded tab/LF/CR cannot smuggle a protocol-relative host', () => {
  const vectors = [
    '/\t/evil.example/phish',
    '/\n/evil.example/phish',
    '/\r/evil.example/phish',
    '/\t\\evil.example/phish',
    '/\n\\evil.example/phish',
    '/\r\\evil.example/phish',
    '/\t\t//evil.example/phish',
    '/\r\n/evil.example/phish',
  ]

  for (const raw of vectors) {
    it(`${JSON.stringify(raw)} does not resolve off-site`, () => {
      const emitted = unescapeAttr(safeUrl(raw))
      // The harm is the RESOLVED origin, not the returned string.
      expect(new URL(resolves(emitted)).origin).toBe('https://demo.barkpark.cloud')
      expect(resolves(emitted)).not.toContain('evil.example')
    })
  }

  it('the live <a href> sink emits no off-site link either', () => {
    const html = renderInlines([
      { type: 'text', value: 'click', marks: [{ type: 'link', href: '/\t/evil.example/phish' }] },
    ])
    const href = unescapeAttr(/href="([^"]*)"/.exec(html)?.[1] ?? '')
    expect(href).not.toBe('')
    expect(resolves(href)).not.toContain('evil.example')
  })
})

describe('safeUrl — embedded tab/LF/CR cannot smuggle a dangerous scheme', () => {
  it('drops jav<TAB>ascript: and its LF/CRLF spellings', () => {
    expect(safeUrl('jav\tascript:alert(1)')).toBe('#')
    expect(safeUrl('jav\nascript:alert(1)')).toBe('#')
    expect(safeUrl('java\r\nscript:alert(1)')).toBe('#')
  })
})

describe('safeUrl — what is checked is what resolves', () => {
  it('never returns a href still carrying tab/LF/CR', () => {
    for (const raw of ['/d/po\tst/x', 'https://example.com/a\nb', '#an\rchor', '?q=\t1']) {
      const out = unescapeAttr(safeUrl(raw))
      expect(out, `safeUrl(${JSON.stringify(raw)}) returned ${JSON.stringify(out)}`).not.toMatch(
        /[\t\n\r]/,
      )
    }
  })
})

describe('safeUrl — legitimate URLs stay untouched', () => {
  it('passes the permitted set through unchanged', () => {
    expect(safeUrl('/d/paper/my-paper')).toBe('/d/paper/my-paper')
    expect(safeUrl('https://example.com/a?b=1')).toBe('https://example.com/a?b=1')
    expect(safeUrl('mailto:hi@example.com')).toBe('mailto:hi@example.com')
    expect(safeUrl('tel:+4712345678')).toBe('tel:+4712345678')
    expect(safeUrl('#anchor')).toBe('#anchor')
    expect(safeUrl('./rel')).toBe('./rel')
    expect(safeUrl('../up')).toBe('../up')
    expect(resolves('/d/paper/x')).toBe('https://demo.barkpark.cloud/d/paper/x')
  })

  it('a non-string href still fails soft to #', () => {
    // @barkpark/react ships CJS/ESM to plain JS callers with no types, so the
    // shape guard is a runtime guarantee, not a type-level one. A bare string
    // is truthy AND iterable — neither shape may reach the sink.
    expect(safeUrl(undefined)).toBe('#')
    expect(safeUrl(null)).toBe('#')
    expect(safeUrl(42)).toBe('#')
    expect(safeUrl(['javascript:alert(1)'])).toBe('#')
    expect(safeUrl({ toString: () => 'javascript:alert(1)' })).toBe('#')
  })
})

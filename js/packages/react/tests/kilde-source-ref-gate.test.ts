// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// KILDE SOURCE-REF HTTPS-ONLY GATE — regression pin (pbw-backlog-react-emitter-
// defense-in-depth). The «kilde» stamp's <a href> is safe by a two-layer defense:
// (1) parseSourceRef returns a non-null href ONLY for `https://…` refs — every
// other scheme (http:, javascript:, data:, protocol-relative //) parses to null
// href or drops entirely; (2) the kildeHtml sink routes href through safeUrl,
// the canonical scheme-allowlister, so even a future loosening of layer (1)
// cannot turn the stamp into a live URL sink. This file pins layer (1) — the
// gate an emitter change could silently loosen.
//
// MUTATION-VALIDITY: widen the gate in src/blocks/dataviz.ts parseSourceRef
// (e.g. `ref.startsWith('https://')` → `ref.startsWith('http')`) and the
// http/scheme cases below go RED; restore and they re-green.

import { describe, it, expect } from 'vitest'
import { renderPortableDocument } from '../src'
import { parseSourceRef } from '../src/blocks/dataviz'

describe('parseSourceRef https-only href gate', () => {
  it('grants a link href ONLY to https:// refs', () => {
    const ref = parseSourceRef('https://example.com/data')
    expect(ref).not.toBeNull()
    expect(ref?.href).toBe('https://example.com/data')
  })

  it('bare "https://" (nothing after the scheme) does not parse', () => {
    expect(parseSourceRef('https://')).toBeNull()
  })

  it('non-https URL schemes never yield an href', () => {
    for (const bad of [
      'http://example.com/data',
      'javascript:alert(1)',
      'data:text/html,<script>alert(1)</script>',
      '//protocol-relative.example',
      'ftp://example.com/file',
      'HTTPS://example.com/upper-scheme',
    ]) {
      expect(parseSourceRef(bad), bad).toBeNull()
    }
  })

  it('commit/paper/task refs parse as plain provenance with NO href', () => {
    expect(parseSourceRef('commit:0123abc')?.href).toBeNull()
    expect(parseSourceRef('paper:some-slug')?.href).toBeNull()
    expect(parseSourceRef('task:task-abc123')?.href).toBeNull()
  })
})

describe('kilde stamp at the render boundary', () => {
  it('an https source renders a real link', () => {
    const html = renderPortableDocument([
      { type: 'stat', value: '42', label: 'Answer', source: 'https://example.com/proof' },
    ])
    expect(html).toContain('<a href="https://example.com/proof">')
  })

  it('a javascript: source renders NO anchor and NO live scheme', () => {
    const html = renderPortableDocument([
      { type: 'stat', value: '42', label: 'Answer', source: 'javascript:alert(1)' },
    ])
    expect(html).not.toContain('<a ')
    expect(html).not.toContain('javascript:')
  })

  it('an http:// source drops from the stamp entirely (a bad ref is not evidence)', () => {
    const html = renderPortableDocument([
      { type: 'stat', value: '42', label: 'Answer', source: 'http://example.com/insecure' },
    ])
    expect(html).not.toContain('<a ')
    expect(html).not.toContain('bp-kilde__ref')
  })
})

describe('forms typeClass fail-closed slug', () => {
  it('a hostile question type cannot inject extra class tokens', () => {
    const html = renderPortableDocument([
      {
        type: 'form',
        questions: [{ id: 'q1', prompt: 'P?', type: 'evil type injected-token' }],
      },
    ])
    // Slugified: spaces stripped, one fused token — never multiple injected tokens.
    expect(html).toContain('bp-form-q--eviltypeinjected-token')
    expect(html).not.toContain('bp-form-q--evil type')
  })

  it('a type that slugs to empty drops the modifier class entirely', () => {
    const html = renderPortableDocument([
      { type: 'form', questions: [{ id: 'q1', prompt: 'P?', type: '###' }] },
    ])
    expect(html).toContain('class="bp-form-question"')
    expect(html).not.toContain('bp-form-q--')
  })

  it('legit lowercase types are byte-unchanged (golden safety)', () => {
    const html = renderPortableDocument([
      { type: 'form', questions: [{ id: 'q1', prompt: 'P?', type: 'yesno' }] },
    ])
    expect(html).toContain('class="bp-form-question bp-form-q--yesno"')
  })
})

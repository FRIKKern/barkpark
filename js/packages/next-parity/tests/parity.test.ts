// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// WAVE-3 CAPSTONE (charter D25-D32): Next STATIC-EXPORT DOM-shape parity.
//
// W1 proved `@barkpark/react`'s `PortableDoc` renders every frozen non-plugin block type to
// HTML that DOM-shape-equals the Elixir `:article` golden. W2 re-proved it from an
// Astro static build. W3 re-runs the SAME proof from a THIRD surface: a real Next
// `output:'export'` build (`basePath:'/blog'`) in which the REAL, RSC-safe
// `<PortableDoc>` Server Component renders each block (idiom b2, NOT `set:html`).
// This suite reads the BUILT `out/**` HTML off disk and asserts:
//
//   1. PARITY — every `[data-pd-type]` wrapper extracted from `out/index.html` holds
//      an inner `.bp-paper-surface` whose DOM shape equals its Elixir golden, using
//      the UNCHANGED comparator from `@barkpark/react`'s W1 harness
//      (tests/support/dom-shape.ts, imported VERBATIM). Coverage ≡ the golden set.
//
//   2. basePath INVERSION (D29) — on `out/index.html`, >=1 asset ref carries the
//      `/blog/` prefix AND ZERO bare `/_next` refs exist at root (prefixed-PRESENT
//      and unprefixed-ABSENT), guarded against the vacuous empty case.
//
//   3. per-route SEO (D31) — `out/posts/*.html` heads carry the exact
//      `generateMetadata → barkparkMetadata` output: a DATED post is `og:type=article`
//      + `article:published_time` PRESENT; an UNDATED post is `og:type=website` with
//      the timestamp ABSENT. Exact-value, never mere presence.
//
//   4. NEGATIVE CONTROL (D30) — a corrupted extracted fragment makes the comparator
//      THROW, proving the gate can go red (Next export ships hydration JS by design,
//      so there is NO zero-JS assertion — the W2 zero-JS proof does not transfer).
//
// EXTRACTION: the built HTML is a FULL DOCUMENT, parsed with happy-dom's DOMParser
// (`parseFromString(html, 'text/html')`) — NOT `body.innerHTML`, which would hoist
// `<head>` content into phantom body roots and corrupt the walk.

import { describe, it, expect, beforeAll } from 'vitest'
import { existsSync, readdirSync, readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { Window } from 'happy-dom'
// The W1 comparator, reused VERBATIM — this file imports it, it is never edited.
import { assertShapeEqual } from '../../react/tests/support/dom-shape'

const HERE = dirname(fileURLToPath(import.meta.url))
const PKG_ROOT = join(HERE, '..')
const FIXTURE_DIR = join(PKG_ROOT, '..', 'react', 'tests', 'fixtures', 'pd-golden')
const SURFACE = 'bp-paper-surface'

interface GoldenFixture {
  type: string
  input: unknown
  expectedHtml: string
}

/** Locate a built HTML file under `out/`, tolerating a basePath-nested layout. */
function builtHtml(...rel: string[]): string {
  const candidates = [
    join(PKG_ROOT, 'out', ...rel),
    join(PKG_ROOT, 'out', 'blog', ...rel), // some Next versions nest export under basePath
  ]
  const found = candidates.find((p) => existsSync(p))
  if (!found) {
    throw new Error(
      `built HTML not found (${rel.join('/')}) — run \`next build\` ` +
        `(pnpm --filter @barkpark/next-parity build) first. Tried:\n  ${candidates.join('\n  ')}`,
    )
  }
  return readFileSync(found, 'utf8')
}

/** type -> frozen Elixir golden HTML, keyed by the golden's own `type`. */
function loadGoldens(): Map<string, GoldenFixture> {
  const map = new Map<string, GoldenFixture>()
  for (const f of readdirSync(FIXTURE_DIR).filter((n) => n.endsWith('.golden.json'))) {
    const g = JSON.parse(readFileSync(join(FIXTURE_DIR, f), 'utf8')) as GoldenFixture
    map.set(g.type, g)
  }
  return map
}

const goldens = loadGoldens()

let indexHtml = ''
let containers: { type: string; outerHTML: string }[] = []

beforeAll(() => {
  indexHtml = builtHtml('index.html')

  // FULL-DOCUMENT parse: DOMParser, NOT body.innerHTML.
  const window = new Window()
  try {
    const doc = new window.DOMParser().parseFromString(indexHtml, 'text/html')
    containers = Array.from(doc.querySelectorAll(`[data-pd-type]`)).map((el) => {
      // Idiom b2: the wrapper carries data-pd-type; the REAL component's root
      // `.bp-paper-surface` is the inner element we compare to the golden.
      const inner = el.querySelector(`.${SURFACE}`)
      return {
        type: el.getAttribute('data-pd-type') ?? '',
        outerHTML: inner ? inner.outerHTML : '',
      }
    })
  } finally {
    window.close?.()
  }
})

describe('Next static export → HTML DOM-shape parity (full frozen golden set)', () => {
  it('extracts one inner .bp-paper-surface per [data-pd-type] wrapper from the BUILT HTML', () => {
    expect(containers.length).toBe(goldens.size)
    for (const c of containers) {
      expect(c.type, 'a wrapper is missing its data-pd-type').not.toBe('')
      expect(goldens.has(c.type), `built HTML has an unknown data-pd-type="${c.type}"`).toBe(true)
      expect(c.outerHTML, `no inner .${SURFACE} inside [data-pd-type="${c.type}"]`).not.toBe('')
    }
  })

  it('covers every frozen golden fixture (coverage >= the golden-dir census, no silent gaps)', () => {
    const built = new Set(containers.map((c) => c.type))
    const missing = [...goldens.keys()].filter((t) => !built.has(t))
    expect(missing, `goldens absent from the Next build: ${missing.join(', ')}`).toHaveLength(0)
    // Derived from the canonical golden directory, never a hand-counted literal
    // (stale-count prose sweep): the floor moves WITH the frozen set.
    expect(containers.length).toBeGreaterThanOrEqual(goldens.size)
  })

  // One assertion per built container: its DOM shape must equal the Elixir golden.
  for (const file of readdirSync(FIXTURE_DIR)
    .filter((n) => n.endsWith('.golden.json'))
    .sort()) {
    const golden = JSON.parse(readFileSync(join(FIXTURE_DIR, file), 'utf8')) as GoldenFixture
    it(`${golden.type} — Next-built DOM shape equals Elixir golden`, () => {
      const container = containers.find((c) => c.type === golden.type)
      expect(container, `no built container for type "${golden.type}"`).toBeDefined()
      assertShapeEqual(container!.outerHTML, golden.expectedHtml, { unwrapClass: SURFACE })
    })
  }
})

describe('basePath sub-path hosting inversion (D29 — prefixed-present AND unprefixed-absent)', () => {
  // Every src="…"/href="…" reference in the built index HTML.
  function assetRefs(html: string): string[] {
    const refs: string[] = []
    for (const m of html.matchAll(/(?:src|href)="([^"]*)"/g)) refs.push(m[1])
    return refs
  }

  it('bakes the /blog basePath into asset refs and leaves NO bare /_next at root', () => {
    const refs = assetRefs(indexHtml)
    // Non-empty guard: the inversion is vacuous if the page has no assets at all.
    const nextRefs = refs.filter((r) => r.includes('/_next/'))
    expect(nextRefs.length, 'no /_next asset refs in the export — inversion would be vacuous').toBeGreaterThan(0)

    // PRESENT: >=1 asset carries the /blog/ prefix.
    const prefixed = nextRefs.filter((r) => r.startsWith('/blog/_next/') || r.includes('/blog/_next/'))
    expect(prefixed.length, `no /blog/-prefixed asset refs found; got: ${nextRefs.join(', ')}`).toBeGreaterThan(0)

    // ABSENT: ZERO bare /_next at root (i.e. a ref that starts "/_next" with no /blog prefix).
    const bare = refs.filter((r) => r.startsWith('/_next/'))
    expect(bare, `bare /_next asset refs leaked past basePath: ${bare.join(', ')}`).toHaveLength(0)
  })
})

describe('per-route SEO via generateMetadata → barkparkMetadata (D31, exact-value)', () => {
  function head(html: string): string {
    const m = html.match(/<head[^>]*>([\s\S]*?)<\/head>/i)
    return m ? m[1] : html
  }
  function metaContent(headHtml: string, prop: string): string | null {
    // Match property="prop" ... content="…" in either attribute order.
    const re = new RegExp(
      `<meta[^>]*(?:property|name)="${prop.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}"[^>]*>`,
      'i',
    )
    const tag = headHtml.match(re)?.[0]
    if (!tag) return null
    return tag.match(/content="([^"]*)"/i)?.[1] ?? null
  }
  function titleText(headHtml: string): string | null {
    return headHtml.match(/<title[^>]*>([\s\S]*?)<\/title>/i)?.[1]?.trim() ?? null
  }

  it('a DATED post → exact <title> + og:title + og:type=article + article:published_time PRESENT', () => {
    const h = head(builtHtml('posts', 'one-renderer-every-surface.html'))
    expect(titleText(h)).toBe('One Renderer, Every Surface')
    expect(metaContent(h, 'og:title')).toBe('One Renderer, Every Surface')
    expect(metaContent(h, 'og:type')).toBe('article')
    expect(metaContent(h, 'article:published_time')).toBe('2026-07-16T09:00:00.000Z')
    // NOT the og: variant — Next emits the article: namespace for published_time.
    expect(metaContent(h, 'og:published_time')).toBeNull()
  })

  it('an UNDATED (draft) post → og:type=website with article:published_time ABSENT', () => {
    const h = head(builtHtml('posts', 'draft-notes-on-hydration.html'))
    expect(titleText(h)).toBe('Draft Notes on Hydration')
    expect(metaContent(h, 'og:type')).toBe('website')
    expect(metaContent(h, 'article:published_time')).toBeNull()
  })
})

describe('negative control — the gate can go red (D30)', () => {
  it('a corrupted extracted fragment makes the comparator THROW', () => {
    const golden = goldens.get('paragraph')!
    expect(golden, 'paragraph golden must exist for the negative control').toBeDefined()
    // Corrupt the wrapper tag so the shape no longer matches the golden's <p> root.
    const corrupt = golden.expectedHtml.replace('<p>', '<blockquote>').replace('</p>', '</blockquote>')
    const wrapped = `<div class="${SURFACE}">${corrupt}</div>`
    expect(() => assertShapeEqual(wrapped, golden.expectedHtml, { unwrapClass: SURFACE })).toThrow()
  })
})

// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// WAVE-4 MEDIA-HYDRATION PROOF (charter D5 / D16-D19).
//
// W1-W3 proved the STATIC DOM-shape parity of `@barkpark/react`'s PortableDoc
// across Phoenix, Astro, and Next. Those harnesses read frozen HTML and compare
// tags/classes/data — they CANNOT cover the two media blocks whose `figures.ex`
// output is an INERT mount point that only becomes live after client-side work:
//
//   diagram   → <pre class="mermaid">…source…</pre>          (renders no SVG until hydrated)
//   asciicast → <div class="bp-asciicast" data-cast-src="…"> (mounts no player until hydrated)
//
// This suite renders the SAME `diagram` + `asciicast` pd-golden fixtures W1-W3
// froze (imported VERBATIM — never re-authored) via `renderPortableDocument`,
// calls the new `@barkpark/react/client` `hydratePortableDoc(container)`, and
// OBSERVES the real browser transforms under headless Playwright chromium:
//
//   • the <pre class="mermaid"> becomes a real <svg> with non-zero geometry
//     (a viewBox + rendered descendants), and
//   • the <div class="bp-asciicast"> gets an attached `.ap-player`.
//
// Browser mode is MANDATORY (charter D18): happy-dom has no layout engine so
// mermaid emits an empty SVG, and asciinema-player throws on the missing 2D
// canvas context. The default `test` script launches browser mode so this GATES
// under turbo/CI (unlike core's `test:browser` side-script, which turbo never
// runs).

import { describe, it, expect, beforeAll, afterEach, vi } from 'vitest'
import { renderPortableDocument } from '@barkpark/react'
import { hydratePortableDoc } from '@barkpark/react/client'

// The frozen W1 goldens, imported verbatim from `@barkpark/react`'s fixture dir —
// the canonical block array, NEVER re-authored here (charter: reuse fixtures).
import diagramGolden from '../../react/tests/fixtures/pd-golden/diagram.golden.json'
import asciicastGolden from '../../react/tests/fixtures/pd-golden/asciicast.golden.json'

interface Golden {
  type: string
  input: Record<string, unknown>
}

// A minimal valid asciicast v2 body so asciinema-player's fetch of the golden's
// `data-cast-src` resolves against NO real network target (charter: stub the
// `.cast` fetch). Header line + one output event.
const CAST_V2 =
  '{"version":2,"width":80,"height":24}\n[0.5,"o","barkpark w4\\r\\n"]\n'

beforeAll(() => {
  // asciinema-player 3.x loads the recording via `fetch`; point every `.cast`
  // request at the inline body above so no request leaves the browser.
  vi.stubGlobal(
    'fetch',
    vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input instanceof Request ? input.url : input)
      if (url.endsWith('.cast')) {
        return new Response(CAST_V2, {
          status: 200,
          headers: { 'content-type': 'text/plain' },
        })
      }
      return new Response('', { status: 404 })
    }),
  )
})

afterEach(() => {
  document.body.innerHTML = ''
})

/**
 * Render one golden fixture's block through PortableDoc's pure string emitter
 * into a live `.bp-paper-surface` container attached to the document (mermaid +
 * asciinema both need an in-document element to measure / mount).
 */
function mount(golden: Golden): HTMLElement {
  const container = document.createElement('div')
  container.className = 'bp-paper-surface'
  container.innerHTML = renderPortableDocument([golden.input as never])
  document.body.appendChild(container)
  return container
}

describe('W4 media hydration — real browser', () => {
  it('diagram: pre.mermaid hydrates into a real SVG with non-zero geometry', async () => {
    const container = mount(diagramGolden as Golden)

    const pre = container.querySelector('pre.mermaid') as HTMLElement | null
    expect(pre, 'the diagram fixture emits a <pre class="mermaid"> mount point').not.toBeNull()
    // Pre-hydration: source text only, no SVG.
    expect(pre!.querySelector('svg')).toBeNull()
    expect(pre!.textContent).toContain('graph TD')

    const result = await hydratePortableDoc(container)
    expect(result.mermaid).toBe(1)

    const svg = container.querySelector('pre.mermaid svg')
    expect(svg, 'mermaid rendered a real <svg> into the mount point').not.toBeNull()
    // Non-zero GEOMETRY, not an empty placeholder: a viewBox + rendered nodes.
    const viewBox = svg!.getAttribute('viewBox') ?? svg!.getAttribute('viewbox')
    expect(viewBox, 'the SVG carries a viewBox').toBeTruthy()
    expect(svg!.querySelectorAll('*').length).toBeGreaterThan(0)
    // mermaid stamps the node processed → the idempotency guard is armed.
    expect(pre!.getAttribute('data-processed')).toBe('true')
    // The raw source is stashed for a palette re-render (mirrors the Phoenix hook).
    expect(pre!.dataset.bpSrc).toContain('graph TD')
  })

  it('asciicast: div.bp-asciicast hydrates into an attached .ap-player', async () => {
    const container = mount(asciicastGolden as Golden)

    const mountPoint = container.querySelector('div.bp-asciicast') as HTMLElement | null
    expect(mountPoint, 'the asciicast fixture emits a <div class="bp-asciicast"> mount point').not.toBeNull()
    expect(mountPoint!.getAttribute('data-cast-src')).toBe('https://example.com/casts/demo.cast')
    // Pre-hydration: an inert mount point, no player.
    expect(container.querySelector('.ap-player')).toBeNull()

    const result = await hydratePortableDoc(container)
    expect(result.asciicast).toBe(1)

    expect(
      container.querySelector('.ap-player'),
      'asciinema-player attached its .ap-player element',
    ).not.toBeNull()
    // The idempotency stamp is set (mirrors the Phoenix runAsciicast hook).
    expect(mountPoint!.dataset.asciicastDone).toBe('true')
  })

  it('is idempotent: a second hydrate call transforms nothing new', async () => {
    const container = document.createElement('div')
    container.className = 'bp-paper-surface'
    container.innerHTML =
      renderPortableDocument([diagramGolden.input as never]) +
      renderPortableDocument([asciicastGolden.input as never])
    document.body.appendChild(container)

    const first = await hydratePortableDoc(container)
    expect(first).toEqual({ mermaid: 1, asciicast: 1, codeTabs: 0, tabs: 0 })

    const second = await hydratePortableDoc(container)
    expect(second, 'processed mount points are skipped on re-run').toEqual({
      mermaid: 0,
      asciicast: 0,
      codeTabs: 0,
      tabs: 0,
    })
  })

  it('is a no-op on a media-free subtree', async () => {
    const container = document.createElement('div')
    container.className = 'bp-paper-surface'
    container.innerHTML = '<p>no media here</p>'
    document.body.appendChild(container)

    const result = await hydratePortableDoc(container)
    expect(result).toEqual({ mermaid: 0, asciicast: 0, codeTabs: 0, tabs: 0 })
  })
})

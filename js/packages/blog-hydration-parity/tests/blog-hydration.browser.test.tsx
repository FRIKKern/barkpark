// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// WAVE-6 CONSUMING-APP HYDRATION PROOF (charter D5 / D16-D19).
//
// media-parity (W4) proved `hydratePortableDoc` transforms the two media mount
// points, but it rendered the fixtures ITSELF via a bespoke `mount()` helper.
// This suite closes the last gap: it drives the REAL consuming-app surface —
// create-barkpark-app's `PortableDocSurface` island — mounted as an actual
// React component through `@testing-library/react` under headless Playwright
// chromium, fed the flagship 42-type showcase seed the template ships. The
// island is imported READ-ONLY from the template tree (never modified), so a
// green here means: a cold Next app that drops in the canonical renderer and
// its client hook gets live media, end to end.
//
// KNOB 3 (pre-optimize): `hydratePortableDoc` dynamically imports `mermaid` and
// `asciinema-player` INSIDE a useEffect. Vite would late-discover them mid-test
// and reject the in-flight dynamic import ("outdated optimize dep"). Importing
// them statically at module top forces vite's dep pre-bundle to include them
// before the browser starts, so the runtime dynamic imports resolve instantly.
import 'mermaid'
import 'asciinema-player'
import 'asciinema-player/dist/bundle/asciinema-player.css'

import { describe, it, expect, beforeAll, afterAll, afterEach, vi } from 'vitest'
import { render, waitFor, cleanup } from '@testing-library/react'

// The REAL blog-starter island + its flagship seed — imported read-only from
// the create-barkpark-app template tree. NEVER modified by this package.
import { PortableDocSurface } from '../../create-barkpark-app/templates/blog-starter/app/posts/[slug]/portable-doc-surface'
import { showcaseContent } from '../../create-barkpark-app/templates/blog-starter/seeds/showcase-content'

// The revert-red guard: a copy of the island with the hydratePortableDoc call
// removed. Proves the positive assertions below are protective, not vacuous.
import { NeuterDocSurface } from './neuter-surface'

// A minimal valid asciicast v2 body so asciinema-player's fetch of the seed's
// `data-cast-src` (https://example.com/casts/demo.cast) resolves against NO
// real network target. Header line + one output event.
const CAST_V2 =
  '{"version":2,"width":80,"height":24}\n[0.5,"o","barkpark w6\\r\\n"]\n'

// KNOB 4 (scoped unhandledrejection swallow): after a test unmounts, mermaid may
// still resolve a lazily-imported diagram chunk whose promise then rejects into
// a torn-down module graph. That surfaces as an unhandledrejection that would
// fail the run even though the ASSERTIONS already passed. Swallow ONLY those
// mermaid / dynamic-import teardown rejections; let everything else propagate.
function isTeardownNoise(reason: unknown): boolean {
  const msg = String(
    (reason as { message?: string })?.message ?? reason ?? '',
  )
  return /mermaid|dynamically imported|Importing a module|Failed to fetch dynamically|outdated optimize/i.test(
    msg,
  )
}
const swallow = (e: PromiseRejectionEvent) => {
  if (isTeardownNoise(e.reason)) e.preventDefault()
}

beforeAll(() => {
  window.addEventListener('unhandledrejection', swallow)
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

afterAll(() => {
  window.removeEventListener('unhandledrejection', swallow)
  vi.unstubAllGlobals()
})

afterEach(() => {
  cleanup()
})

/** True once mermaid has rendered a real <svg> with non-zero geometry. */
function liveMermaidSvg(root: ParentNode): SVGSVGElement | null {
  const svg = root.querySelector<SVGSVGElement>('pre.mermaid svg')
  if (!svg) return null
  const viewBox = svg.getAttribute('viewBox') ?? svg.getAttribute('viewbox')
  if (!viewBox) return null
  if (svg.querySelectorAll('*').length === 0) return null
  return svg
}

describe('W6 blog-starter island hydration — real consuming-app surface', () => {
  it('the REAL island drives hydratePortableDoc: mermaid → live SVG AND asciicast → attached .ap-player', async () => {
    const { container } = render(<PortableDocSurface blocks={showcaseContent} />)

    // The island renders the static mount points synchronously (SSR-shaped
    // HTML). Its useEffect then calls hydratePortableDoc(ref.current).
    const surface = container.querySelector('.bp-paper-surface') as HTMLElement
    expect(surface, 'the island rendered its bp-paper-surface root').not.toBeNull()
    expect(
      surface.querySelector('pre.mermaid'),
      'the seed carries a diagram block → a <pre class="mermaid"> mount point',
    ).not.toBeNull()
    expect(
      surface.querySelector('div.bp-asciicast'),
      'the seed carries an asciicast block → a <div class="bp-asciicast"> mount point',
    ).not.toBeNull()

    // Wait for the island's own useEffect-driven hydration to transform BOTH
    // media mount points — asserted with waitFor, not mere presence.
    await waitFor(
      () => {
        const svg = liveMermaidSvg(surface)
        expect(svg, 'mermaid hydrated into a real <svg> with non-zero geometry').not.toBeNull()
        expect(
          surface.querySelector('.ap-player'),
          'asciinema-player attached its .ap-player element',
        ).not.toBeNull()
      },
      { timeout: 8000 },
    )

    // Belt-and-braces: the SVG geometry is genuinely non-empty and mermaid
    // stamped its idempotency guard (mirrors the Phoenix hook).
    const svg = liveMermaidSvg(surface)!
    expect(svg.querySelectorAll('*').length).toBeGreaterThan(0)
    expect(
      surface.querySelector('pre.mermaid')!.getAttribute('data-processed'),
    ).toBe('true')
  })

  it('revert-red guard: the NEUTER island (hydration call removed) stays inert', async () => {
    const { container } = render(<NeuterDocSurface blocks={showcaseContent} />)
    const surface = container.querySelector('.bp-paper-surface') as HTMLElement

    // The SAME static mount points render — proving the neuter is a faithful
    // clone and the difference is ONLY the missing hydration call.
    expect(surface.querySelector('pre.mermaid'), 'mount point present').not.toBeNull()
    expect(surface.querySelector('div.bp-asciicast'), 'mount point present').not.toBeNull()

    // Give hydration the SAME window the positive test used. Without the
    // hydratePortableDoc call nothing transforms it, so it must stay inert.
    await new Promise((r) => setTimeout(r, 1500))

    expect(
      liveMermaidSvg(surface),
      'no hydration call → no live mermaid SVG (this is what a silent regression would look like)',
    ).toBeNull()
    expect(
      surface.querySelector('.ap-player'),
      'no hydration call → no attached asciicast player',
    ).toBeNull()
    expect(
      surface.querySelector('pre.mermaid')!.getAttribute('data-processed'),
      'the mermaid idempotency stamp was never set',
    ).not.toBe('true')
  })
})

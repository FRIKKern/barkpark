// @vitest-environment happy-dom
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// The FAILURE half of asciicast hydration (jf-backlog-asciicast-empty-box).
//
// `hydrateAsciicast` used to call `player.create(...)`, stamp
// `data-asciicast-done` and count `mounted += 1` unconditionally. Mounting is
// not loading: on a recording the player cannot fetch (404, CSP, CORS, an
// air-gapped reader) asciinema paints `div.ap-overlay-error` — a bordered box
// whose whole content is a 💥 glyph — and the hydration still reported
// `{asciicast: 1}`. Two lies in one call: the reader gets the empty box the
// komposisjon law forbids, and the caller is told a recording is on the page.
//
// The player module is mocked, because the thing under test is OUR reaction to
// the player's DOM, not the player. To keep the mock from DEFUSING the test,
// every assertion is about state the SOURCE owns:
//   • the fallback markup and its copy (the mock never writes it);
//   • which mount points were emptied of the error overlay;
//   • the three counts the source computes from the probe outcomes.
// The mock's only job is to paint asciinema's OWN two surfaces —
// `.ap-overlay-error` (fault) / `.ap-terminal` (painted) — byte-for-byte as the
// real 3.x player does.

import { describe, it, expect, beforeEach, vi } from 'vitest'

/** What the next `player.create()` call should paint. */
let castOutcome: 'ok' | 'error' | 'throw' = 'ok'
const createCalls: Array<{ src: string; opts: Record<string, unknown> }> = []

vi.mock('asciinema-player', () => ({
  create(src: string, el: HTMLElement, opts: Record<string, unknown>) {
    createCalls.push({ src, opts })
    if (castOutcome === 'throw') throw new Error('player refused to mount')
    const player = el.ownerDocument.createElement('div')
    player.className = 'ap-player'
    const overlay = el.ownerDocument.createElement('div')
    if (castOutcome === 'error') {
      // asciinema-player 3.x's real failure surface: an overlay holding one glyph.
      overlay.className = 'ap-overlay ap-overlay-error'
      overlay.textContent = '💥'
    } else {
      overlay.className = 'ap-terminal'
      overlay.textContent = '$ barkpark --help'
    }
    player.appendChild(overlay)
    el.appendChild(player)
    return {}
  },
}))

const { hydratePortableDoc } = await import('../src/client')
const { renderPortableDocument } = await import('../src/PortableDoc')

const CAST_SRC = 'https://example.com/casts/demo.cast'
const CAPTION = 'A terminal walkthrough'

/**
 * The REAL emitter's markup, not a hand-written fixture: the `<figure>` +
 * mount-point + `<figcaption>` shape is the contract the fallback must respect,
 * and taking it from `renderPortableDocument` means a markup change reaches this
 * test instead of sliding past it.
 */
function mountCast(src = CAST_SRC): HTMLElement {
  document.body.innerHTML = renderPortableDocument([
    { type: 'asciicast', src, caption: CAPTION } as never,
  ])
  const el = document.body.querySelector<HTMLElement>('div.bp-asciicast')
  if (!el) throw new Error('the asciicast emitter produced no mount point')
  return el
}

beforeEach(() => {
  castOutcome = 'ok'
  createCalls.length = 0
  document.body.innerHTML = ''
})

describe('asciicast hydration — the LOADED path', () => {
  it('a recording that paints is counted loaded and keeps the live player', async () => {
    const el = mountCast()

    const result = await hydratePortableDoc(document)

    expect(result.asciicast, 'one recording loaded').toBe(1)
    expect(result.asciicastMounted).toBe(1)
    expect(result.asciicastFailed).toBe(0)
    // The player's own DOM is untouched — no fallback was swapped in.
    expect(el.querySelector('.ap-player'), 'the live player stays').not.toBeNull()
    expect(el.querySelector('.bp-asciicast__fallback')).toBeNull()
    expect(el.dataset.asciicastFailed).toBeUndefined()
    expect(el.dataset.asciicastDone).toBe('true')
    expect(createCalls).toHaveLength(1)
    expect(createCalls[0]!.src).toBe(CAST_SRC)
  })

  it('is idempotent: a second pass re-mounts nothing and re-counts nothing', async () => {
    mountCast()
    await hydratePortableDoc(document)

    const second = await hydratePortableDoc(document)

    expect(second.asciicast).toBe(0)
    expect(second.asciicastMounted).toBe(0)
    expect(second.asciicastFailed).toBe(0)
    expect(createCalls, 'no second create() on a done mount point').toHaveLength(1)
  })
})

describe('asciicast hydration — the FAILED path', () => {
  it('swaps asciinema’s emoji box for an honest fallback and counts it failed', async () => {
    castOutcome = 'error'
    const el = mountCast()

    const result = await hydratePortableDoc(document)

    // The COUNT tells the truth: mounted, but not loaded.
    expect(result.asciicast, 'nothing loaded').toBe(0)
    expect(result.asciicastMounted, 'a player was still attempted').toBe(1)
    expect(result.asciicastFailed).toBe(1)

    // The BOX tells the truth: no bare glyph, a sentence instead.
    expect(el.querySelector('.ap-overlay-error'), 'the 💥 overlay is gone').toBeNull()
    expect(el.textContent).not.toContain('💥')
    const fallback = el.querySelector('.bp-asciicast__fallback')
    expect(fallback, 'the honest fallback replaced it').not.toBeNull()
    expect(fallback!.textContent).toContain('Opptaket kunne ikke lastes.')

    // …and it hands the reader the recording itself.
    const link = el.querySelector<HTMLAnchorElement>('a.bp-asciicast__fallback-link')
    expect(link, 'the raw cast is linked').not.toBeNull()
    expect(link!.getAttribute('href')).toBe(CAST_SRC)

    // The CAPTION survives: it is the figure's, not the player's.
    const caption = document.body.querySelector('figcaption.bp-figcaption')
    expect(caption, 'the figcaption is still in the figure').not.toBeNull()
    expect(caption!.textContent).toBe(CAPTION)

    // Stamped both ways: still skipped by the idempotency guard, and selectable
    // as a faulted cast.
    expect(el.dataset.asciicastDone).toBe('true')
    expect(el.dataset.asciicastFailed).toBe('true')
  })

  it('a create() that throws lands on the same fallback', async () => {
    castOutcome = 'throw'
    const el = mountCast()

    const result = await hydratePortableDoc(document)

    expect(result).toEqual({
      mermaid: 0,
      asciicast: 0,
      asciicastMounted: 1,
      asciicastFailed: 1,
      codeTabs: 0,
      tabs: 0,
    })
    expect(el.querySelector('.bp-asciicast__fallback')!.textContent).toContain(
      'Opptaket kunne ikke lastes.',
    )
  })

  it('a non-fetchable cast src degrades to message-only, never a javascript: link', async () => {
    castOutcome = 'error'
    // `safeUrl` already refuses this at emit time, so build the mount point by
    // hand — the guard under test is the fallback's own, and a future emitter
    // change must not be able to hand a scheme through to `href`.
    document.body.innerHTML =
      '<figure><div class="bp-asciicast" data-cast-src="javascript:alert(1)"></div>' +
      '<figcaption class="bp-figcaption">' + CAPTION + '</figcaption></figure>'
    const el = document.body.querySelector<HTMLElement>('div.bp-asciicast')!

    const result = await hydratePortableDoc(document)

    expect(result.asciicastFailed).toBe(1)
    expect(el.textContent).toContain('Opptaket kunne ikke lastes.')
    expect(el.querySelector('a'), 'no link is better than a scheme link').toBeNull()
  })
})

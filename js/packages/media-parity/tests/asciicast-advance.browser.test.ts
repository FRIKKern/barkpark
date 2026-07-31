// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// WAVE-6 ASCIICAST FRAME-ADVANCE PROOF (charter D21/D34 — closing the W4
// attach→advance leg, HARDEN-only).
//
// W4 (`media.browser.test.ts`) proved asciinema-player ATTACHES: after
// `hydratePortableDoc`, the inert `<div class="bp-asciicast">` grows an
// `.ap-player`. It stubbed the `.cast` fetch with a one-event body and never
// pressed play, so it never proved the player renders REAL TERMINAL FRAMES that
// ADVANCE over time — only that a wrapper mounted.
//
// This suite closes that leg end-to-end. It commits a real multi-frame
// asciicast-v2 file (`fixtures/advance.cast`, imported VERBATIM as bytes) with
// two output events:
//
//   t=0.2s  "POSTER_BASE_7Q2"    — inside the poster:'npt:0:1' snapshot (t≈1s)
//   t=1.4s  "ADVANCE_FRAME_9Z4"  — AFTER the poster; only appears once playback
//                                   advances past t=1.4s
//
// (The 1.2s pre→post gap is < the `idleTimeLimit:2` client.ts sets, so the
// player advances the gap in real time instead of collapsing it.)
//
// The drive path is `hydratePortableDoc` + a `.ap-overlay-start` DOM-click ONLY.
// `autoPlay`/`seek` would force a renderer edit to `@barkpark/react`'s
// `client.ts` (the mount options are baked there); a DOM-click keeps this
// HARDEN-only — ZERO renderer change. Browser mode is mandatory (charter D18):
// asciinema needs a real 2D-canvas + layout to run the terminal.
//
// The green is non-vacuous by construction:
//   • ANTI-VACUOUS BASELINE — the poster renders t≈1s, so POSTER_BASE is present
//     the instant we mount. Mere "advance text eventually present" would be
//     meaningless; we first assert ADVANCE_FRAME is ABSENT at the poster, then
//     that the CLICK is what makes it appear.
//   • REVERT-RED NEUTER — the sibling test runs the identical setup MINUS the
//     click and proves ADVANCE_FRAME stays absent for ≥6s. If autoPlay ever
//     crept into client.ts (or the poster stopped gating), the neuter goes red —
//     so the positive test's pass is proven load-bearing on the click.

import { describe, it, expect, beforeAll, afterAll, afterEach, vi } from 'vitest'
import { renderPortableDocument } from '@barkpark/react'
import { hydratePortableDoc } from '@barkpark/react/client'

// The frozen W1 asciicast golden — imported verbatim, NEVER re-authored. Its
// `src` is a 404 placeholder (`https://example.com/casts/demo.cast`); the fetch
// stub below serves the committed bytes in its place.
import asciicastGolden from '../../react/tests/fixtures/pd-golden/asciicast.golden.json'

// The committed multi-frame asciicast-v2 fixture, imported as raw bytes (Vite
// `?raw`). These EXACT bytes are what the stubbed fetch returns, so the proof
// runs against a real on-disk `.cast`, not an inline literal.
import advanceCast from './fixtures/advance.cast?raw'

// The two markers live in `fixtures/advance.cast`. POSTER_BASE is emitted at
// t=0.2s (inside the t≈1s poster); ADVANCE_FRAME at t=1.4s (after it).
const POSTER_BASE = 'POSTER_BASE_7Q2'
const ADVANCE_FRAME = 'ADVANCE_FRAME_9Z4'

interface Golden {
  type: string
  input: Record<string, unknown>
}

// The golden's `input` now carries the per-block `poster` (`npt:0:12`) so the
// pd-parity gate proves `data-cast-poster` byte-identical across the Elixir/TS
// twins. That poster sits PAST the t=1.4s advance frame, which is exactly what
// the third test below exercises — so the two DEFAULT-poster tests strip the
// key first and pin the unset → `npt:0:1` fallback leg.
const DEFAULT_POSTER_GOLDEN: Golden = (() => {
  const input = { ...(asciicastGolden as Golden).input }
  delete input.poster
  return { ...(asciicastGolden as Golden), input }
})()

beforeAll(() => {
  // Serve the committed `advance.cast` bytes for every `.cast` request so no
  // request leaves the browser (the W4 vi.stubGlobal pattern).
  vi.stubGlobal(
    'fetch',
    vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input instanceof Request ? input.url : input)
      if (url.endsWith('.cast')) {
        return new Response(advanceCast, {
          status: 200,
          headers: { 'content-type': 'text/plain' },
        })
      }
      return new Response('', { status: 404 })
    }),
  )
})

afterAll(() => {
  vi.unstubAllGlobals()
})

afterEach(() => {
  document.body.innerHTML = ''
})

/** Mount the asciicast golden's block into an in-document `.bp-paper-surface`. */
function mount(golden: Golden, overrides: Record<string, unknown> = {}): HTMLElement {
  const container = document.createElement('div')
  container.className = 'bp-paper-surface'
  container.innerHTML = renderPortableDocument([
    { ...golden.input, ...overrides } as never,
  ])
  document.body.appendChild(container)
  return container
}

/** The live terminal's text = every rendered `.ap-line` joined. */
function terminalText(container: HTMLElement): string {
  return Array.from(container.querySelectorAll('.ap-line'))
    .map((l) => l.textContent ?? '')
    .join('\n')
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))

describe('W6 asciicast frame advance — real browser', () => {
  it('advances past the poster to render the post-poster frame on a play click', async () => {
    const container = mount(DEFAULT_POSTER_GOLDEN)

    // Pre-hydration: an inert mount point, no player (W4 baseline).
    expect(container.querySelector('.ap-player')).toBeNull()

    const result = await hydratePortableDoc(container)
    expect(result.asciicast).toBe(1)
    expect(
      container.querySelector('.ap-player'),
      'asciinema-player attached its .ap-player element',
    ).not.toBeNull()

    // The player renders the poster (t≈1s) into `.ap-line`s. Wait for that
    // snapshot to actually paint, so the baseline below is meaningful and not
    // just "the terminal has not rendered yet".
    await vi.waitFor(
      () => {
        expect(
          terminalText(container),
          'the poster snapshot rendered the t=0.2s frame',
        ).toContain(POSTER_BASE)
      },
      { timeout: 5000, interval: 100 },
    )

    // ANTI-VACUOUS BASELINE: the poster is live (POSTER_BASE above), yet the
    // t=1.4s ADVANCE frame is ABSENT — the poster gates it out. So a later
    // "ADVANCE present" can only come from playback advancing, not the poster.
    expect(
      terminalText(container),
      'the t=1.4s advance frame is NOT in the t≈1s poster',
    ).not.toContain(ADVANCE_FRAME)

    // DRIVE = DOM-click ONLY. The start overlay's play button starts playback;
    // no autoPlay/seek, so client.ts stays untouched.
    const startOverlay = container.querySelector(
      '.ap-overlay-start',
    ) as HTMLElement | null
    expect(
      startOverlay,
      'the paused/poster player shows a .ap-overlay-start play button',
    ).not.toBeNull()
    startOverlay!.click()

    // Playback now advances 0 → 0.2s → 1.4s; poll the terminal until the frame
    // that was absent at the poster actually renders.
    await vi.waitFor(
      () => {
        expect(
          terminalText(container),
          'playback advanced past t=1.4s and rendered the post-poster frame',
        ).toContain(ADVANCE_FRAME)
      },
      { timeout: 8000, interval: 100 },
    )
  })

  it('revert-red neuter: without the play click the advance frame never appears (held ≥6s)', async () => {
    const container = mount(DEFAULT_POSTER_GOLDEN)

    const result = await hydratePortableDoc(container)
    expect(result.asciicast).toBe(1)

    // Same setup, but NO click. Prove the poster paints first (player is alive),
    // then hold and prove the advance frame stays absent the whole time.
    await vi.waitFor(
      () => {
        expect(terminalText(container)).toContain(POSTER_BASE)
      },
      { timeout: 5000, interval: 100 },
    )

    // Hold ≥6s (well past the 1.4s advance timestamp). A live-but-un-driven
    // player must never surface the advance frame; if it does (e.g. autoPlay
    // slipped into client.ts, or the poster stopped gating), this goes RED.
    const HOLD_MS = 6500
    const step = 300
    for (let waited = 0; waited < HOLD_MS; waited += step) {
      await sleep(step)
      const text = terminalText(container)
      expect(
        text,
        `advance frame must stay absent without a play click (t+${waited}ms)`,
      ).not.toContain(ADVANCE_FRAME)
      // Sanity: the player stays alive (poster frame keeps rendering), so the
      // absence above is a real time-gate, not a dead/blank terminal.
      expect(text, `poster frame stays rendered (t+${waited}ms)`).toContain(
        POSTER_BASE,
      )
    }
  }, 15000)

  // ── the per-block `poster` option ─────────────────────────────────────────
  // The mirror image of the two tests above. They pin the DEFAULT (`npt:0:1`):
  // the t=1.4s frame is gated OUT of the resting state and only a play click
  // reveals it. Here the block names `npt:0:2` instead — so the very same frame
  // must be on screen AT REST, with no click at all. That is the whole feature:
  // a recording whose first seconds are a banner + a reading pause no longer
  // rests on near-empty black; it rests on real, legible terminal content.
  it('a per-block poster renders a LATER frame at rest, with no play click', async () => {
    const container = mount(DEFAULT_POSTER_GOLDEN, { poster: 'npt:0:2' })

    // The poster reached the DOM as the data attribute the two client twins read.
    const mountPoint = container.querySelector('div.bp-asciicast') as HTMLElement | null
    expect(mountPoint!.dataset.castPoster, 'the block poster rides data-cast-poster').toBe(
      'npt:0:2',
    )

    const result = await hydratePortableDoc(container)
    expect(result.asciicast).toBe(1)

    // NO click anywhere in this test — the frame appears because the poster
    // snapshot is taken at t=2s, past the t=1.4s event.
    await vi.waitFor(
      () => {
        expect(
          terminalText(container),
          'the npt:0:2 poster snapshot already contains the t=1.4s frame',
        ).toContain(ADVANCE_FRAME)
      },
      { timeout: 5000, interval: 100 },
    )
    expect(terminalText(container)).toContain(POSTER_BASE)

    // Still PAUSED: the start overlay is up, so the content above is the poster
    // snapshot, not playback that somehow began on its own.
    expect(
      container.querySelector('.ap-overlay-start'),
      'the player is still paused — this is the poster, not autoplay',
    ).not.toBeNull()
  })
})

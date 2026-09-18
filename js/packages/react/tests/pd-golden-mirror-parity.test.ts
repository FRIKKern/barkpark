// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// THE MIRROR-FRESHNESS PREDICATE (row rpu-backlog-field-embed-coverage).
//
// `mix barkpark.portable_doc.gen_pd_parity` mints EVERY golden fixture TWICE —
// once into the Elixir mirror `api/test/support/fixtures/pd-parity/` and once
// into the JS mirror `js/packages/react/tests/fixtures/pd-golden/`
// (gen_pd_parity.ex `@js_dir`). Until this file, NOTHING compared them:
//
//   • `scripts/pd-parity-completeness.sh` reads the ELIXIR mirror only
//     (`FIXTURES="$ROOT/api/test/support/fixtures/pd-parity"`). A type minted
//     there and never mirrored into JS is, to that guard, fully covered.
//   • `PortableDoc.parity.test.tsx` reads the JS mirror only, and its coverage
//     floor was the pinned literal `>= 46` while 65 fixtures were on disk — a
//     floor 19 behind the corpus can never red on a missing mirror entry.
//
// So "the golden harness (both mirrors) covers them freshness-green" — the
// property this row's criterion 2 asks for — was UNMEASURED. This file measures
// it, and measures it as a PREDICATE, not an enumeration: there is no list of
// type names here to keep up to date. The expected set IS the Elixir mirror, so
// a FIFTEENTH field type (or a fifty-first anything) minted on the Elixir side
// and not mirrored REDs here on the day it lands, with no edit to this file.
//
// ── PRECONDITION, NOT A SKIP ────────────────────────────────────────────────
// An absent or tiny Elixir mirror is the one way this comparison could pass
// having compared nothing (an empty set equals an empty set). It is asserted,
// loudly, before any comparison runs — a missing upstream dir FAILS here rather
// than quietly reading as all-clear.
//
// ── KNOWN LIMIT, stated so nobody reads more into the green than is there ────
// turbo's `test` task inputs (js/turbo.json) are rooted at `js/` and CANNOT
// name a path under `api/`. A PR that changes ONLY the Elixir mirror leaves
// every react `test` input byte-identical, so turbo replays a cached green and
// this guard does not execute. It fires on every run that is not a cache hit —
// which is every PR that touches js/ at all, and every cold CI run. Closing the
// cache hole needs an UNCACHED step in .github/workflows/js-tests.yml, which is
// the gates lane's fence; filed separately rather than smuggled in here.

import { describe, it, expect } from 'vitest'
import { existsSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { ELIXIR_MIRROR, JS_MIRROR, goldenNames } from './support/pd-golden-mirrors'

describe('pd-golden mirror freshness (JS mirror ≡ Elixir mirror)', () => {
  // ── the precondition ──────────────────────────────────────────────────────
  it('PRECONDITION: the Elixir mirror is present and non-trivially populated', () => {
    expect(
      existsSync(ELIXIR_MIRROR),
      `the canonical mint is missing at ${ELIXIR_MIRROR} — this comparison would be vacuous`,
    ).toBe(true)
    // 30 is a deliberate FLOOR-on-the-instrument, not a corpus pin: it only has
    // to be low enough never to need editing and high enough that an emptied or
    // half-written dir cannot pass. The corpus size itself is asserted by
    // equality below, where it needs no literal at all.
    expect(goldenNames(ELIXIR_MIRROR).length).toBeGreaterThan(30)
  })

  it('PRECONDITION: the JS mirror is present and non-trivially populated', () => {
    expect(existsSync(JS_MIRROR), `the JS mirror is missing at ${JS_MIRROR}`).toBe(true)
    expect(goldenNames(JS_MIRROR).length).toBeGreaterThan(30)
  })

  // ── the predicate ─────────────────────────────────────────────────────────
  it('the two mirrors hold the SAME fixture set (both directions)', () => {
    const elixir = goldenNames(ELIXIR_MIRROR)
    const js = goldenNames(JS_MIRROR)
    const missingInJs = elixir.filter((f) => !js.includes(f))
    const extraInJs = js.filter((f) => !elixir.includes(f))
    expect(
      missingInJs,
      `minted into api/test/support/fixtures/pd-parity/ but NEVER mirrored into ` +
        `js/packages/react/tests/fixtures/pd-golden/ — re-run ` +
        `\`MIX_ENV=test mix barkpark.portable_doc.gen_pd_parity\` and commit BOTH mirrors`,
    ).toEqual([])
    expect(
      extraInJs,
      `present in the JS mirror with no Elixir counterpart — the type was removed ` +
        `from compose.ex, or the fixture was hand-authored instead of minted`,
    ).toEqual([])
  })

  it('every mirrored fixture is byte-identical across the two mirrors', () => {
    const diverged: string[] = []
    for (const name of goldenNames(ELIXIR_MIRROR)) {
      const a = join(ELIXIR_MIRROR, name)
      const b = join(JS_MIRROR, name)
      if (!existsSync(b)) continue // set equality is the assertion above; do not double-report
      if (readFileSync(a, 'utf8') !== readFileSync(b, 'utf8')) diverged.push(name)
    }
    expect(
      diverged,
      `the JS mirror is STALE for these fixtures — the Elixir emitter moved and only ` +
        `one mirror was regenerated; re-mint and commit both`,
    ).toEqual([])
  })
})

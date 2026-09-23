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
// ── THE CACHE HOLE IS CLOSED (task-0fb4f5e1ef4a1237) ─────────────────────────
// This file used to carry a KNOWN LIMIT here saying this guard COULD NOT fire
// on an Elixir-only mirror change. The premise under it is real and was
// re-verified: turbo's `test` task inputs (js/turbo.json) are rooted at `js/`
// and cannot name a path under `api/`, so such a change does not enter the task
// hash at all. MEASURED locally with a warm cache — adding one file under
// api/test/support/fixtures/pd-parity/ left @barkpark/react:test at the SAME
// hash (26dbb9de8e5296ec), "cache hit, replaying logs", "40 passed", exit 0,
// having executed nothing.
//
// The caveat's CONCLUSION was too strong, though. A replay needs a cache entry
// to exist, and whether CI restores one carrying that hash is not decided by
// the change. MEASURED on CI with the same api-only control commit: the runner
// computed the identical hash 26dbb9de8e5296ec, did NOT have it in the restored
// cache, executed the task, and js-tests went FAILURE. So before this workflow
// step the real state was WORSE than "cannot fire": whether this guard judged
// an Elixir-only change was decided by CI cache weather. A gate defeatable by a
// cache hit is not a gate.
//
// .github/workflows/js-tests.yml now runs this file in an UNCACHED step of its
// own ("pd-golden mirror freshness"), ahead of every turbo step, in addition to
// the cached `test` task. The workflow already triggered on
// `api/test/support/fixtures/pd-parity/**`; what was missing was a RUN, not a
// trigger. MEASURED: with that step in place the same control commit reds
// js-tests AT THAT STEP (step 12), before Build or Test execute at all. The
// cached `test` task may still replay on such a PR — that is fine; the uncached
// step is what carries the verdict now.

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

/**
 * Error-vocabulary parity for the MOBILE sheet block — the sixth mirror.
 *
 * `Barkpark.Plugins.Sheets.Engine.error_values/0`
 * (@canonical capability:engine-error-vocabulary) is the single owner of the
 * "#…!" strings a computed cell can hold. Six surfaces mirror it. Five were
 * held equal by a named test; this one was not:
 *
 *   1. api/lib/barkpark/portable_doc/render/walk.ex          — sheets_parity_test
 *   2. api/lib/barkpark_web/live/studio/sheet_grid/cells.ex  — sheets_parity_test
 *   3. web/lib/sheets.ts (ENGINE_ERRORS)                     — web/__tests__/sheets-errors.test.ts
 *   4. internal/pdrender                                     — Go golden
 *   5. js/packages/react/src/blocks/sheet.ts (ERROR_VALUES)  — js/packages/react/tests/sheet-error-vocabulary.test.ts (#15404)
 *   6. apps/mobile/src/papers/portabledoc/blocks/sheet.tsx   — THIS FILE
 *
 * The gap was not hypothetical by the time this file was written. #15374 added
 * `#NAME?` engine-side; the mobile set kept its seven strings, so a `#NAME?`
 * cell rendered as ordinary text on mobile while every other surface painted it
 * red + bold. That is the drift this guard both repairs and forecloses.
 *
 * The lock is the SAME engine-generated fixture the web and react mirrors read:
 * `web/__tests__/fixtures/engine-errors.json`, which
 * `api/test/barkpark/sheets_parity_test.exs` asserts equals
 * `Engine.error_values/0`. Reading that shared file rather than copying it into
 * apps/mobile is deliberate — a copy would be a SEVENTH mirror needing its own
 * guard, whereas this read adds none, and a third hand-written list is the very
 * defect this file exists to remove.
 *
 * RED IN BOTH DIRECTIONS by construction, because the equality is a set
 * equality and not a subset check: a code added engine-side lands in the
 * fixture and reds this suite until `sheet.tsx` learns it, AND a code added to
 * `sheet.tsx` alone reds it too. Neither side can move by itself.
 *
 * mobile.yml's paths block carries the fixture path so an engine-side
 * vocabulary bump RUNS this gate rather than leaving it stale-green on a
 * mobile PR that lands weeks later.
 *
 * Run: `pnpm --filter barkpark-mobile test sheetErrorVocabulary`.
 */
import { readFileSync } from 'node:fs'
import { join } from 'node:path'

import { ERROR_VALUES } from '../src/papers/portabledoc/blocks/sheet'

// __tests__/ -> mobile/ -> apps/ -> repo root
const FIXTURE_PATH = join(__dirname, '..', '..', '..', 'web', '__tests__', 'fixtures', 'engine-errors.json')

const fixture: string[] = JSON.parse(readFileSync(FIXTURE_PATH, 'utf8'))

describe('mobile sheet ERROR_VALUES mirrors the engine vocabulary', () => {
  it('the shared engine fixture is present and non-empty', () => {
    // Guards the read itself: a moved or renamed fixture must red HERE rather
    // than silently leave the equality below comparing against nothing.
    expect(Array.isArray(fixture)).toBe(true)
    expect(fixture.length).toBeGreaterThan(0)
    expect(fixture.every((c) => typeof c === 'string' && c.startsWith('#'))).toBe(true)
  })

  it('the imported set is the real renderer set, not an empty module', () => {
    // If the import ever resolves to undefined or an empty Set, the equality
    // below would compare [] to [] only if the fixture were empty too — the
    // check above covers that — but an empty Set against a full fixture must
    // fail LOUDLY here with a readable message rather than as a diff.
    expect(ERROR_VALUES).toBeInstanceOf(Set)
    expect(ERROR_VALUES.size).toBeGreaterThan(0)
  })

  it('ERROR_VALUES equals the engine fixture exactly (no one-sided drift)', () => {
    expect([...ERROR_VALUES].sort()).toEqual([...fixture].sort())
  })

  it('names the codes missing from the mobile set (fixture -> mobile direction)', () => {
    const missing = fixture.filter((c) => !ERROR_VALUES.has(c))
    expect(`missing from apps/mobile sheet.tsx: ${missing.join(', ') || '(none)'}`).toBe(
      'missing from apps/mobile sheet.tsx: (none)',
    )
  })

  it('names the codes the mobile set invented (mobile -> fixture direction)', () => {
    const extra = [...ERROR_VALUES].filter((c) => !fixture.includes(c))
    expect(`not in the engine fixture: ${extra.join(', ') || '(none)'}`).toBe('not in the engine fixture: (none)')
  })

  it('carries #NAME?, the code #15374 added engine-side', () => {
    // The concrete drift this row was filed for. Pinned by name so a future
    // regression is legible in the failure line, not just in a set diff.
    expect(fixture).toContain('#NAME?')
    expect(ERROR_VALUES.has('#NAME?')).toBe(true)
  })
})

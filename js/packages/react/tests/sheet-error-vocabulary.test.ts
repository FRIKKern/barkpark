/**
 * Error-vocabulary parity for the REACT sheet emitter.
 *
 * `Barkpark.Plugins.Sheets.Engine.error_values/0`
 * (@canonical capability:engine-error-vocabulary) is the single owner of the
 * "#…!" strings a computed cell can hold. Six surfaces mirror it:
 *
 *   1. api/lib/barkpark/portable_doc/render/walk.ex        — sheets_parity_test
 *   2. api/lib/barkpark_web/live/studio/sheet_grid/cells.ex — sheets_parity_test
 *   3. web/lib/sheets.ts (ENGINE_ERRORS)                   — web/__tests__/sheets-errors.test.ts
 *   4. internal/pdrender                                   — Go golden
 *   5. js/packages/react/src/blocks/sheet.ts (ERROR_VALUES) — THIS FILE
 *   6. apps/mobile/src/papers/portabledoc/blocks/sheet.tsx  — apps/mobile/__tests__/sheetErrorVocabulary.test.ts (added #15473)
 *
 * A GUARD IS NOT A GATE. This file fired correctly on the very next
 * vocabulary bump (#15374 added `#NAME?`) and main merged past it anyway —
 * js-tests.yml publishes no context in .github/required-checks.json, so its
 * red cannot block. See the comment above ERROR_VALUES in src/blocks/sheet.ts.
 *
 * The lock is the SAME fixture the web mirror consumes:
 * `web/__tests__/fixtures/engine-errors.json`, which
 * `api/test/barkpark/sheets_parity_test.exs` asserts equals
 * `Engine.error_values/0`. Reading that shared file instead of copying it into
 * this package is deliberate — a copy would be a SIXTH mirror needing its own
 * guard, whereas this read adds none. So: a code added engine-side lands in the
 * fixture and reds this suite until `sheet.ts` learns it; a code added to
 * `sheet.ts` alone reds it too. Neither side can move on its own.
 *
 * Run: `pnpm --filter @barkpark/react test`.
 */

import { describe, expect, test } from 'vitest'
import { readFileSync } from 'node:fs'
import { ERROR_VALUES } from '../src/blocks/sheet'

// tests/ -> react/ -> packages/ -> js/ -> repo root
const FIXTURE_URL = new URL(
  '../../../../web/__tests__/fixtures/engine-errors.json',
  import.meta.url,
)

const fixture: string[] = JSON.parse(readFileSync(FIXTURE_URL, 'utf8'))

describe('react sheet ERROR_VALUES mirrors the engine vocabulary', () => {
  test('the shared engine fixture is present and non-empty', () => {
    // Guards the read itself: a moved/renamed fixture must red HERE rather
    // than silently leave the deep-equality below comparing against nothing.
    expect(Array.isArray(fixture)).toBe(true)
    expect(fixture.length).toBeGreaterThan(0)
    expect(fixture.every((c) => typeof c === 'string' && c.startsWith('#'))).toBe(true)
  })

  test('ERROR_VALUES equals the engine fixture exactly (no one-sided drift)', () => {
    expect([...ERROR_VALUES].sort()).toEqual([...fixture].sort())
  })

  test('every engine code is recognised by the emitter set', () => {
    for (const code of fixture) {
      expect(ERROR_VALUES.has(code)).toBe(true)
    }
  })

  test('ordinary values are never engine errors', () => {
    for (const v of ['', 'hello', '42', '#HELLO!', '#NAME', 'NUM!', '  #REF!']) {
      expect(ERROR_VALUES.has(v)).toBe(false)
    }
  })
})

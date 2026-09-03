/**
 * The mobile sheet block mirrors the engine's error vocabulary by hand
 * (src/papers/portabledoc/blocks/sheet.tsx ERROR_VALUES). The Elixir side
 * locks the web mirror and the react mirror to ONE fixture,
 * web/__tests__/fixtures/engine-errors.json (sheets_parity_test.exs "errors
 * axis single-source"; js/packages/react/tests/sheet-error-vocabulary.test.ts).
 * Mobile was the mirror nobody locked (task-6f18e71a351f8081, C): #15521 shipped
 * because the react copy had missed the eighth code and nothing said so.
 *
 * Same contract as the react test: the fixture is present and non-empty, the
 * set equals it exactly (no one-sided drift either way), and ordinary values
 * are never errors.
 */
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { ERROR_VALUES } from '../src/papers/portabledoc/blocks/sheet'

const FIXTURE = join(__dirname, '..', '..', '..', 'web', '__tests__', 'fixtures', 'engine-errors.json')

describe('mobile sheet ERROR_VALUES mirrors the engine vocabulary', () => {
  const engine: string[] = JSON.parse(readFileSync(FIXTURE, 'utf8'))

  test('the shared engine fixture is present and non-empty', () => {
    expect(Array.isArray(engine)).toBe(true)
    expect(engine.length).toBeGreaterThan(0)
  })

  test('ERROR_VALUES equals the engine fixture exactly (no one-sided drift)', () => {
    expect([...ERROR_VALUES].sort()).toEqual([...engine].sort())
  })

  test('every engine code is recognised by the mobile set', () => {
    for (const code of engine) expect(ERROR_VALUES.has(code)).toBe(true)
  })

  test('ordinary values are never engine errors', () => {
    for (const v of ['', '0', 'abc', '#hashtag', 'N/A', 'REF']) expect(ERROR_VALUES.has(v)).toBe(false)
  })
})

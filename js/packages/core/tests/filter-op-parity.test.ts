// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

/**
 * The JS half of the filter-operator lock.
 *
 * `Barkpark.Content.Query.valid_filter_ops/0` (api/lib/barkpark/content/query.ex)
 * owns the PUBLIC filter vocabulary — `QueryController` derives its door from it
 * at compile time, so that list IS the wire form. This package cannot call it,
 * so `FILTER_OPS` in src/types.ts mirrors it and `FilterOp` is derived from that
 * array.
 *
 * `api/test/fixtures/filter_ops.json` is the ONE shared artifact. The Elixir
 * side asserts the fixture equals `valid_filter_ops/0`
 * (api/test/barkpark/content/filter_ops_fixture_parity_test.exs); this file
 * asserts `FILTER_OPS` equals the same fixture. Reading the file rather than
 * copying it is the point — a copy would be a third list needing its own guard.
 *
 * WHY THE TYPE IS DERIVED, NOT SPELLED. A TypeScript union is erased at
 * runtime, so a test can only compare a runtime array. If `FilterOp` were
 * hand-written beside `FILTER_OPS`, this file would be comparing a hand-copy to
 * a hand-copy: the array could learn an op the union still refused and stay
 * green. `type FilterOp = (typeof FILTER_OPS)[number]` is what makes the
 * assertion below cover the compile-time surface too.
 *
 * THE DEFECT THIS EXISTS FOR: `is` was in `@valid_filter_ops` and absent from
 * the union. Both sides had tests; nothing compared them, so a typed caller
 * could not express a filter the API accepts and validates.
 */

import { describe, expect, test } from 'vitest'
import { readFileSync } from 'node:fs'
import { FILTER_OPS, type FilterOp } from '../src/types'
import { makeFilterExpression, buildQueryString } from '../src/filter-builder'
import { BarkparkValidationError } from '../src/errors'

// tests/ -> core/ -> packages/ -> js/ -> repo root
const FIXTURE_URL = new URL('../../../../api/test/fixtures/filter_ops.json', import.meta.url)

const fixture: string[] = JSON.parse(readFileSync(FIXTURE_URL, 'utf8'))

describe('FILTER_OPS mirrors the Elixir filter vocabulary', () => {
  test('the shared fixture is present and non-empty', () => {
    // Guards the read itself: a moved or renamed fixture must red HERE rather
    // than leave the equality below comparing against nothing.
    expect(Array.isArray(fixture)).toBe(true)
    expect(fixture.length).toBeGreaterThan(0)
    expect(fixture.every((op) => typeof op === 'string' && op.length > 0)).toBe(true)
  })

  test('FILTER_OPS equals the shared fixture exactly, in order', () => {
    // Order too, not just membership: the fixture is regenerated straight from
    // `@valid_filter_ops`, and a same-set-different-order diff is the cheapest
    // signal that someone edited one side by hand.
    expect([...FILTER_OPS]).toEqual(fixture)
  })

  test('every Elixir op is expressible through the builder', () => {
    // The criterion the union failed: the API accepts fourteen ops and the SDK
    // typed thirteen. This drives each one through the runtime guard.
    for (const op of fixture) {
      const value = op === 'in' || op === 'nin' ? ['a'] : op === 'is' ? 'null' : 'x'
      expect(() => makeFilterExpression('field', op as FilterOp, value)).not.toThrow()
    }
  })

  test('the builder-only spellings stay OUT — they have no wire form', () => {
    // `starts_with` / `not_starts_with` are `@doc_id_only_ops`: clauses on the
    // doc_id/_id column only, and QueryController's door refuses them (pinned
    // Elixir-side by filter_ops_test.exs "the door stays narrower than the
    // builder"). Typing them here would bless a filter every HTTP caller gets a
    // 400 for.
    for (const builderOnly of ['starts_with', 'not_starts_with']) {
      expect(fixture).not.toContain(builderOnly)
      expect(() =>
        makeFilterExpression('doc_id', builderOnly as unknown as FilterOp, 'x'),
      ).toThrow(BarkparkValidationError)
    }
  })
})

describe("the `is` operator serialises to the wire form the API expects", () => {
  test("`is` builds `filter[<field>][is]=null` / `=notnull`", () => {
    // api-v1.md §4: "`is` (`null`/`notnull`)". query.ex refuses any other value
    // before the query is built.
    const qs = buildQueryString({
      filters: [makeFilterExpression('subtitle', 'is', 'null')],
    })
    expect(decodeURIComponent(qs)).toBe('filter[subtitle][is]=null')

    const notnull = buildQueryString({
      filters: [makeFilterExpression('subtitle', 'is', 'notnull')],
    })
    expect(decodeURIComponent(notnull)).toBe('filter[subtitle][is]=notnull')
  })

  test('`eq`/`neq` with a null VALUE keep producing the same wire form', () => {
    // The pre-existing sugar. Adding the explicit `is` spelling must not change
    // what the null-value shorthand emits.
    expect(
      decodeURIComponent(buildQueryString({ filters: [makeFilterExpression('a', 'eq', null)] })),
    ).toBe('filter[a][is]=null')
    expect(
      decodeURIComponent(buildQueryString({ filters: [makeFilterExpression('a', 'neq', null)] })),
    ).toBe('filter[a][is]=notnull')
  })

  test('`is` refuses any value other than the two literals', () => {
    for (const bad of [null, true, 1, 'NULL', 'nope', new Date()]) {
      expect(() => makeFilterExpression('a', 'is', bad as never)).toThrow(BarkparkValidationError)
    }
  })
})

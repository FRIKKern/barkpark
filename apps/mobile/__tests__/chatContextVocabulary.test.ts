/**
 * THE MOBILE HALF of the chat context band vocabulary lock
 * (task-b6b9a4424d653937).
 *
 * The connection band ships on two surfaces from one conceptual contract, and
 * until this file the contract existed as TWO independent hand-maintained
 * copies:
 *
 *   Elixir (CANONICAL) — api/lib/barkpark/studio_chat/context_identity.ex
 *     unset_marker/0, unknown_marker/0, no_repo_marker/0, server_local_marker/0,
 *     field_names/0
 *   Mobile             — apps/mobile/src/chat/context.ts
 *     ABSENT_UNSET, ABSENT_UNKNOWN, ABSENT_NO_REPO, ABSENT_SERVER_LOCAL,
 *     CONTEXT_FIELD_NAMES
 *
 * Both halves were well tested INTERNALLY — Studio's band in #15430, mobile's in
 * #15439 — and neither test could see the other side. Nothing failed when a
 * marker was reworded on one surface only, or the six fields reordered on one
 * surface only; the users would just see two different bands describing the same
 * session.
 *
 * The lock is ONE checked-in fixture,
 * `api/test/support/fixtures/chat_context_band_vocabulary.json`, read by BOTH
 * this file and `api/test/barkpark/studio_chat/context_identity_vocabulary_test.exs`.
 * Reading the SAME bytes rather than copying them into apps/mobile is the whole
 * point: a copy would be a third hand-maintained list needing its own guard,
 * which is the defect, not the fix. Same shape as the fold-label lock
 * (`chat_fold_labels.json`, PRs #15434 and #15457).
 *
 * RED IN BOTH DIRECTIONS by construction: a marker changed in
 * `context_identity.ex` alone reds the Elixir file, the SAME marker changed in
 * `context.ts` alone reds this file.
 *
 * ORDER IS PART OF THE CONTRACT. CONTEXT_FIELD_NAMES is the PAINT order, so the
 * comparison below is an array equality — never a set, never sorted. A sorted
 * comparison would wave through exactly the reorder this file exists to catch,
 * and a reordered band is a visible defect on one surface only.
 *
 * Run: `pnpm --filter barkpark-mobile test chatContextVocabulary`.
 */
import { readFileSync } from 'node:fs'
import { join } from 'node:path'

import {
  ABSENT_NO_REPO,
  ABSENT_SERVER_LOCAL,
  ABSENT_UNKNOWN,
  ABSENT_UNSET,
  CONTEXT_FIELD_NAMES,
} from '../src/chat/context'

// __tests__/ -> mobile/ -> apps/ -> repo root
const FIXTURE_PATH = join(
  __dirname,
  '..',
  '..',
  '..',
  'api',
  'test',
  'support',
  'fixtures',
  'chat_context_band_vocabulary.json',
)

interface Vocabulary {
  markers: { unset: string; unknown: string; no_repo: string; server_local: string }
  field_names: string[]
}

const fixture: Vocabulary = JSON.parse(readFileSync(FIXTURE_PATH, 'utf8'))

describe('the shared vocabulary fixture is readable and populated', () => {
  // NON-VACUITY. Every equality below is only as good as the fixture actually
  // holding values. A moved, renamed or emptied fixture must red HERE rather
  // than leave the locks comparing undefined against undefined.
  it('carries all four markers, each a non-empty parenthesised string', () => {
    for (const key of ['unset', 'unknown', 'no_repo', 'server_local'] as const) {
      const value = fixture.markers?.[key]
      expect(typeof value).toBe('string')
      expect(value.length).toBeGreaterThan(0)
      // Parenthesised is what makes a marker unmistakable for a host name,
      // slug, URL or path — no real value is ever wrapped this way.
      expect(value.startsWith('(') && value.endsWith(')')).toBe(true)
    }
  })

  it('carries exactly six field names, all non-empty strings', () => {
    expect(Array.isArray(fixture.field_names)).toBe(true)
    expect(fixture.field_names).toHaveLength(6)
    for (const name of fixture.field_names) {
      expect(typeof name).toBe('string')
      expect(name.length).toBeGreaterThan(0)
    }
  })

  it('keeps the four markers distinct from one another', () => {
    // Law 2 of the band: a reader must tell "nothing is set" from "nobody can
    // tell" from "the server runs it" at a glance. Two markers collapsing to
    // one string destroys that on BOTH surfaces at once.
    const values = Object.values(fixture.markers)
    expect(new Set(values).size).toBe(values.length)
  })
})

describe('context.ts markers equal the shared fixture', () => {
  // A table, so a drift names the export that moved instead of printing a
  // six-key object diff you have to hunt through.
  const cases: [string, string, string, keyof Vocabulary['markers']][] = [
    ['ABSENT_UNSET', ABSENT_UNSET, 'unset_marker/0', 'unset'],
    ['ABSENT_UNKNOWN', ABSENT_UNKNOWN, 'unknown_marker/0', 'unknown'],
    ['ABSENT_NO_REPO', ABSENT_NO_REPO, 'no_repo_marker/0', 'no_repo'],
    ['ABSENT_SERVER_LOCAL', ABSENT_SERVER_LOCAL, 'server_local_marker/0', 'server_local'],
  ]

  for (const [exportName, actual, elixirFn, fixtureKey] of cases) {
    it(`${exportName} equals fixture markers.${fixtureKey}`, () => {
      const expected = fixture.markers[fixtureKey]
      // The label rides INTO the compared value so the jest diff names the
      // export and its Elixir owner without any extra message plumbing.
      expect(`${exportName} (mirrors ${elixirFn}) = ${actual}`).toBe(
        `${exportName} (mirrors ${elixirFn}) = ${expected}`,
      )
      expect(actual).toBe(expected)
    })
  }
})

describe('CONTEXT_FIELD_NAMES equals the shared fixture IN PAINT ORDER', () => {
  it('matches one-for-one, in order', () => {
    // Array equality on purpose. ContextIdentity.field_names/0 is pinned to the
    // same list on the Elixir side, so neither surface can reorder alone.
    expect(CONTEXT_FIELD_NAMES).toEqual(fixture.field_names)
  })

  it('is order-sensitive — a permutation must NOT satisfy the lock', () => {
    // The guard's own non-vacuity check: proves the equality above cannot have
    // quietly become a set or sorted comparison, which would wave through the
    // exact defect this file exists to catch.
    const [a, b, ...rest] = fixture.field_names
    const permuted = [b, a, ...rest]
    expect(CONTEXT_FIELD_NAMES).not.toEqual(permuted)
  })
})

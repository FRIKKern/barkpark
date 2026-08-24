/**
 * Tests for the REAL corpus walk (`src/lib/paginate.ts`) that `allDocs()` uses
 * (task-669e7706cb86cb3a). `paginate.ts` imports nothing, so `node --test`
 * loads the SHIPPED code directly — no mirror, no mock of the thing under
 * test. That matters here: the finder-contract CI job runs this glob with no
 * `npm ci`, so a test that imported `bp.ts` (and through it `@barkpark/core`)
 * could not run at all.
 *
 * Ported from `web/__tests__/paginate.test.ts` (PR #13340) and
 * `apps/hundesteder/__tests__/paginate.test.ts` (PR #13316) — same law, same
 * mutant set. This is the fifth instance of the fix.
 *
 * The defect class under pin: `allDocs()` issued ONE query with a fixed
 * `.limit(500)` and no offset. Its two callers both inherited the truncation —
 * `browseSeed()` baked a short search seed, and `getStaticPaths()` generated
 * NO PAGE for a doc past #500, so the deployed site 404s on it under a green
 * build. NAMED MUTANTS each test kills:
 *   • single-page-only          → the multi-page test reds (rows lost)
 *   • advance-by-filtered-count → the raw-advance test reds (cursor stalls)
 *   • no-cap                    → the cap test never terminates / reds
 *   • swallow-failed-page       → the mid-walk failure test reds (no flag)
 *   • silent-truncation         → the warning test reds (nothing said)
 *   • unwired-allDocs           → the source test reds (bp.ts kept its
 *                                 single-shot `.limit(500).find()`)
 */

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import {
  collectAllPages,
  collectCorpus,
  CORPUS_PAGE_LIMIT,
  CORPUS_MAX_PAGES,
} from './paginate.ts'

/** A fake corpus served in pages of `limit`, counting the calls. */
function corpusFetcher(total: number, calls: Array<[number, number]>) {
  const rows = Array.from({ length: total }, (_, i) => ({ i }))
  return async (limit: number, offset: number): Promise<Array<{ i: number }> | null> => {
    calls.push([limit, offset])
    return rows.slice(offset, offset + limit)
  }
}

test('walks every page and terminates on the short page', async () => {
  const calls: Array<[number, number]> = []
  const out = await collectAllPages(corpusFetcher(118, calls), { limit: 50, maxPages: 20 })
  assert.equal(out.rows.length, 118, 'every row must survive the walk')
  assert.equal(out.truncated, undefined, 'a clean exhaustion carries no truncation flag')
  assert.deepEqual(calls, [
    [50, 0],
    [50, 50],
    [50, 100],
  ])
})

test('THE ROW: a corpus past the old fixed 500 cap drains across pages', async () => {
  // The exact defect: `.limit(500).find()` returned 500 of these and the build
  // shipped, silently, missing 813 documents.
  const calls: Array<[number, number]> = []
  const out = await collectCorpus(corpusFetcher(1313, calls), () => {})
  assert.equal(out.rows.length, 1313, 'all 1313 docs — not the first 500, not the first 1000')
  assert.equal(out.truncated, undefined, 'a fully drained corpus is not truncated')
  assert.ok(calls.length > 1, 'more than one page must have been requested')
  assert.equal(calls[0][0], CORPUS_PAGE_LIMIT, 'the first page asks for the clamped page size')
  assert.equal(calls[1][1], CORPUS_PAGE_LIMIT, 'the second page starts where the first ended')
})

test('the cursor advances by the RAW page length, never a filtered count', async () => {
  const calls: Array<[number, number]> = []
  await collectAllPages(corpusFetcher(25, calls), { limit: 10, maxPages: 20 })
  assert.deepEqual(
    calls.map(([, offset]) => offset),
    [0, 10, 20],
    'a stalled cursor would re-request offset 0 forever',
  )
})

test('the cap bounds the walk and says so out loud', async () => {
  // An upstream that ALWAYS returns a full page — the walk must stop.
  const always = async (limit: number): Promise<Array<{ i: number }>> =>
    Array.from({ length: limit }, (_, i) => ({ i }))
  const out = await collectAllPages(always, { limit: 10, maxPages: 3 })
  assert.equal(out.rows.length, 30)
  assert.equal(out.truncated, 'cap', 'hitting the cap must be reported, never absorbed')
})

test('a mid-walk failed page returns partial truth, flagged', async () => {
  const fetchPage = async (limit: number, offset: number): Promise<Array<{ i: number }> | null> =>
    offset === 0 ? Array.from({ length: limit }, (_, i) => ({ i })) : null
  const out = await collectAllPages(fetchPage, { limit: 10, maxPages: 5 })
  assert.equal(out.rows.length, 10, 'what was collected survives')
  assert.equal(out.truncated, 'failed_page', 'the partial result must disclaim itself')
})

test('a failed FIRST page degrades to empty with no truncation flag', async () => {
  const out = await collectAllPages(async () => null, { limit: 10, maxPages: 5 })
  assert.deepEqual(out.rows, [])
  assert.equal(out.truncated, undefined, 'there is no partial truth to disclaim yet')
})

test('collectCorpus warns loudly on a truncated corpus, and is silent on a whole one', async () => {
  const warnings: string[] = []
  const always = async (limit: number): Promise<Array<{ i: number }>> =>
    Array.from({ length: limit }, (_, i) => ({ i }))

  await collectCorpus(always, (m) => warnings.push(m))
  assert.equal(warnings.length, 1, 'a capped walk must produce exactly one build-log warning')
  assert.match(warnings[0], /cap/, 'the warning names WHICH truncation happened')
  assert.match(warnings[0], /INCOMPLETE/, 'the warning says the seed is incomplete, in the clear')
  assert.equal(
    warnings[0].includes(String(CORPUS_PAGE_LIMIT * CORPUS_MAX_PAGES)),
    true,
    'the warning carries the count it DID collect, so the log is actionable',
  )

  // NEGATIVE ARM: a corpus that drains cleanly must not cry wolf.
  const quiet: string[] = []
  await collectCorpus(corpusFetcher(7, []), (m) => quiet.push(m))
  assert.deepEqual(quiet, [], 'a complete corpus must produce NO warning')
})

test('bp.ts allDocs() is wired to the walk and no longer single-shots', () => {
  // `bp.ts` imports `@barkpark/core` and evaluates `required(...)` at module
  // load, so it cannot be imported by this dep-free job — the same reason
  // `templates/search-starter/token-guard.test.mjs` asserts its build guard
  // from SOURCE. Without this assertion every test above could pass while
  // `allDocs()` kept its single-shot call, which is the whole defect.
  const raw = readFileSync(fileURLToPath(new URL('./bp.ts', import.meta.url)), 'utf8')
  // Strip comments before asserting: the doc comment on `allDocs()` NAMES the
  // retired `.limit(500).find()` call, and a source assertion that cannot tell
  // prose from code would red on a correct file (it did, first run).
  const src = raw.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^[ \t]*\/\/.*$/gm, '')
  const allDocsBody = src.slice(src.indexOf('export async function allDocs'))
  assert.ok(
    allDocsBody.startsWith('export async function allDocs'),
    'allDocs() must still be exported from bp.ts',
  )
  assert.match(allDocsBody, /collectCorpus</, 'allDocs() must walk the corpus via collectCorpus')
  assert.match(allDocsBody, /\.offset\(offset\)/, 'the walk must pass an advancing offset')
  assert.doesNotMatch(
    src,
    /\.limit\(500\)\.find\(\)/,
    'the single-shot .limit(500).find() must be gone from bp.ts entirely',
  )
})

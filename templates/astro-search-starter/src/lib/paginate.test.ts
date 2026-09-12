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
 *
 * THE SECOND DEFECT (task-a5b10e7a686e37bb), ported from
 * `web/__tests__/paginate.test.ts` (PR #13657): the short-page inference is
 * only sound while the server honours the requested `limit`, and it does not —
 * it clamps to 1000. Everything below the `THE SECOND DEFECT` banner pins the
 * clamp, the exact `hasMore`/`nextOffset` termination, and the `no_advance`
 * state. NAMED MUTANTS those add:
 *   • no-clamp                  → the clamp test reds (1000 of 2500 rows)
 *   • ignore-hasMore            → the full-page-hasMore:false test reds (2 calls)
 *   • ignore-nextOffset         → the cursor test reds ([0, 2] not [0, 7])
 *   • advance-past-the-clamp    → the no_advance test reds (40 calls, 'cap')
 *
 * WHY A LIMIT ABOVE 1000 AT ALL, when `collectCorpus` passes exactly
 * `CORPUS_PAGE_LIMIT = 1000`: because that coincidence is the ONLY thing that
 * made this edition safe. The guard is caller-INDEPENDENT, so the test that
 * proves it must ask for more than the ceiling — a test pinned at 1000 is
 * vacuous and would stay green through the exact edit (raising the constant)
 * that reintroduces the defect.
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
  SERVER_MAX_PAGE_LIMIT,
  __resetPaginateWarnings,
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

/* ── THE SECOND DEFECT: a server-clamped page read as an exhausted one ────── */

/**
 * A fake corpus behind a server that CLAMPS every page to `serverMax`, exactly
 * as the query controller does — the shape the old law could not survive.
 */
function clampingFetcher(total: number, serverMax: number, calls: Array<[number, number]>) {
  const rows = Array.from({ length: total }, (_, i) => ({ i }))
  return async (limit: number, offset: number): Promise<Array<{ i: number }> | null> => {
    calls.push([limit, offset])
    return rows.slice(offset, offset + Math.min(limit, serverMax))
  }
}

/** The law as this edition shipped it before task-a5b10e7a686e37bb, kept here
 * so the defect is DEMONSTRATED rather than asserted about. */
async function preFixLaw<T>(
  fetchPage: (limit: number, offset: number) => Promise<T[] | null>,
  { limit, maxPages }: { limit: number; maxPages: number },
): Promise<{ rows: T[]; truncated?: string }> {
  const rows: T[] = []
  let offset = 0
  for (let page = 0; page < maxPages; page++) {
    const batch = await fetchPage(limit, offset)
    if (batch === null) return page === 0 ? { rows } : { rows, truncated: 'failed_page' }
    rows.push(...batch)
    if (batch.length < limit) return { rows }
    offset += batch.length
  }
  return { rows, truncated: 'cap' }
}

test('THE DEFECT: the pre-fix law called a server-clamped page an exhausted one', async () => {
  const calls: Array<[number, number]> = []
  const out = await preFixLaw(clampingFetcher(2500, 1000, calls), { limit: 2500, maxPages: 40 })
  assert.equal(out.rows.length, 1000, 'a silent 60% prefix')
  assert.equal(out.truncated, undefined, 'and it reported CLEAN exhaustion')
  assert.equal(calls.length, 1, 'one request, then it stopped')
})

test('THE ROW: a limit past the ceiling is clamped, the walk warns, and the WHOLE corpus arrives', async () => {
  __resetPaginateWarnings()
  const warnings: string[] = []
  const orig = console.warn
  console.warn = (msg: string) => warnings.push(String(msg))
  const calls: Array<[number, number]> = []
  let out: { rows: unknown[]; truncated?: string }
  try {
    // CORPUS_PAGE_LIMIT is 1000 today; 2500 is the edit that used to be fatal.
    out = await collectAllPages(clampingFetcher(2500, 1000, calls), {
      limit: 2500,
      maxPages: 40,
    })
  } finally {
    console.warn = orig
  }
  // The no-clamp mutant reds here with 1000 — the silent prefix.
  assert.equal(out.rows.length, 2500, 'all 2500 docs — not the first 1000')
  assert.equal(out.truncated, undefined)
  assert.deepEqual(calls, [
    [1000, 0],
    [1000, 1000],
    [1000, 2000], // short page (500) — genuinely the end now
  ])
  assert.equal(warnings.length, 1, 'once per process, not once per page')
  assert.match(warnings[0], /2500/, 'the warning names what was asked for')
  assert.match(warnings[0], /1000/, 'and what was substituted')
})

test('a limit AT the ceiling is silent — the value collectCorpus already passes', async () => {
  __resetPaginateWarnings()
  const warnings: string[] = []
  const orig = console.warn
  console.warn = (msg: string) => warnings.push(String(msg))
  try {
    const out = await collectAllPages(clampingFetcher(2500, 1000, []), {
      limit: CORPUS_PAGE_LIMIT,
      maxPages: 40,
    })
    assert.equal(out.rows.length, 2500)
  } finally {
    console.warn = orig
  }
  assert.deepEqual(warnings, [], 'no false alarm on the correct call')
})

test('the ceiling matches the controller clamp, and the corpus page size rides it', () => {
  // A ceiling set ABOVE the server's clamp puts the silent-prefix defect back.
  assert.equal(SERVER_MAX_PAGE_LIMIT, 1000)
  assert.equal(CORPUS_PAGE_LIMIT, SERVER_MAX_PAGE_LIMIT)
})

test('hasMore:false ends the walk on a FULL page — no wasted probe request', async () => {
  let callCount = 0
  const out = await collectAllPages(
    async (limit: number) => {
      callCount++
      return { rows: Array.from({ length: limit }, (_, i) => ({ i })), hasMore: false }
    },
    { limit: 10, maxPages: 5 },
  )
  assert.equal(callCount, 1, 'ignore-hasMore reds here with 2')
  assert.equal(out.rows.length, 10)
  assert.equal(out.truncated, undefined, 'exhausted, and it KNOWS')
})

test('a SHORT page carrying hasMore:true keeps walking — length is no longer the oracle', async () => {
  const calls: Array<[number, number]> = []
  const out = await collectAllPages(
    async (limit: number, offset: number) => {
      calls.push([limit, offset])
      if (offset === 0) return { rows: [{ i: 0 }, { i: 1 }], hasMore: true, nextOffset: 2 }
      return { rows: [{ i: 2 }], hasMore: false }
    },
    { limit: 10, maxPages: 5 },
  )
  assert.equal(out.rows.length, 3, 'terminate-on-length reds here with 2')
  assert.equal(out.truncated, undefined)
  assert.equal(calls.length, 2)
})

test('nextOffset drives the cursor when the server supplies it', async () => {
  const calls: Array<[number, number]> = []
  await collectAllPages(
    async (limit: number, offset: number) => {
      calls.push([limit, offset])
      // A cursor that does NOT equal offset + rows.length: only a walk that
      // honours nextOffset lands on 7.
      if (offset === 0) return { rows: [{ i: 0 }, { i: 1 }], hasMore: true, nextOffset: 7 }
      return { rows: [], hasMore: false }
    },
    { limit: 10, maxPages: 5 },
  )
  assert.deepEqual(
    calls.map(([, offset]) => offset),
    [0, 7],
    'ignore-nextOffset reds with [0, 2]',
  )
})

test('hasMore with NO nextOffset stops and says no_advance — it never spins on the clamp', async () => {
  // The real shape past the 100_000 offset ceiling: the controller withholds
  // nextOffset because a further read re-serves this same page.
  let callCount = 0
  const out = await collectAllPages(
    async (limit: number) => {
      callCount++
      return { rows: Array.from({ length: limit }, (_, i) => ({ i })), hasMore: true }
    },
    { limit: 10, maxPages: 5 },
  )
  assert.equal(callCount, 1, 'advance-past-the-clamp reds here with 5')
  assert.equal(out.rows.length, 10, 'and would have collected 50 DUPLICATE rows')
  assert.equal(out.truncated, 'no_advance', 'partial truth, NAMED')
})

test('an EMPTY page claiming hasMore cannot loop forever', async () => {
  let callCount = 0
  const out = await collectAllPages(
    async () => {
      callCount++
      return { rows: [], hasMore: true, nextOffset: 0 } // a cursor that never moves
    },
    { limit: 10, maxPages: 5 },
  )
  assert.equal(callCount, 1)
  assert.deepEqual(out, { rows: [], truncated: 'no_advance' })
})

test('collectCorpus NAMES no_advance in its build-log notice', async () => {
  // A truncation state the notice cannot name is a guard that fires
  // unreportably — the second acceptance criterion of task-a5b10e7a686e37bb.
  const warnings: string[] = []
  const out = await collectCorpus(
    async (limit: number) => ({
      rows: Array.from({ length: limit }, (_, i) => ({ i })),
      hasMore: true,
    }),
    (m) => warnings.push(m),
  )
  assert.equal(out.truncated, 'no_advance')
  assert.equal(warnings.length, 1)
  assert.match(warnings[0], /no_advance/, 'the notice names WHICH truncation happened')
  assert.match(warnings[0], /INCOMPLETE/)
  assert.ok(CORPUS_MAX_PAGES > 1, 'the cap is not what stopped this walk')
})

/**
 * The bounded pagination law for this template's corpus reads — the Astro
 * edition of `web/lib/paginate.ts` and `apps/hundesteder/lib/paginate.ts`
 * (task-669e7706cb86cb3a, the FIFTH instance of this fix; same law, not a new
 * one).
 *
 * WHY THIS FILE EXISTS AT ALL: `src/lib/bp.ts` imports `@barkpark/core` and
 * evaluates `required('BARKPARK_API_URL')` at module load, so it cannot be
 * imported by a test — and the finder-contract CI job (`.github/workflows/
 * astro-search-finder-test.yml`) runs `node --test 'src/**\/*.test.ts'` with
 * NO `npm ci` at all. This module therefore imports NOTHING: the real walk
 * ships and is tested as ONE artifact under bare `node --test`, exactly like
 * the two siblings above.
 *
 * THE DEFECT IT RETIRES: `allDocs()` was
 * `bp().docs(type).order('_updatedAt:desc').limit(500).find()` — ONE query, no
 * offset loop, no truncation signal. The Barkpark query API clamps `limit` to
 * at most 1000 per page (`DocsBuilder.limit`, js/packages/core/src/types.ts),
 * so a corpus past the fixed cap was silently truncated. Both of `allDocs()`'s
 * callers inherit that:
 *
 *   - `browseSeed()` bakes `search-seed.json`, so the finder's prefix index
 *     silently misses every doc past the cap;
 *   - `getStaticPaths()` in `src/pages/d/[type]/[slug].astro` — WORSE: a doc
 *     past the cap gets NO PAGE GENERATED AT ALL. The deployed site 404s on it
 *     while the build log stays green.
 *
 * THE SECOND DEFECT, and why the law below changed (task-a5b10e7a686e37bb):
 * the original law inferred exhaustion from page LENGTH — a page with fewer
 * rows than requested was "the honest end". That inference is only sound while
 * the server honours the requested `limit`. It does not: the query controller
 * clamps it (`min(1000) |> max(1)`). So a caller asking for pages of 2500 got
 * 1000 rows back, read `1000 < 2500` as exhaustion, stopped after ONE request,
 * and reported `truncated: undefined` — a CLEAN termination over a silent
 * prefix, strictly worse than the bug this module was written to retire
 * because it also defeats the loud `collectCorpus` notice. `web/lib/paginate.ts`
 * fixed this (PR #13657); this edition and the hundesteder one did not follow,
 * and were safe only by the coincidence that `CORPUS_PAGE_LIMIT` is exactly
 * 1000. One edit to that constant reintroduced the defect with nothing to stop
 * it. This port ends that — the protection is caller-INDEPENDENT: it clamps
 * whatever it is handed.
 *
 * THE LAW (identical to both siblings):
 *   - the requested `limit` is CLAMPED to `SERVER_MAX_PAGE_LIMIT` before the
 *     first request, and a caller that asked for more is warned once naming
 *     both numbers. This restores the soundness of the short-page test: the
 *     server can no longer shorten a page behind the walk's back;
 *   - when a page carries the query API's EXACT truncation signal (`hasMore`),
 *     the walk terminates on `hasMore === false` and NOT on page length. A
 *     page that is short but says `hasMore: true` keeps walking;
 *   - `nextOffset` drives the cursor when the server supplies it, otherwise
 *     the offset advances by the RAW page length (never by a post-filter
 *     count — dropping malformed rows must not stall the cursor);
 *   - a page that yields NO forward progress — the server says `hasMore` but
 *     withholds `nextOffset` (it does so past the 100_000 offset ceiling), or
 *     supplies one that does not advance — stops the walk and says
 *     `truncated: 'no_advance'` rather than spinning against a clamp;
 *   - a page WITHOUT the signal (a bare array, which is what the SDK's
 *     `.find()` hands back) falls back to the short-page test, which is now
 *     sound because of the clamp;
 *   - the walk is BOUNDED by `maxPages`: if every page comes back full the cap
 *     stops the loop and `truncated: 'cap'` says so out loud;
 *   - a FAILED page (the fetcher returns null) mid-walk returns everything
 *     collected so far with `truncated: 'failed_page'` — partial truth,
 *     honestly labeled, never silently swallowed. A FAILED FIRST page is left
 *     to the caller: this module returns `{ rows: [] }` with no truncation
 *     flag (there is no partial truth to disclaim yet).
 */

/**
 * The largest page the document query will serve, whatever a caller asks for:
 * the query controller clamps `limit` to `min(1000) |> max(1)`. Requesting
 * more does not fail — it silently returns a page of 1000, which is precisely
 * what made the old short-page law unsound. Keep this in step with the
 * controller, and with `web/lib/paginate.ts`'s constant of the same name.
 */
export const SERVER_MAX_PAGE_LIMIT = 1000

/**
 * The rich page shape: the rows PLUS the query API's truncation signal. A
 * `fetchPage` callback may return this instead of a bare array to get exact
 * termination, when it can see the raw envelope (`result.hasMore`,
 * `result.nextOffset`). `bp.ts` goes through the SDK's `.find()`, which
 * surfaces documents only, so it returns a bare array and rides the clamped
 * short-page fallback.
 */
export interface FetchedPage<T = unknown> {
  rows: T[]
  /** `result.hasMore` — EXACT: a row exists past this page. Omit when unknown. */
  hasMore?: boolean
  /** `result.nextOffset` — the offset that reads the next page, when one exists. */
  nextOffset?: number
}

/** What a `fetchPage` callback may hand back. `null` = this page failed. */
export type FetchedPageResult<T = unknown> = T[] | FetchedPage<T> | null

export interface CollectedPages<T = unknown> {
  rows: T[]
  /** undefined = clean termination: the corpus really is exhausted. */
  truncated?: 'cap' | 'failed_page' | 'no_advance'
}

/** Has the over-limit warning already been emitted? Warn once per process, not
 * once per page — a 40-page walk must not print the same line 40 times. */
let warnedOverLimit = false

/** Test seam: reset the once-only warning latch. Not used by shipped code. */
export function __resetPaginateWarnings(): void {
  warnedOverLimit = false
}

function isFetchedPage<T>(v: T[] | FetchedPage<T>): v is FetchedPage<T> {
  return !Array.isArray(v)
}

export async function collectAllPages<T = unknown>(
  fetchPage: (limit: number, offset: number) => Promise<FetchedPageResult<T>>,
  { limit, maxPages }: { limit: number; maxPages: number },
): Promise<CollectedPages<T>> {
  // Never ask for more than the server will serve. Asking for 2500 and being
  // handed 1000 is the whole defect: the walk read the short page as the end.
  const pageLimit = Math.max(1, Math.min(limit, SERVER_MAX_PAGE_LIMIT))
  if (limit > SERVER_MAX_PAGE_LIMIT && !warnedOverLimit) {
    warnedOverLimit = true
    console.warn(
      `[paginate] requested page limit ${limit} exceeds the query API's ceiling ` +
        `of ${SERVER_MAX_PAGE_LIMIT}; walking in pages of ${SERVER_MAX_PAGE_LIMIT} instead. ` +
        `The server would have silently served ${SERVER_MAX_PAGE_LIMIT} rows per page.`,
    )
  }

  const rows: T[] = []
  let offset = 0
  for (let page = 0; page < maxPages; page++) {
    const result = await fetchPage(pageLimit, offset)
    if (result === null) {
      // First page failing means we have nothing — that is the existing
      // degrade-to-empty behaviour. A later page failing means partial truth.
      return page === 0 ? { rows } : { rows, truncated: 'failed_page' }
    }

    const rich = isFetchedPage(result)
    const batch = rich ? result.rows : result
    const hasMore = rich ? result.hasMore : undefined
    rows.push(...batch)

    // EXACT termination when the server told us; the short-page inference only
    // as a fallback (sound now that `pageLimit` is never above the clamp).
    if (hasMore === false) return { rows }
    if (hasMore === undefined && batch.length < pageLimit) return { rows }

    // Forward progress. `nextOffset` when the server supplied an advancing one,
    // otherwise the RAW page length. Either way it must MOVE — a walk that
    // re-reads the same offset would spin to the cap re-collecting rows.
    const supplied = rich ? result.nextOffset : undefined
    const advancing =
      typeof supplied === 'number' && Number.isFinite(supplied) && supplied > offset
    // The server says more rows exist but hands back no advancing cursor: it
    // does exactly that past the 100_000 offset ceiling, where a further read
    // re-serves THIS page. Advancing by page length there would re-collect the
    // same rows until the cap. Stop, and say why.
    if (hasMore === true && supplied === undefined) {
      return { rows, truncated: 'no_advance' }
    }
    const next = advancing ? supplied : offset + batch.length
    if (next <= offset) return { rows, truncated: 'no_advance' }
    offset = next
  }
  return { rows, truncated: 'cap' }
}

/** Page size for the corpus walk — the server's own ceiling, so a full page is
 * a genuinely full page. Asking for more is no longer unsafe (`collectAllPages`
 * clamps whatever it is handed and warns), but there is nothing to gain: the
 * server would serve 1000 either way. */
export const CORPUS_PAGE_LIMIT = SERVER_MAX_PAGE_LIMIT

/** Walk bound. 1000/page x 40 pages = 40k docs, far beyond any plausible
 * starter corpus — the cap exists so a misbehaving upstream that always
 * returns full pages cannot spin the build forever, and hitting it is reported
 * out loud, never absorbed. */
export const CORPUS_MAX_PAGES = 40

/**
 * The corpus walk `allDocs()` performs, with its page bounds and its loud
 * truncation notice bound in — kept HERE, beside the law, so the thing under
 * test is the thing that ships. `src/lib/bp.ts` supplies only the SDK call.
 *
 * The notice goes to `console.warn` rather than a throw on purpose: a partial
 * corpus must be VISIBLE in the build log, but a starter that hard-fails its
 * build on one flaky upstream page is worse than one that ships what it got
 * and says so. Silence is the only unacceptable option. It fires for EVERY
 * truncation state, `no_advance` included — a state the notice cannot name is
 * a guard that fires unreportably.
 */
export async function collectCorpus<T = unknown>(
  fetchPage: (limit: number, offset: number) => Promise<FetchedPageResult<T>>,
  warn: (msg: string) => void = console.warn,
): Promise<CollectedPages<T>> {
  const out = await collectAllPages<T>(fetchPage, {
    limit: CORPUS_PAGE_LIMIT,
    maxPages: CORPUS_MAX_PAGES,
  })
  if (out.truncated !== undefined) {
    warn(
      `[bp] CORPUS PAGINATION COULD NOT TERMINATE CLEANLY (${out.truncated}) — ` +
        `building from the ${out.rows.length} docs collected so far. The search ` +
        `seed is INCOMPLETE and documents past this point get no generated page.`,
    )
  }
  return out
}

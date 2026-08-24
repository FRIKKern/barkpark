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
 * THE LAW (identical to both siblings):
 *   - request pages of `limit` rows, advancing `offset` by the RAW page length
 *     (never by a post-filter count — dropping malformed rows must not stall
 *     the cursor);
 *   - a SHORT page (fewer than `limit` rows) terminates the walk — the corpus
 *     is exhausted;
 *   - the walk is BOUNDED by `maxPages`: if every page comes back full the cap
 *     stops the loop and `truncated: "cap"` says so out loud;
 *   - a FAILED page (the fetcher returns null) mid-walk returns everything
 *     collected so far with `truncated: "failed_page"` — partial truth,
 *     honestly labeled, never silently swallowed. A FAILED FIRST page is left
 *     to the caller: this module returns `{ rows: [] }` with no truncation
 *     flag (there is no partial truth to disclaim yet).
 */

export interface CollectedPages<T = unknown> {
  rows: T[]
  /** undefined = clean termination on a short page. */
  truncated?: 'cap' | 'failed_page'
}

export async function collectAllPages<T = unknown>(
  fetchPage: (limit: number, offset: number) => Promise<T[] | null>,
  { limit, maxPages }: { limit: number; maxPages: number },
): Promise<CollectedPages<T>> {
  const rows: T[] = []
  let offset = 0
  for (let page = 0; page < maxPages; page++) {
    const batch = await fetchPage(limit, offset)
    if (batch === null) {
      // First page failing means we have nothing — that is the existing
      // degrade-to-empty behaviour. A later page failing means partial truth.
      return page === 0 ? { rows } : { rows, truncated: 'failed_page' }
    }
    rows.push(...batch)
    if (batch.length < limit) return { rows } // short page — the honest end
    offset += batch.length // raw advance: the cursor never stalls
  }
  return { rows, truncated: 'cap' }
}

/** Page size for the corpus walk. The query API clamps `limit` to 1000, so
 * this is the largest honest page — asking for more silently gets 1000 back
 * and a bigger number here would make a full page look short. */
export const CORPUS_PAGE_LIMIT = 1000

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
 * and says so. Silence is the only unacceptable option.
 */
export async function collectCorpus<T = unknown>(
  fetchPage: (limit: number, offset: number) => Promise<T[] | null>,
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

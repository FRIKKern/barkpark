/**
 * The bounded pagination law for web/'s `/v1/data/query` list helpers,
 * extracted so the REAL loop is testable (task-269eefbe4864d8a5).
 *
 * WHY THIS FILE EXISTS: `papers.ts` / `posts.ts` / `listings.ts` each pull in
 * `@barkpark/core`, `next/cache`, `server-only`, and/or `@/` path aliases —
 * enough surface that hand-kept mirrors are the usual test strategy in this
 * package (see `__tests__/listings.test.ts`'s header). This module
 * deliberately imports nothing, so the pagination behaviour ships and is
 * tested as ONE artifact under bare `node --test`, exactly like
 * `apps/hundesteder/lib/paginate.ts` (PR #13316), the second instance of this
 * fix. This is the third — same shape, not a new one.
 *
 * THE DEFECT IT RETIRES: `fetchPapers()` / `fetchPosts()` each issued a single
 * `.limit(50).find()` query with no offset loop. `rawListings()` did the same
 * at `LISTINGS_LIMIT` (default 500). The Barkpark query API clamps `limit` to
 * at most 1000 (`DocsBuilder.limit` docs, js/packages/core/src/types.ts), so
 * any corpus past the fixed cap was silently truncated: no error, no signal,
 * every consumer (the /papers listing, sitemap.xml, feed.xml, the scoped
 * posts listing, the listings map) simply seeing a shrunken corpus. Confirmed
 * ACTIVE in prod: the `docs` dataset carries 118 papers against a `limit(50)`
 * call. Same silent-wrongness class as the chat roster fix legislated against
 * ("PAGINATION COULD NOT TERMINATE", task-35e4fa473743f866) and its
 * unpaginated hundesteder sibling (task-32a7f8c07041d4d6).
 *
 * THE SECOND DEFECT, and why the law below changed (task-6eb2d810605b1a41):
 * the original law inferred exhaustion from page LENGTH — a page with fewer
 * rows than requested was "the honest end". That inference is only sound while
 * the server honours the requested `limit`. It does not: the query controller
 * clamps it (`api/lib/barkpark_web/controllers/query_controller.ex:29`,
 * `parse_int(params["limit"], 100) |> min(1000) |> max(1)`). So a caller
 * asking for pages of 2500 got 1000 rows back, read `1000 < 2500` as
 * exhaustion, stopped after ONE request, and reported `truncated: undefined` —
 * a CLEAN termination over a silent prefix. That is strictly worse than the
 * bug this module was written to retire, because it also defeats the
 * `truncated` warning above. `web/lib/listings.ts` reaches it for real:
 * `LISTINGS_LIMIT` is read from the environment with no upper bound, so
 * `LISTINGS_LIMIT=2000` renders the first 1000 map pins and logs nothing.
 * `papers.ts` / `posts.ts` pass exactly 1000 and are correct only by
 * coincidence — one edit to that constant reintroduces the defect.
 *
 * THE LAW:
 *   - the requested `limit` is CLAMPED to `SERVER_MAX_PAGE_LIMIT` before the
 *     first request, and a caller that asked for more is warned once naming
 *     both numbers. This restores the soundness of the short-page test: the
 *     server can no longer shorten a page behind the walk's back;
 *   - when a page carries the query API's EXACT truncation signal
 *     (`hasMore`, always present as of query_controller.ex:97-130), the walk
 *     terminates on `hasMore === false` and NOT on page length. A page that is
 *     short but says `hasMore: true` keeps walking;
 *   - `nextOffset` drives the cursor when the server supplies it, otherwise
 *     the offset advances by the RAW page length (never by a post-filter
 *     count — dropping malformed rows must not stall the cursor);
 *   - a page that yields NO forward progress — the server says `hasMore` but
 *     withholds `nextOffset` (it does so past the 100_000 offset ceiling), or
 *     supplies one that does not advance — stops the walk and says
 *     `truncated: "no_advance"` rather than spinning against a clamp;
 *   - a page WITHOUT the signal (a bare array, the legacy fetcher shape) falls
 *     back to the short-page test, which is now sound because of the clamp;
 *   - the walk is BOUNDED by `maxPages`: if every page comes back full the
 *     cap stops the loop and `truncated: "cap"` says so out loud;
 *   - a FAILED page (the fetcher returns null) mid-walk returns everything
 *     collected so far with `truncated: "failed_page"` — partial truth,
 *     honestly labeled, never silently swallowed. A FAILED FIRST page is left
 *     to the caller: this module returns `{ rows: [] }` with no truncation
 *     flag (there is no partial truth to disclaim yet), and callers that want
 *     the existing throw-and-show-an-error behaviour reject out of their
 *     `fetchPage` callback on `offset === 0` instead of swallowing to null.
 */

/**
 * The largest page the document query will serve, whatever a caller asks for:
 * `query_controller.ex:29` clamps `limit` to `min(1000) |> max(1)`. Requesting
 * more does not fail — it silently returns a page of 1000, which is precisely
 * what made the old short-page law unsound. Keep this in step with the
 * controller; `js/packages/core/src/types.ts` documents the same ceiling on
 * `DocsBuilder.limit`.
 */
export const SERVER_MAX_PAGE_LIMIT = 1000;

/**
 * The rich page shape: the rows PLUS the query API's truncation signal. A
 * `fetchPage` callback may return this instead of a bare array to get exact
 * termination — see `web/lib/listings.ts` for the envelope keys
 * (`result.hasMore`, `result.nextOffset`).
 */
export interface FetchedPage {
  rows: unknown[];
  /** `result.hasMore` — EXACT: a row exists past this page. Omit when unknown. */
  hasMore?: boolean;
  /** `result.nextOffset` — the offset that reads the next page, when one exists. */
  nextOffset?: number;
}

/** What a `fetchPage` callback may hand back. `null` = this page failed. */
export type FetchedPageResult = unknown[] | FetchedPage | null;

export interface CollectedPages {
  rows: unknown[];
  /** undefined = clean termination: the corpus really is exhausted. */
  truncated?: "cap" | "failed_page" | "no_advance";
}

/**
 * Read one `/v1/data/query` response into a `FetchedPage` — the ONE place in
 * `web/` that knows where the truncation signal lives on the envelope.
 *
 * The response nests under `result`: `{ result: { documents, count, limit,
 * offset, hasMore, nextOffset? } }` (query_controller.ex:120-131). `hasMore`
 * is always present and EXACT — the controller reads one row past the page to
 * answer it. `nextOffset` rides along only when a next page exists, and is
 * deliberately WITHHELD past the 100_000 offset ceiling where a further read
 * would re-serve the same page.
 *
 * Tolerates two shape drifts the walkers already accepted: a bare array, and
 * an un-nested envelope (`{ documents }` at the top level). Neither carries a
 * signal in the bare-array case, so the walk falls back to its short-page
 * test — sound now that the page size is clamped. NEVER infer truncation from
 * `count === limit`: that is exactly the ambiguity `hasMore` was added to end.
 */
export function readQueryPage(json: unknown): FetchedPage {
  if (Array.isArray(json)) return { rows: json };

  const outer = (json ?? {}) as Record<string, unknown>;
  const inner = (outer.result ?? outer) as Record<string, unknown>;
  const docs = inner.documents;
  return {
    rows: Array.isArray(docs) ? docs : [],
    ...(typeof inner.hasMore === "boolean" ? { hasMore: inner.hasMore } : {}),
    ...(typeof inner.nextOffset === "number" && Number.isFinite(inner.nextOffset)
      ? { nextOffset: inner.nextOffset }
      : {}),
  };
}

/** Has the over-limit warning already been emitted? Warn once per process, not
 * once per page — a 20-page walk must not print the same line 20 times. */
let warnedOverLimit = false;

/** Test seam: reset the once-only warning latch. Not used by shipped code. */
export function __resetPaginateWarnings(): void {
  warnedOverLimit = false;
}

function isFetchedPage(v: unknown[] | FetchedPage): v is FetchedPage {
  return !Array.isArray(v);
}

export async function collectAllPages(
  fetchPage: (limit: number, offset: number) => Promise<FetchedPageResult>,
  { limit, maxPages }: { limit: number; maxPages: number },
): Promise<CollectedPages> {
  // Never ask for more than the server will serve. Asking for 2500 and being
  // handed 1000 is the whole defect: the walk read the short page as the end.
  const pageLimit = Math.max(1, Math.min(limit, SERVER_MAX_PAGE_LIMIT));
  if (limit > SERVER_MAX_PAGE_LIMIT && !warnedOverLimit) {
    warnedOverLimit = true;
    console.warn(
      `[paginate] requested page limit ${limit} exceeds the query API's ceiling ` +
        `of ${SERVER_MAX_PAGE_LIMIT}; walking in pages of ${SERVER_MAX_PAGE_LIMIT} instead. ` +
        `The server would have silently served ${SERVER_MAX_PAGE_LIMIT} rows per page.`,
    );
  }

  const rows: unknown[] = [];
  let offset = 0;
  for (let page = 0; page < maxPages; page++) {
    const result = await fetchPage(pageLimit, offset);
    if (result === null) {
      // First page failing means we have nothing — that is the existing
      // degrade-to-empty behaviour. A later page failing means partial truth.
      return page === 0 ? { rows } : { rows, truncated: "failed_page" };
    }

    const rich = isFetchedPage(result);
    const batch = rich ? result.rows : result;
    const hasMore = rich ? result.hasMore : undefined;
    rows.push(...batch);

    // EXACT termination when the server told us; the short-page inference only
    // as a fallback (sound now that `pageLimit` is never above the clamp).
    if (hasMore === false) return { rows };
    if (hasMore === undefined && batch.length < pageLimit) return { rows };

    // Forward progress. `nextOffset` when the server supplied an advancing one,
    // otherwise the RAW page length. Either way it must MOVE — a walk that
    // re-reads the same offset would spin to the cap re-collecting rows.
    const supplied = rich ? result.nextOffset : undefined;
    const advancing =
      typeof supplied === "number" && Number.isFinite(supplied) && supplied > offset;
    // The server says more rows exist but hands back no advancing cursor: it
    // does exactly that past the 100_000 offset ceiling, where a further read
    // re-serves THIS page. Advancing by page length there would re-collect the
    // same rows until the cap. Stop, and say why.
    if (hasMore === true && supplied === undefined) {
      return { rows, truncated: "no_advance" };
    }
    const next = advancing ? supplied : offset + batch.length;
    if (next <= offset) return { rows, truncated: "no_advance" };
    offset = next;
  }
  return { rows, truncated: "cap" };
}

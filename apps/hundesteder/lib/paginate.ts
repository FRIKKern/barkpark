/**
 * The bounded pagination law for the places data layer, extracted so the REAL
 * loop is testable (task-32a7f8c07041d4d6).
 *
 * WHY THIS FILE EXISTS: `places.ts` imports `server-only`, which is not
 * resolvable under bare `node --test`, so its logic could previously only be
 * tested through hand-kept mirrors (see the header of
 * `__tests__/places.test.ts`). This module deliberately imports nothing, so
 * the pagination behaviour ships and is tested as ONE artifact.
 *
 * THE DEFECT IT RETIRES: `fetchPlaces()` issued a single query with no
 * `limit`/`offset`. The Barkpark query API defaults `limit` to 100 (clamped
 * to at most 1000 — query_controller.ex), so past 100 published places the
 * site would silently lose places: no error, no signal, every consumer
 * (landing grid, city index, map, slug lookup) simply seeing a truncated
 * corpus. That is the same silent-wrongness class the chat roster fix
 * legislated against ("PAGINATION COULD NOT TERMINATE",
 * task-35e4fa473743f866) — this is its unpaginated flavor.
 *
 * THE SECOND DEFECT, and why the law below changed (task-a5b10e7a686e37bb):
 * the original law inferred exhaustion from page LENGTH — a page with fewer
 * rows than requested was "the honest end". That inference is only sound while
 * the server honours the requested `limit`. It does not: the query controller
 * clamps it (`min(1000) |> max(1)`). So a caller asking for pages of 2500 got
 * 1000 rows back, read `1000 < 2500` as exhaustion, stopped after ONE request,
 * and reported `truncated: undefined` — a CLEAN termination over a silent
 * prefix, strictly worse than the bug this module was written to retire
 * because it also defeats the `truncated` warning. `web/lib/paginate.ts` fixed
 * this (PR #13657); this edition and the Astro one did not follow, and were
 * safe only by the coincidence that `PLACES_PAGE_LIMIT` is exactly 1000. One
 * edit to that constant reintroduced the defect with nothing to stop it. This
 * port ends that — the protection is caller-INDEPENDENT: it clamps whatever it
 * is handed. Same law as `web/lib/paginate.ts`, not a new one.
 *
 * THE LAW:
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
 *     `truncated: "no_advance"` rather than spinning against a clamp;
 *   - a page WITHOUT the signal (a bare array) falls back to the short-page
 *     test, which is now sound because of the clamp;
 *   - the walk is BOUNDED by `maxPages`: if every page comes back full the
 *     cap stops the loop and `truncated: "cap"` says so out loud;
 *   - a FAILED page (the fetcher returns null) mid-walk returns everything
 *     collected so far with `truncated: "failed_page"` — partial truth,
 *     honestly labeled, never a throw (the module's never-throw law).
 */

/**
 * The largest page the document query will serve, whatever a caller asks for:
 * `query_controller.ex` clamps `limit` to `min(1000) |> max(1)`. Requesting
 * more does not fail — it silently returns a page of 1000, which is precisely
 * what made the old short-page law unsound. Keep this in step with the
 * controller, and with `web/lib/paginate.ts`'s constant of the same name.
 */
export const SERVER_MAX_PAGE_LIMIT = 1000;

export interface PageResult {
  /** Raw rows of one page, or null when the page fetch failed outright. */
  rows: unknown[] | null;
}

/**
 * The rich page shape: the rows PLUS the query API's truncation signal. A
 * `fetchPage` callback may return this instead of a bare array to get exact
 * termination — `lib/places.ts` lifts the keys straight off the envelope
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

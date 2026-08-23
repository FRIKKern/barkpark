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
 * THE LAW:
 *   - request pages of `limit` rows, advancing `offset` by the RAW page
 *     length (never by a post-filter count — dropping malformed rows must
 *     not stall the cursor);
 *   - a SHORT page (fewer than `limit` rows) terminates the walk — the
 *     corpus is exhausted;
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

export interface CollectedPages {
  rows: unknown[];
  /** undefined = clean termination on a short page. */
  truncated?: "cap" | "failed_page";
}

export async function collectAllPages(
  fetchPage: (limit: number, offset: number) => Promise<unknown[] | null>,
  { limit, maxPages }: { limit: number; maxPages: number },
): Promise<CollectedPages> {
  const rows: unknown[] = [];
  let offset = 0;
  for (let page = 0; page < maxPages; page++) {
    const batch = await fetchPage(limit, offset);
    if (batch === null) {
      // First page failing means we have nothing — that is the existing
      // degrade-to-empty behaviour. A later page failing means partial truth.
      return page === 0 ? { rows } : { rows, truncated: "failed_page" };
    }
    rows.push(...batch);
    if (batch.length < limit) return { rows }; // short page — the honest end
    offset += batch.length; // raw advance: the cursor never stalls
  }
  return { rows, truncated: "cap" };
}

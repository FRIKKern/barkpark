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
 * THE LAW:
 *   - request pages of `limit` rows, advancing `offset` by the RAW page
 *     length (never by the post-filter count — dropping malformed rows must
 *     not stall the cursor);
 *   - a SHORT page (fewer than `limit` rows) terminates the walk — the
 *     corpus is exhausted;
 *   - the walk is BOUNDED by `maxPages`: if every page comes back full the
 *     cap stops the loop and `truncated: "cap"` says so out loud;
 *   - a FAILED page (the fetcher returns null) mid-walk returns everything
 *     collected so far with `truncated: "failed_page"` — partial truth,
 *     honestly labeled, never a throw (the module's never-throw law).
 */

export interface PageResult {
  /** Raw rows of one page, or null when the page fetch failed outright. */
  rows: unknown[] | null;
}

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

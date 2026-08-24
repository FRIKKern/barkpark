/**
 * The finder's honest result-count reading — what the header may claim when the
 * list on screen and the number beside it were measured over DIFFERENT sets.
 *
 * WHY THIS FILE EXISTS: it imports nothing, so the reading ships and is tested
 * as ONE artifact under bare `node --test`, exactly like `lib/paginate.ts` and
 * `lib/graph-truncation.ts`. `components/finder.tsx` pulls in `next/navigation`,
 * `phoenix`, and a dozen `@/` modules, which is why the rule it applies lives
 * out here rather than inline.
 *
 * ## The defect it retires
 *
 * The engine caps what it hands back at a WORKING SET (`MAX_HITS`, 100 rows —
 * `lib/find-search.ts` and `lib/use-live-search.ts` both request it). Facet
 * buckets and `total` are NOT capped with it: the retriever computes them over
 * the full match set on purpose —
 *
 *   "Facets + count stay on the FULL match set (not the ranking pool): the user
 *    wants 'this query matched 1.2k items across these facets', not 'the top 500
 *    break down this way'."
 *   — api/lib/barkpark/search/documents_retriever.ex, count_and_facets/1
 *
 * The finder then applies the facet selection and the sort CLIENT-SIDE, over
 * the 100 rows it holds. So on a corpus larger than the window:
 *
 *   - the rail offers `paper 1200` (a real, dataset-wide count, and the rail
 *     says so: "Counts computed by Indx across the matches");
 *   - clicking it filters the 100 fetched rows down to, say, 12;
 *   - the header read `12 of 1200 results` — a total belonging to the
 *     UNFILTERED match set, printed beside a count belonging to a
 *     client-filtered prefix of the ranking pool.
 *
 * Nothing distinguished that from an exhausted list of 12. Same shape as every
 * truncation this codebase has already legislated against — `paginate.ts`'s
 * `truncated`, `graph.ts`'s `truncated`, `listings.ts`'s `substituted`,
 * `find-event`'s `recorded` — and the same remedy: the degrade stays, because
 * client-side faceting over a bounded window is genuinely fast and genuinely
 * useful, but it stops being SILENT.
 *
 * `sort` has the identical problem and is arguably worse for looking
 * authoritative: "Newest" over a truncated relevance window is the newest of
 * the top 100 by relevance, NOT the newest of the 1200 matches.
 *
 * ## The law
 *
 *   - the window is TRUNCATED when the engine's `total` exceeds the number of
 *     rows it actually returned. That is the exact signal, straight from the
 *     server — never inferred from `hits.length === some cap`, which cannot
 *     tell an exhausted page from a clipped one;
 *   - with NO client-side narrowing in play (no facet, relevance order), the
 *     displayed count and `total` describe the same set, so the existing
 *     `N of TOTAL` reading is already honest and is kept verbatim;
 *   - with narrowing in play over a truncated window, `total` must NOT be
 *     printed as this view's total. The count says what it really counted —
 *     matches within the rows in hand — and names the window;
 *   - when the window is COMPLETE, client-side narrowing is exact over the
 *     whole match set, so no caveat is warranted and none is emitted. A notice
 *     that fires when nothing is wrong is how a real one gets ignored.
 */

/** What the finder knows about the current view when it renders its header. */
export interface ResultWindowInput {
  /** Engine match count over the FULL match set (`FindResponse.total`). */
  total: number;
  /** Rows the engine actually returned — the working set (`hits.length`). */
  fetched: number;
  /** Rows on screen after client-side facet filtering (`visibleHits.length`). */
  visible: number;
  /** Is any facet selected? Client-side narrowing over the rows in hand. */
  facetActive: boolean;
  /** Is a non-relevance sort applied? Client-side reordering of those rows. */
  reordered: boolean;
}

export interface ResultWindowReading {
  /** The count phrase, without the trailing "result"/"results" noun. */
  countLabel: string;
  /** Singular/plural for the noun the caller appends. */
  plural: boolean;
  /**
   * The engine returned fewer rows than it matched — the working set is a
   * prefix of the corpus. True even when nothing is narrowed client-side.
   */
  windowTruncated: boolean;
  /**
   * One sentence naming what the on-screen list is a view OF, or null when the
   * view and the match set coincide and there is nothing to disclaim.
   */
  caveat: string | null;
}

/**
 * Read the honest count for one rendered view.
 *
 * `countLabel` is deliberately a phrase and not a full sentence: the finder's
 * header appends "result"/"results" itself, and keeping that noun in the
 * component preserves its existing markup.
 */
export function readResultWindow({
  total,
  fetched,
  visible,
  facetActive,
  reordered,
}: ResultWindowInput): ResultWindowReading {
  // The exact signal, from the server: it matched more than it handed over.
  const windowTruncated = total > fetched;
  const narrowed = facetActive || reordered;
  const plural = visible !== 1;

  // Nothing client-side is reshaping the list, so `visible` and `total` measure
  // the same set and the long-standing reading is correct as it stands.
  if (!narrowed) {
    return {
      countLabel: windowTruncated ? `${visible} of ${total}` : `${visible}`,
      plural,
      windowTruncated,
      caveat: null,
    };
  }

  // Narrowed, but the engine gave us everything it matched — the client-side
  // facet/sort is exact over the whole match set. No caveat is warranted.
  if (!windowTruncated) {
    return { countLabel: `${visible}`, plural, windowTruncated, caveat: null };
  }

  // Narrowed over a PREFIX. `total` describes the unfiltered match set and must
  // not ride beside a filtered count as though it were this view's total.
  return {
    countLabel: `${visible} of the first ${fetched}`,
    plural,
    windowTruncated,
    caveat: caveatFor({ total, fetched, facetActive, reordered }),
  };
}

/**
 * Name what was actually narrowed, and over what. Kept separate so the wording
 * is one thing to change and the branch table above stays readable.
 */
function caveatFor({
  total,
  fetched,
  facetActive,
  reordered,
}: {
  total: number;
  fetched: number;
  facetActive: boolean;
  reordered: boolean;
}): string {
  const what =
    facetActive && reordered
      ? "Filtering and sorting run"
      : facetActive
        ? "Filtering runs"
        : "Sorting runs";
  return (
    `${what} over the ${fetched} results the engine returned, not the ` +
    `${total} it matched — narrow the query to reach the rest.`
  );
}

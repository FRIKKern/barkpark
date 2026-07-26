// Pure paging accumulator for the papers list (review F3 verify-round).
// Extracted from the screen so jest can pin the paging laws directly — the
// wrong-envelope assumption (`count` read as a corpus total) slipped through
// exactly because this logic lived untested inside a hook component.
//
// Laws:
//   • `offset` advances by the RAW server page length (pageLen), never by the
//     post-dedupe length — a page full of already-seen ids still moves the
//     window forward, so paging can never stall or refetch the same rows.
//   • `hasMore` comes from the page itself (short page = end of corpus); it
//     never depends on the display-only `total`.
//   • Appended items dedupe on `_id`: under order=_updatedAt:desc a paper
//     updated between page fetches can slide across the page seam.
import type { PaperListItem, PaperPage } from '../api/papers'

export interface PagerState {
  papers: PaperListItem[]
  /** next server offset — Σ raw page lengths, dedupe-independent */
  offset: number
  hasMore: boolean
  /** corpus total when the server sent one (`count=true`) — display only */
  total?: number
}

export const EMPTY_PAGER: PagerState = { papers: [], offset: 0, hasMore: true }

/** Fold one fetched page into the pager state. */
export function appendPage(state: PagerState, page: PaperPage): PagerState {
  const seen = new Set(state.papers.map((p) => p._id))
  const fresh = page.items.filter((p) => !seen.has(p._id))
  const next: PagerState = {
    papers: [...state.papers, ...fresh],
    offset: state.offset + page.pageLen,
    hasMore: page.hasMore,
  }
  const total = page.total ?? state.total
  if (total !== undefined) next.total = total
  return next
}

/** Fold a CACHED page 0 into a fresh PagerState (D42 read-through). The cache
 * path MUST yield the identical shape and invariants as the network path —
 * so it IS the network fold, applied to the empty pager: offset advances by
 * the cached page's raw pageLen, hasMore comes from the page itself, total
 * carries through. Anything else would fork the paging laws. */
export function hydrate(cachedPage: PaperPage): PagerState {
  return appendPage(EMPTY_PAGER, cachedPage)
}

/** Whether the screen should fetch another page on end-reach. */
export function shouldLoadMore(state: PagerState): boolean {
  return state.hasMore
}

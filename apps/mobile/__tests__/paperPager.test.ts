// Papers list paging laws (review F3 verify-round) — mocked-envelope legs.
//
// The original F3 fix read the query envelope's `count` as a corpus total;
// live it is the RETURNED-PAGE row count (probed: limit=5 → count:5 against
// 537 papers), so paging stopped after page one. These tests pin the real
// envelope shape end-to-end through fetchPaperPage + the pure paperPager:
//
//   (a) a full page (exactly PAPER_PAGE_SIZE rows) → hasMore, and the next
//       fetch goes out with offset=PAPER_PAGE_SIZE,
//   (b) a short page → no further fetch (shouldLoadMore false), end state,
//   (c) an item repeating across the page seam → appended once, while the
//       offset still advances by the RAW page length (never the deduped one),
//   (d) `count=true` is on the wire and `result.total` feeds the display-only
//       total — hasMore never depends on it.
import type { BarkparkClient } from '@barkpark/core'

import { PAPER_PAGE_SIZE, fetchPaperPage } from '../src/api/papers'
import { EMPTY_PAGER, appendPage, shouldLoadMore } from '../src/papers/paperPager'

/** The LIVE envelope shape: result.{count,offset,total?,limit,perspective,
 * documents} where `count` is the returned-page row count. */
function envelope(docs: Record<string, unknown>[], offset: number, total?: number) {
  return {
    result: {
      count: docs.length, // page rows — the field the regression misread
      offset,
      limit: PAPER_PAGE_SIZE,
      perspective: 'published',
      ...(total !== undefined ? { total } : {}),
      documents: docs,
    },
  }
}

function docs(from: number, n: number): Record<string, unknown>[] {
  return Array.from({ length: n }, (_, i) => ({
    _id: `paper-${from + i}`,
    title: `Paper ${from + i}`,
  }))
}

/** A fetchRaw-only mock client serving canned envelopes per offset. */
function mockClient(pages: Record<number, ReturnType<typeof envelope>>) {
  const paths: string[] = []
  const fetchRaw = jest.fn(async (path: string) => {
    paths.push(path)
    const offset = Number(/[?&]offset=(\d+)/.exec(path)?.[1] ?? '0')
    const body = pages[offset]
    if (body === undefined) throw new Error(`no canned page at offset ${offset}`)
    return { ok: true, json: async () => body }
  })
  return { client: { fetchRaw } as unknown as BarkparkClient, paths }
}

describe('papers list paging (F3 verify-round)', () => {
  it('(a) full page → hasMore, and the second fetch carries offset=PAPER_PAGE_SIZE', async () => {
    const { client, paths } = mockClient({
      0: envelope(docs(0, PAPER_PAGE_SIZE), 0, 537),
      [PAPER_PAGE_SIZE]: envelope(docs(PAPER_PAGE_SIZE, PAPER_PAGE_SIZE), PAPER_PAGE_SIZE, 537),
    })

    const page1 = await fetchPaperPage(client, 'production', 0)
    expect(page1.hasMore).toBe(true)
    expect(page1.pageLen).toBe(PAPER_PAGE_SIZE)

    let state = appendPage(EMPTY_PAGER, page1)
    expect(shouldLoadMore(state)).toBe(true)
    expect(state.offset).toBe(PAPER_PAGE_SIZE)

    // The screen's loadMore fetches at pager.offset — drive it.
    const page2 = await fetchPaperPage(client, 'production', state.offset)
    state = appendPage(state, page2)

    expect(paths).toHaveLength(2)
    expect(paths[1]).toContain(`offset=${PAPER_PAGE_SIZE}`)
    expect(state.papers).toHaveLength(2 * PAPER_PAGE_SIZE)
  })

  it('(b) short page → no further fetch: shouldLoadMore is false', async () => {
    const { client, paths } = mockClient({ 0: envelope(docs(0, 37), 0, 37) })

    const page = await fetchPaperPage(client, 'production', 0)
    expect(page.hasMore).toBe(false)

    const state = appendPage(EMPTY_PAGER, page)
    expect(shouldLoadMore(state)).toBe(false)
    expect(state.papers).toHaveLength(37)
    // The screen renders the end-state footer from exactly this predicate;
    // no second request exists to make.
    expect(paths).toHaveLength(1)
  })

  it('(b2) the regression itself: page one of a large corpus DOES page on', async () => {
    // count == page rows (100) — the misread field. hasMore must still be true.
    const { client } = mockClient({ 0: envelope(docs(0, PAPER_PAGE_SIZE), 0) })
    const page = await fetchPaperPage(client, 'production', 0)
    expect(page.hasMore).toBe(true)
    expect(shouldLoadMore(appendPage(EMPTY_PAGER, page))).toBe(true)
  })

  it('(c) an item repeating across the seam dedupes; offset advances by RAW page length', async () => {
    const pageOneDocs = docs(0, PAPER_PAGE_SIZE)
    // Page two starts by repeating the last two items of page one (a paper
    // updated between fetches slides across the seam under _updatedAt:desc).
    const pageTwoDocs = [...docs(PAPER_PAGE_SIZE - 2, 2), ...docs(PAPER_PAGE_SIZE, 98)]
    const { client } = mockClient({
      0: envelope(pageOneDocs, 0),
      [PAPER_PAGE_SIZE]: envelope(pageTwoDocs, PAPER_PAGE_SIZE),
    })

    let state = appendPage(EMPTY_PAGER, await fetchPaperPage(client, 'production', 0))
    state = appendPage(state, await fetchPaperPage(client, 'production', state.offset))

    // 100 + (100 − 2 dupes) unique rows…
    expect(state.papers).toHaveLength(2 * PAPER_PAGE_SIZE - 2)
    const ids = state.papers.map((p) => p._id)
    expect(new Set(ids).size).toBe(ids.length)
    // …but the server offset advanced by the RAW lengths, so the next window
    // is fresh — never a stall, never a refetch of the same rows.
    expect(state.offset).toBe(2 * PAPER_PAGE_SIZE)
  })

  it('(d) count=true rides the wire; result.total is display-only', async () => {
    const { client, paths } = mockClient({ 0: envelope(docs(0, PAPER_PAGE_SIZE), 0, 537) })
    const page = await fetchPaperPage(client, 'production', 0)
    expect(paths[0]).toContain('count=true')
    expect(page.total).toBe(537)

    const state = appendPage(EMPTY_PAGER, page)
    expect(state.total).toBe(537)
    // hasMore is the page-length law, independent of total.
    expect(state.hasMore).toBe(true)

    // A server without total: pager still pages purely on page length.
    const { client: bare } = mockClient({ 0: envelope(docs(0, PAPER_PAGE_SIZE), 0) })
    const barePage = await fetchPaperPage(bare, 'production', 0)
    expect(barePage.total).toBeUndefined()
    expect(appendPage(EMPTY_PAGER, barePage).hasMore).toBe(true)
  })

  it('total learned once survives a later page that omits it', async () => {
    const { client } = mockClient({
      0: envelope(docs(0, PAPER_PAGE_SIZE), 0, 537),
      [PAPER_PAGE_SIZE]: envelope(docs(PAPER_PAGE_SIZE, 40), PAPER_PAGE_SIZE),
    })
    let state = appendPage(EMPTY_PAGER, await fetchPaperPage(client, 'production', 0))
    state = appendPage(state, await fetchPaperPage(client, 'production', state.offset))
    expect(state.total).toBe(537)
    expect(state.hasMore).toBe(false)
  })
})

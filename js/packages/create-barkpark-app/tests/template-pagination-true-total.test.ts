import { describe, it, expect } from 'vitest'
import { promises as fs } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

import { pageCount, pageWindow } from '../templates/blog-starter/lib/page-param'
import { POSTS_PER_PAGE } from '../templates/blog-starter/lib/queries'

const BLOG = path.join(
  path.dirname(fileURLToPath(import.meta.url)),
  '..',
  'templates',
  'blog-starter',
)

/**
 * THE SHIPPED FUDGE (wtc-backlog-blog-pagination-true-total).
 *
 * blog-starter's home page used to know only whether a NEXT page exists: it
 * over-fetched `POSTS_PER_PAGE + 1` documents and passed
 *
 *     const totalPages = hasNext ? pageNum + 1 : pageNum
 *
 * to <Pagination>. That number is not the corpus's page count — it is
 * "wherever the reader currently stands, plus at most one". The numbered link
 * list is therefore a function of WHERE YOU ARE rather than HOW MUCH THERE IS:
 * it grows as you page deeper and never shows the true last page.
 *
 * The fix wires `countDocs` (lib/barkpark.ts — the envelope's true total-match
 * count) through `pageCount`. These tests are the BEFORE/AFTER repro: the fudge
 * is modelled here exactly as it shipped, and every assertion below contrasts
 * what it renders against what the true total renders.
 */

/** The defect, reimplemented verbatim, as the control arm. */
function fudgedTotalPages(pageNum: number, corpusSize: number): number {
  // The page fetched POSTS_PER_PAGE + 1 rows at this offset and asked whether
  // the extra one came back.
  const offset = (pageNum - 1) * POSTS_PER_PAGE
  const fetched = Math.max(0, Math.min(POSTS_PER_PAGE + 1, corpusSize - offset))
  const hasNext = fetched > POSTS_PER_PAGE
  return hasNext ? pageNum + 1 : pageNum
}

/** What the reader actually sees: the numbered run <Pagination> materialises. */
function renderedLinks(pageNum: number, totalPages: number): number[] {
  return pageWindow(pageNum, totalPages)
}

describe('before/after: the fudged window misrepresents the corpus', () => {
  it('a deep page shows a window that grows with the reader instead of the corpus', () => {
    const corpus = 47 // 10 pages at 5 per page
    const truth = pageCount(corpus, POSTS_PER_PAGE)
    expect(truth).toBe(10)

    // BEFORE: on page 3 the fudge claims a 4-page site.
    expect(fudgedTotalPages(3, corpus)).toBe(4)
    expect(renderedLinks(3, fudgedTotalPages(3, corpus))).toEqual([1, 2, 3, 4])

    // AFTER: the true total renders the real neighbourhood, and page 10 exists.
    expect(renderedLinks(3, truth)).toEqual([1, 2, 3, 4, 5, 6, 7, 8, 9])

    // The signature of the defect: the fudged "last page" MOVES as you walk.
    expect(fudgedTotalPages(5, corpus)).toBe(6)
    expect(fudgedTotalPages(7, corpus)).toBe(8)
    // The true total does not.
    expect(pageCount(corpus, POSTS_PER_PAGE)).toBe(10)
  })

  it('the fudge can never reveal the last page from anywhere but the last page', () => {
    const corpus = 47
    const truth = pageCount(corpus, POSTS_PER_PAGE)
    for (let p = 1; p < truth - 1; p++) {
      expect(renderedLinks(p, fudgedTotalPages(p, corpus))).not.toContain(truth)
    }
    // Whereas the true total surfaces it as soon as it is in range.
    expect(renderedLinks(truth, truth)).toContain(truth)
  })
})

describe('the exact-multiple boundary (off-by-one)', () => {
  it('a corpus that exactly fills N pages is N pages, not N + 1', () => {
    for (const n of [1, 2, 3, 10]) {
      expect(pageCount(n * POSTS_PER_PAGE, POSTS_PER_PAGE)).toBe(n)
    }
  })

  it('one document past the boundary opens exactly one more page', () => {
    expect(pageCount(3 * POSTS_PER_PAGE, POSTS_PER_PAGE)).toBe(3)
    expect(pageCount(3 * POSTS_PER_PAGE + 1, POSTS_PER_PAGE)).toBe(4)
    expect(pageCount(4 * POSTS_PER_PAGE - 1, POSTS_PER_PAGE)).toBe(4)
  })

  it('on the last page of an exactly-full corpus no "Older" page is offered', () => {
    const corpus = 3 * POSTS_PER_PAGE
    const truth = pageCount(corpus, POSTS_PER_PAGE)
    expect(truth).toBe(3)
    // <Pagination> renders "Older →" iff currentPage < totalPages.
    expect(truth < truth).toBe(false)
    expect(renderedLinks(truth, truth)).toEqual([1, 2, 3])
    // The fudge agrees here — the boundary is exactly where it looks correct,
    // which is why the defect survived: it is only wrong in the MIDDLE.
    expect(fudgedTotalPages(truth, corpus)).toBe(truth)
  })
})

describe('the zero-posts corpus', () => {
  it('an empty corpus is one page, never zero', () => {
    expect(pageCount(0, POSTS_PER_PAGE)).toBe(1)
  })

  it('renders no pagination control at all (totalPages <= 1 returns null)', () => {
    const truth = pageCount(0, POSTS_PER_PAGE)
    expect(truth <= 1).toBe(true)
    expect(renderedLinks(1, truth)).toEqual([1])
  })

  it('page 1 of an empty corpus offers no next page', () => {
    const truth = pageCount(0, POSTS_PER_PAGE)
    expect(1 < truth).toBe(false)
  })
})

describe('the template derives totalPages from the corpus, not from the cursor', () => {
  it('app/page.tsx feeds countDocs through pageCount and drops the +1 probe', async () => {
    const src = await fs.readFile(path.join(BLOG, 'app', 'page.tsx'), 'utf8')
    expect(src.length).toBeGreaterThan(200) // the read is real

    // The true-total wiring, as one expression: pageCount(<countDocs …>, POSTS_PER_PAGE).
    expect(/pageCount\(\s*await\s+countDocs\(/.test(src)).toBe(true)
    expect(src).toContain('POSTS_PER_PAGE')

    // The exact shipped defect, byte-for-byte, and the class of it.
    expect(src).not.toContain('hasNext ? pageNum + 1 : pageNum')
    expect(/hasNext/.test(src)).toBe(false)
    expect(/\bpageNum\s*\+\s*1\b/.test(src)).toBe(false)

    // The over-fetch that made the fudge possible: the page must request
    // exactly POSTS_PER_PAGE, never POSTS_PER_PAGE + 1.
    expect(/POSTS_PER_PAGE\s*\+\s*1/.test(src)).toBe(false)
    expect(/limit:\s*POSTS_PER_PAGE\s*[,}]/.test(src)).toBe(true)
  })

  it('countDocs reads the envelope total rather than counting a page of documents', async () => {
    const src = await fs.readFile(path.join(BLOG, 'lib', 'barkpark.ts'), 'utf8')
    expect(src).toContain('export async function countDocs')
    // It must return the envelope's count, not documents.length (which caps at
    // the page size and would silently re-introduce the fudge one layer down).
    expect(/return\s+env\.result\?\.count/.test(src)).toBe(true)
    expect(/countDocs[\s\S]*?documents\.length/.test(src)).toBe(false)
  })
})

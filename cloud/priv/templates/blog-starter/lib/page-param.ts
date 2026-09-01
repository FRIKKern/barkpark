/**
 * Pure, framework-free clamping of the caller-controlled `?page=` query param.
 *
 * WHY THIS IS NOT INLINE IN `app/page.tsx`
 *
 * The idiom this replaces —
 *
 *     Math.max(1, Math.floor(Number(sp.page ?? '1') || 1))
 *
 * — clamps only the LOWER bound, and it is a Server Component that feeds
 * `Pagination`, whose `Array.from({ length: totalPages })` then materialises one
 * `<Link>` per page ON THE SERVER, per request. Two anonymous requests break it:
 *
 *   ?page=20000   -> 20 000 <Link> elements rendered server-side, per request.
 *   ?page=Infinity -> `Number('Infinity')` is Infinity, which is TRUTHY, so it
 *                     slips past the `|| 1` fallback, and `Array.from` throws
 *                     `RangeError: Invalid array length` -> the route 500s.
 *
 * `|| 1` looks like a guard but only catches the FALSY results of `Number()`
 * (`NaN`, `0`, `-0`, `''`). `Infinity` is not falsy. `Number.isFinite` is the
 * guard that idiom is missing, and an upper clamp is the other half.
 *
 * Kept dependency-free (no 'server-only', no next/*, no @barkpark/* imports) so
 * it is unit-testable directly — see create-barkpark-app's
 * tests/template-page-param.test.ts, which imports THIS file.
 */

/** Hard ceiling on how many numbered page links a single render may build. */
export const MAX_PAGE_LINKS = 9

/** How many pages a corpus of `total` documents fills at `perPage` each. Always >= 1. */
export function pageCount(total: number, perPage: number): number {
  if (!Number.isFinite(total) || !Number.isFinite(perPage) || perPage < 1) return 1
  return Math.max(1, Math.ceil(Math.max(0, total) / perPage))
}

/**
 * Resolve `?page=` to a finite integer in `[1, totalPages]`.
 *
 * Anything that is not a finite number — absent, empty, `'abc'`, `'Infinity'`,
 * `'1e309'` (overflows to Infinity), `'NaN'`, an array of repeated params —
 * resolves to page 1. Anything above `totalPages` is clamped DOWN to it, so the
 * number that reaches `Array.from` is bounded by the corpus, never by the URL.
 */
export function resolvePageParam(raw: string | string[] | undefined, totalPages: number): number {
  const max = Number.isFinite(totalPages) ? Math.max(1, Math.floor(totalPages)) : 1
  // Next gives an array when the param repeats (`?page=2&page=9`); take the first.
  const first = Array.isArray(raw) ? raw[0] : raw
  if (typeof first !== 'string' || first.trim() === '') return 1
  const n = Number(first)
  if (!Number.isFinite(n)) return 1
  const floored = Math.floor(n)
  if (floored < 1) return 1
  return Math.min(floored, max)
}

/**
 * The bounded, contiguous run of page numbers a pagination control should
 * render, centred on `currentPage`.
 *
 * This is the SECOND half of the clamp, and it is deliberately independent of
 * the first: `resolvePageParam` bounds what the URL can ask for, and this bounds
 * what any caller — however it computed `totalPages` — can make the renderer
 * build. `Array.from({ length })` is only ever handed a value this function
 * produced, so it can never be `Infinity` and never exceed `MAX_PAGE_LINKS`.
 */
export function pageWindow(
  currentPage: number,
  totalPages: number,
  maxLinks: number = MAX_PAGE_LINKS,
): number[] {
  const cap = Number.isFinite(maxLinks) ? Math.max(1, Math.floor(maxLinks)) : MAX_PAGE_LINKS
  const total = Number.isFinite(totalPages) ? Math.max(1, Math.floor(totalPages)) : 1
  const current = Number.isFinite(currentPage)
    ? Math.min(Math.max(1, Math.floor(currentPage)), total)
    : 1

  const size = Math.min(cap, total)
  let start = current - Math.floor((size - 1) / 2)
  if (start < 1) start = 1
  if (start + size - 1 > total) start = total - size + 1

  return Array.from({ length: size }, (_, i) => start + i)
}

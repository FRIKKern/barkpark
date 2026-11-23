// A light's views read on pages of the one browser at once (check/view-pages.mjs gives the rule): the skins light's
// and the phone light's. Each page reads its share of the list in order; what a view adds to the light is kept
// apart and made in the list's order once every page is done, so the light reads the same on one page or on two.
import { spread, viewsRead } from './view-pages.mjs'

/** A read that ends the light at its view, as the first view to meet it would on one page. */
export const STOP = Symbol('the light ends at this view')

/**
 * `views` read on `pages` pages, by `what` (the light's name, for its lines). `open()` makes a page; `start(page)`
 * readies it and gives what `read` needs; `read(page, view, keep, ready)` reads one view, handing what it adds to
 * the light to `keep`, and may answer STOP; `end(page)` closes the page's own reading.
 * Gives the count line and its fail, the view the light stopped at (or null), and `once`, which takes a list of
 * fails and keeps each thing the census told where the list's order first reads it.
 * An error ends the light with the error of the first view in the list's order that meets one, as on one page; a
 * page that cannot open is red by name.
 */
export async function readOnPages({ views, pages, what, open, start, read, end }) {
  const shares = spread(views, pages)
  const count = viewsRead(views, shares, what)
  const kept = views.map(() => [])
  const opened = []
  // What the census tells (layers.mjs) is a fact of the page, not of the view, and each of the light's pages tells
  // it again. So each thing told is marked with its text and its place among the same texts in that view, and once
  // every page is done it is kept at the first view in the list's order that tells it, as often as that view does,
  // and dropped wherever it is told again: the light names it the same on one page or on two.
  const marks = new Map()
  const mark = (key) => {
    if (!marks.has(key)) marks.set(key, marks.size)
    return `⁠${marks.get(key)}⁠`
  }
  const viewOf = []
  const tellOnce = (page, j) => {
    const census = page.barkCensus
    if (!census) return
    const seen = new Map()
    const told = async (p) =>
      (await census(p)).map((s) => {
        const here = `${viewOf[j]}\u0000${s}`
        const k = (seen.get(here) ?? 0) + 1
        seen.set(here, k)
        return `${s}${mark(`${s}\u0000${k}`)}`
      })
    told.placement = census.placement
    page.barkCensus = told
  }
  const MARKED = /⁠(\d+)⁠$/
  const keptOnce = new Set()
  const once = (list) =>
    list.flatMap((l) => {
      const m = l.match(MARKED)
      if (!m) return [l]
      if (keptOnce.has(m[1])) return []
      keptOnce.add(m[1])
      return [l.replace(MARKED, '')]
    })
  // Each page goes on only through the views before the first that ends the light. Before its first view a page
  // is at -1.
  const errors = []
  let stopAt = Infinity
  const endAt = (i) => (stopAt = Math.min(stopAt, i))
  const onPage = async (j) => {
    let page
    try {
      page = await open()
    } catch (e) {
      errors.push({ i: -1, e: new Error(`${what} could not open its page ${j + 1} of ${shares.length}: ${String(e.message).split('\n')[0]}`) })
      return endAt(-1)
    }
    opened[j] = page
    tellOnce(page, j)
    let i = -1
    try {
      const ready = await start?.(page)
      for (const v of shares[j]) {
        i = views.indexOf(v)
        if (i > stopAt) return
        viewOf[j] = i
        if ((await read(page, v, (f) => kept[i]?.push(f), ready)) === STOP) return endAt(i)
      }
      i = views.length
      await end?.(page)
    } catch (e) {
      errors.push({ i, e })
      endAt(i)
    }
  }
  try {
    await Promise.all(shares.map((_, j) => onPage(j)))
    if (errors.length) throw errors.reduce((a, b) => (b.i < a.i ? b : a)).e
    for (const [i, k] of kept.entries()) if (i <= stopAt) for (const f of k) f()
  } finally {
    await Promise.all(opened.filter(Boolean).map((p) => p.context().close()))
  }
  return { count, once, stopped: Number.isFinite(stopAt) ? views[stopAt] : null }
}

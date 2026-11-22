// The one capture the check reads pixels from: every capture of the page under test and of the reference page.
// A capture is a read of the look, so it is bracketed: it counts only when the page was at rest before it and after
// it, and no motion started between (before and after, in probes.mjs). Otherwise it is taken again, inside settle's
// bound of 2 s; when the bound ends, it is red by name, the check's own red.

const BOUND_MS = 2000

/** A PNG (base64) of `clip` on `page`, bracketed by `world` (the check's own isolated world of that page).
    Playwright keeps the page's pixel ratio (a capture from a CDP session of our own resets the emulated ratio to 1
    for everything after it), and is told to leave the caret alone, so it adds no style of its own to the page: the
    check hides the caret itself, from its own world (caret in drawn.mjs). */
export async function capture(page, world, clip) {
  const until = Date.now() + BOUND_MS
  for (;;) {
    const mark = await world(() => window.__barkCheck.before('a capture'))
    let png
    let ok = false
    try {
      png = await page.screenshot({ clip: { x: clip.x, y: clip.y, width: clip.w, height: clip.h }, fullPage: true, scale: 'device', caret: 'initial' })
    } finally {
      ok = await world((m) => window.__barkCheck.after(m), mark)
    }
    if (ok) return png.toString('base64')
    if (Date.now() > until) throw new Error('the check could not read (not a fault of the part): read on a page not at rest: a capture: motion started while it was taken, every time inside the bound')
  }
}

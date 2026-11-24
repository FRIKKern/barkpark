// The one capture the check reads pixels from: every capture of the page under test and of the reference page.
// A capture is a read of the look, so it passes the same door as every other: the page comes to rest inside the
// bound, or the capture is red by name (still, in probes.mjs).

/** How many times a capture is taken before the check gives up on it: the first and two more. */
import { tick } from './probe-clock.mjs'
export const TRIES = 3
const shots = { taken: 0, again: 0, moved: 0 }
/** The run's line: how many captures were taken again because the page moved while they were taken, as a shot of the
    view or with a box placed against the view in the clip, and how many full-page ones moved with no such box in the
    clip and were read as taken. */
export const captureSentence = () =>
  `capture: ${shots.taken} captures, ${shots.again} taken again (the page moved during a shot of the view, or during a full-page shot with a box placed against the view in the clip), ${shots.moved} moved during a full-page shot with no such box in the clip and read as taken`

/** A PNG (base64) of `clip` on `page`, once `world` (the check's own isolated world of that page) finds it at rest.
    Playwright keeps the page's pixel ratio (a capture from a CDP session of our own resets the emulated ratio to 1
    for everything after it), and is told to leave the caret alone, so it adds no style of its own to the page: the
    check hides the caret itself, from its own world (caret in drawn.mjs).
    A clip that lies inside the view, on a page drawn at its own scale, is taken as the view shows it, not as a
    full-page capture: a full-page capture can move the page by itself (taken while focus is in a box over the page,
    or at some scroll spots at phone width), and a shot of the view leaves the page where it is. A clip that reaches
    beyond the view, or one on a page the phone shows zoomed out (a page with no viewport width of its own, as the
    reference tab is), needs the full page: a shot of a zoomed view is drawn at the zoom. So does a page's first shot: until a page has
    been drawn once for a full-page shot, a shot of its view can draw its text otherwise. Either way the page goes back to the scroll it had before the capture, and comes to rest there, before
    anything reads it again. A full-page capture draws the page where it lies on the page, so a move leaves it as it
    is, but a box placed against the view (position fixed or sticky) is drawn where the move put it: a capture during
    which the page moved with such a box in the clip is not read but taken again, up to TRIES times, and then the
    capture is red by name as the check's own. A shot of the view draws the view wherever the move put it, so one
    taken when the page moved after the view was read, whatever is in the clip, is taken again the same way. */
export async function capture(page, world, clip) {
  const tw = performance.now()
  await world(() => window.__barkCheck.still('a capture'))
  tick('still-before-shot', performance.now() - tw)
  // The view as the screen shows it (the visual viewport, without scrollbars): what a shot of the view draws.
  const [left, top, vx, vy, vw, vh, zoom, drawn] = await world(() => {
    const v = visualViewport
    return [scrollX, scrollY, v.pageLeft, v.pageTop, v.width, v.height, v.scale, window.__barkFullShot === true]
  })
  const inView = drawn && zoom === 1 && clip.x >= vx && clip.y >= vy && clip.x + clip.w <= vx + vw && clip.y + clip.h <= vy + vh
  // Playwright reads a clip on the full page from the page's corner, and a clip of the view from the view's.
  const shot = inView
    ? { clip: { x: clip.x - vx, y: clip.y - vy, width: clip.w, height: clip.h }, fullPage: false }
    : { clip: { x: clip.x, y: clip.y, width: clip.w, height: clip.h }, fullPage: true }
  shots.taken++
  for (let n = 1; ; n++) {
    const t0 = performance.now()
    const png = await page.screenshot({ ...shot, scale: 'device', caret: 'initial' })
    tick(inView ? 'shot-view' : 'shot-full', performance.now() - t0)
    if (!inView && !drawn) await world(() => (window.__barkFullShot = true))
    const moved = await world(async ([left, top, c]) => {
      if (scrollX === left && scrollY === top) return null
      const was = [scrollX, scrollY]
      scrollTo({ left, top, behavior: 'instant' })
      await window.__barkCheck.still('the page after a capture')
      // A box placed against the view in the clip lies in the view: what the browser draws at every 8th pixel of
      // the clip inside the view, and the boxes that hold it, are asked for their position. Only what is drawn is
      // asked, so a box the browser skips (a closed details' content) is not brought up to date by the question.
      const [l, t] = [Math.max(c.x, scrollX), Math.max(c.y, scrollY)]
      const [r, b] = [Math.min(c.x + c.w, scrollX + innerWidth), Math.min(c.y + c.h, scrollY + innerHeight)]
      const hit = new Set()
      for (let y = t; y < b; y += 8) for (let x = l; x < r; x += 8) for (const n of document.elementsFromPoint(x - scrollX, y - scrollY)) hit.add(n)
      const placed = (n) => n && (['fixed', 'sticky'].includes(getComputedStyle(n).position) || placed(n.parentElement))
      return { was, pinned: [...hit].some(placed) }
    }, [left, top, clip])
    if (!moved) return png.toString('base64')
    if (!inView && !moved.pinned) {
      shots.moved++
      return png.toString('base64')
    }
    if (n === TRIES) throw new Error(`the check could not read (not a fault of the part): the page moved during the capture ${TRIES} times, from scroll ${left}, ${top} to ${moved.was.join(', ')}`)
    shots.again++
  }
}

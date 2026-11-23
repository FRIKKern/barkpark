// The one capture the check reads pixels from: every capture of the page under test and of the reference page.
// A capture is a read of the look, so it passes the same door as every other: the page comes to rest inside the
// bound, or the capture is red by name (still, in probes.mjs).

/** How many times a capture is taken before the check gives up on it: the first and two more. */
export const TRIES = 3
const shots = { taken: 0, again: 0, moved: 0 }
/** The run's line: how many captures were taken again because the page moved while they were taken with a box placed
    against the view in the clip, and how many moved with no such box in the clip and were read as taken. */
export const captureSentence = () =>
  `capture: ${shots.taken} captures, ${shots.again} taken again (the page moved during the shot, a box placed against the view in the clip), ${shots.moved} moved during the shot with no such box in the clip and read as taken`

/** A PNG (base64) of `clip` on `page`, once `world` (the check's own isolated world of that page) finds it at rest.
    Playwright keeps the page's pixel ratio (a capture from a CDP session of our own resets the emulated ratio to 1
    for everything after it), and is told to leave the caret alone, so it adds no style of its own to the page: the
    check hides the caret itself, from its own world (caret in drawn.mjs).
    The capture can move the page by itself (a full-page capture taken while focus is in a box over the page can
    scroll it). So the page goes back to the scroll it had before the capture, and comes to rest there, before
    anything reads it again. A full-page capture draws the page where it lies on the page, so a move leaves it as it
    is, but a box placed against the view (position fixed or sticky) is drawn where the move put it: a capture during
    which the page moved with such a box in the clip is not read but taken again, up to TRIES times, and then the
    capture is red by name as the check's own. */
export async function capture(page, world, clip) {
  await world(() => window.__barkCheck.still('a capture'))
  const at = await world(() => [scrollX, scrollY])
  shots.taken++
  for (let n = 1; ; n++) {
    const png = await page.screenshot({ clip: { x: clip.x, y: clip.y, width: clip.w, height: clip.h }, fullPage: true, scale: 'device', caret: 'initial' })
    const moved = await world(async ([left, top, c]) => {
      if (scrollX === left && scrollY === top) return null
      const was = [scrollX, scrollY]
      scrollTo({ left, top, behavior: 'instant' })
      await window.__barkCheck.still('the page after a capture')
      // A box placed against the view whose box, on the page, meets the clip.
      const meets = (r) => r.left + scrollX < c.x + c.w && r.right + scrollX > c.x && r.top + scrollY < c.y + c.h && r.bottom + scrollY > c.y
      const pinned = [...document.querySelectorAll('*')].some((n) => ['fixed', 'sticky'].includes(getComputedStyle(n).position) && [...n.getClientRects()].some(meets))
      return { was, pinned }
    }, [...at, clip])
    if (!moved) return png.toString('base64')
    if (!moved.pinned) {
      shots.moved++
      return png.toString('base64')
    }
    if (n === TRIES) throw new Error(`the check could not read (not a fault of the part): the page moved during the capture ${TRIES} times, from scroll ${at.join(', ')} to ${moved.was.join(', ')}`)
    shots.again++
  }
}

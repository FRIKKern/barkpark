// The checker's input on a page: keys and the pointer, each made here and nowhere else (the wall round a page the
// check opens, check/wall.mjs, refuses it from any other file). After it comes its rest step, afterAct in
// check/probes.mjs: a frame is drawn, so what the input started shows, then the page comes to rest inside the bound
// before the next read (after a key, the browser's scroll of the element with focus into view included), or the act
// is red there, named with the file and line the checker made it from. A pointer move to the point the pointer is
// already at is no input, and is not made.

/** Where the checker made the act: the first caller outside this file, as check/<file>.mjs:<line>. */
function where() {
  for (const l of new Error().stack.split('\n').slice(1)) {
    if (l.includes('/check/acts.mjs')) continue
    const m = l.match(/\/(check\/[\w.-]+\.mjs):(\d+)/)
    if (m) return `${m[1]}:${m[2]}`
  }
  return 'an unknown place'
}
const rested = (page, act, at, kind = 'pointer') => page.barkCheck((a) => window.__barkCheck.afterAct(a), [`${act} at ${at}`, kind])

/** Where the checker last put the pointer on each page; unknown until it first does. */
const pointer = new WeakMap()
/** The run's pointer moves: made, and not made because the pointer was already at that point. */
export const MOVES = { made: 0, skipped: 0 }
export const movesLine = () => `pointer moves: ${MOVES.made} made, ${MOVES.skipped} not made because the pointer was already at that point`

/** A key pressed and let go. */
export async function press(page, key) {
  const at = where()
  await page.keyboard.press(key)
  await rested(page, `the key ${key}`, at, 'key')
}

/** A click at a point. */
export async function click(page, x, y) {
  const at = where()
  await page.mouse.click(x, y)
  pointer.set(page, { x, y })
  await rested(page, 'a click', at)
}

/** A click at the middle of the element `selector` names, scrolled into view first. */
export async function clickOn(page, selector) {
  const { x, y } = await page.barkCheck((s) => {
    const el = document.querySelector(s)
    el.scrollIntoView({ block: 'nearest', inline: 'nearest', behavior: 'instant' })
    const r = el.getBoundingClientRect()
    return { x: r.left + r.width / 2, y: r.top + r.height / 2 }
  }, selector)
  await click(page, x, y)
}

/** The pointer moved to a point. */
export async function pointTo(page, x, y) {
  const at = where()
  const was = pointer.get(page)
  if (was && was.x === x && was.y === y) {
    MOVES.skipped++
    return
  }
  await page.mouse.move(x, y)
  pointer.set(page, { x, y })
  MOVES.made++
  await rested(page, 'the pointer moved', at)
}

/** The pointer's button held down where the pointer is. */
export async function pointerDown(page) {
  const at = where()
  await page.mouse.down()
  await rested(page, 'the pointer pressed', at)
}

/** The pointer's button let go. */
export async function pointerUp(page) {
  const at = where()
  await page.mouse.up()
  await rested(page, 'the pointer let go', at)
}

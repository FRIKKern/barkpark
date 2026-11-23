// The checker's input on a page: keys and the pointer, each made here and nowhere else (a test holds that, by
// file and line: check/motion.mjs ACTS). Each is followed by its rest step, afterAct in check/probes.mjs: a frame
// is drawn, so what the input started shows, then the page comes to rest inside the bound before the next read,
// or the act is red there, named with the file and line the checker made it from.

/** Where the checker made the act: the first caller outside this file, as check/<file>.mjs:<line>. */
function where() {
  for (const l of new Error().stack.split('\n').slice(1)) {
    if (l.includes('/check/acts.mjs')) continue
    const m = l.match(/\/(check\/[\w.-]+\.mjs):(\d+)/)
    if (m) return `${m[1]}:${m[2]}`
  }
  return 'an unknown place'
}
const rested = (page, act, at) => page.barkCheck((who) => window.__barkCheck.afterAct(who), `${act} at ${at}`)

/** A key pressed and let go. */
export async function press(page, key) {
  const at = where()
  await page.keyboard.press(key)
  await rested(page, `the key ${key}`, at)
}

/** A click at a point. */
export async function click(page, x, y) {
  const at = where()
  await page.mouse.click(x, y)
  await rested(page, 'a click', at)
}

/** The pointer moved to a point. */
export async function pointTo(page, x, y) {
  const at = where()
  await page.mouse.move(x, y)
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

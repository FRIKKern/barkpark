// The checker's input on a page: keys and the pointer, each made here and nowhere else (a test holds that, by
// file and line: check/motion.mjs ACTS). Each is followed by its rest step, afterAct in check/probes.mjs: a frame
// is drawn, so what the input started shows, then the page comes to rest inside the bound before the next read.

const rested = (page) => page.barkCheck(() => window.__barkCheck.afterAct())

/** A key pressed and let go. */
export async function press(page, key) {
  await page.keyboard.press(key)
  await rested(page)
}

/** A click at a point. */
export async function click(page, x, y) {
  await page.mouse.click(x, y)
  await rested(page)
}

/** The pointer moved to a point. */
export async function pointTo(page, x, y) {
  await page.mouse.move(x, y)
  await rested(page)
}

/** The pointer's button held down where the pointer is. */
export async function pointerDown(page) {
  await page.mouse.down()
  await rested(page)
}

/** The pointer's button let go. */
export async function pointerUp(page) {
  await page.mouse.up()
  await rested(page)
}

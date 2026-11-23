// The one capture the check reads pixels from: every capture of the page under test and of the reference page.
// A capture is a read of the look, so it passes the same door as every other: the page comes to rest inside the
// bound, or the capture is red by name (still, in probes.mjs).

/** A PNG (base64) of `clip` on `page`, once `world` (the check's own isolated world of that page) finds it at rest.
    Playwright keeps the page's pixel ratio (a capture from a CDP session of our own resets the emulated ratio to 1
    for everything after it), and is told to leave the caret alone, so it adds no style of its own to the page: the
    check hides the caret itself, from its own world (caret in drawn.mjs). */
export async function capture(page, world, clip) {
  await world(() => window.__barkCheck.still('a capture'))
  const png = await page.screenshot({ clip: { x: clip.x, y: clip.y, width: clip.w, height: clip.h }, fullPage: true, scale: 'device', caret: 'initial' })
  return png.toString('base64')
}

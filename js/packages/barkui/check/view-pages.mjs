// The skins light's views on pages of the one browser at once (check/proofs.mjs skinsAndSchemes): one rule over the
// list of views, nothing named. Each view is read on one page; what a view adds to the light is made in the list's
// order once every page is done, so the light reads the same on any number of pages. A view on no page, or on two,
// is red by name, and so is a page that cannot open: the light never reads quietly on fewer pages or fewer views.

/** How many pages the skins light reads its views on at once. */
export const VIEW_PAGES = 2

/** The views the skins light reads, in order: each skin in light, then each in dark. */
export const viewList = (skins) => ['light', 'dark'].flatMap((scheme) => skins.map((skin) => ({ skin, scheme })))

/** The views each of `n` pages reads: view i on page i mod n. */
// PLANT: the second view is left on no page.
export const spread = (views, n = VIEW_PAGES) => Array.from({ length: n }, (_, j) => views.filter((_, i) => i % n === j && i !== 1))

/** The count line, made from the list and the pages' shares, and the fail when any view is read on more than one
    page, on none, or is not on the list. */
export function viewsRead(views, shares) {
  const times = views.map((v) => shares.filter((s) => s.includes(v)).length)
  const twice = times.filter((t) => t > 1).length
  const none = times.filter((t) => t === 0).length
  const stray = shares.flat().filter((v) => !views.includes(v)).length
  const line = `views the skins light read: ${views.length - none} of ${views.length}; on two pages: ${twice}; on none: ${none}${stray ? `; off the list: ${stray}` : ''}`
  const named = (t) => views.filter((_, i) => t(times[i])).map((v) => `${v.skin} ${v.scheme}`).join(', ')
  const fail = none || twice || stray ? `the skins light's pages do not read each view once: ${line}${none ? ` (on none: ${named((t) => t === 0)})` : ''}${twice ? ` (on two: ${named((t) => t > 1)})` : ''}` : null
  return { line, fail }
}

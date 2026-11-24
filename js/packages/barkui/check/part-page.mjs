// The page each part is read on: the run's page (check/check.mjs), with the stage of every other part hidden but the
// one that follows it. Every stage is still printed, so every part's elements connect and its demo runs, and what UI
// SDK writes to the page for any of them is there as it is on the run's page (the dialog's stage writes UI SDK's
// hidden sheet at load, which the menu would otherwise write when it first opens). Only the part's own stage and the
// one that follows it are drawn (a stage reads otherwise at the end of a page). On CI's hosted runner three parts at
// once fill the runner's cores, most of it the browser drawing and styling stages a part does not read, so a part's
// time grew with the stages beside it; on this page it does not.
import { readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'

/** The file name of the page `name` is read on, beside the run's page. */
export const partPageName = (name) => `index-${name}.html`

/** The run's page `html`, whose stages are `order` in page order, with every stage but `name`'s and the one after
    it hidden. Refuses a part the page does not print, and a stage the page does not print exactly once. */
export function hideOthers(html, order, name) {
  const at = order.indexOf(name)
  if (at < 0) throw new Error(`check: the page prints no stage of ${name}`)
  const shown = order.slice(at, at + 2)
  let out = html
  for (const n of order) {
    const open = `<section class="sr-part" id="part-${n}"`
    const times = out.split(open).length - 1
    if (times !== 1) throw new Error(`check: the page prints the stage of ${n} ${times} times, not once`)
    if (!shown.includes(n)) out = out.replace(open, `${open} hidden`)
  }
  return out
}

/** Writes the page `name` is read on beside the run's page `file` (so it loads the same sheets and script) and
    gives its path. */
export function writePartPage(file, order, name) {
  const to = join(dirname(file), partPageName(name))
  writeFileSync(to, hideOthers(readFileSync(file, 'utf8'), order, name))
  return to
}

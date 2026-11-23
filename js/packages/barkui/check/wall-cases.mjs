// The wall round the browser library (check/acts.mjs, check/wall.mjs), proved: on a wall page, each input form in
// check/wall-plants.mjs is refused by name at that file, one made in a timer or an event listener too, and none
// ends the run; a name read with no file of the check on the stack is refused by name too. The selftest reads N of M
// for each list: M is the list's length.
import { launch, refusals } from './acts.mjs'
import { NO_FRAME, OWN, SEEN } from './wall-plants.mjs'

const AT = 'check/wall-plants.mjs:'
/** The refusals this row makes on purpose with no file on the stack, by their place in the run's list: the selftest
    leaves them out of every case's own refusals. */
export const PLANTED = new Set()

/** How many of `plants` the wall refused, each made on `page` and held by `held` (the refusals it made); one not
    refused is named. */
async function refusedOf(page, plants, held) {
  let n = 0
  for (const [name, make] of plants) {
    const r0 = refusals().length
    const got = await Promise.resolve()
      .then(() => make(page))
      .then(() => 'made', (e) => String(e.message))
    // A timer's or a listener's refusal comes after the plant returns.
    await page.waitForTimeout(100)
    if (held(name, refusals().slice(r0))) n++
    else console.log(`    not refused: ${name}: ${got.slice(0, 160)}`)
  }
  return n
}

async function wallHolds() {
  const browser = await launch()
  try {
    const page = await (await browser.newContext()).newPage()
    await page.setContent('<!doctype html><button id="x">x</button><div id="a" draggable="true">a</div><div id="b">b</div>')
    const atFile = (_, made) => made.some((r) => r.at.startsWith(AT))
    const seen = await refusedOf(page, SEEN.map((make, i) => [`the review's plant ${i + 1}`, make]), atFile)
    const own = await refusedOf(page, Object.entries(OWN), atFile)
    const unfiled = (name, made) => {
      for (const r of made) if (r.at === 'an unknown file') PLANTED.add(r.n)
      return made.some((r) => r.what === NO_FRAME[name].what && r.at === 'an unknown file')
    }
    const bare = await refusedOf(page, Object.entries(NO_FRAME).map(([name, x]) => [name, x.make]), unfiled)
    console.log(`    the wall refused ${seen} of ${SEEN.length} of the review's plants and ${own} of ${Object.keys(OWN).length} of the selftest's own forms, each by name at ${AT.slice(0, -1)}, and ${bare} of ${Object.keys(NO_FRAME).length} names read with no file of the check on the stack, each by name`)
    return seen === SEEN.length && own === Object.keys(OWN).length && bare === Object.keys(NO_FRAME).length
  } finally {
    await browser.close()
  }
}

export const WALL_CASES = [
  {
    name: "the checker's input: on a wall page every name off the wall's list is refused by name and file, from a timer or a listener too, and no refusal ends the run",
    direct: wallHolds,
  },
]

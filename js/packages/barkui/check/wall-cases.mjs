// The wall round the browser library (check/acts.mjs, check/wall.mjs), proved: on a wall page, each input form in
// check/wall-plants.mjs is refused by name at that file, one made in a timer or an event listener too, and none
// ends the run. The selftest reads N of M for each list: M is the list's length.
import { launch, refusals } from './acts.mjs'
import { OWN, SEEN } from './wall-plants.mjs'

const AT = 'check/wall-plants.mjs:'

/** How many of `plants` the wall refused at check/wall-plants.mjs, each made on `page`; one not refused is named. */
async function refusedOf(page, plants) {
  let held = 0
  for (const [name, make] of plants) {
    const r0 = refusals().length
    const got = await Promise.resolve()
      .then(() => make(page))
      .then(() => 'made', (e) => String(e.message))
    // A timer's or a listener's refusal comes after the plant returns.
    await page.waitForTimeout(100)
    if (refusals().slice(r0).some((r) => r.at.startsWith(AT))) held++
    else console.log(`    not refused: ${name}: ${got.slice(0, 160)}`)
  }
  return held
}

async function wallHolds() {
  const browser = await launch()
  try {
    const page = await (await browser.newContext()).newPage()
    await page.setContent('<!doctype html><button id="x">x</button><div id="a" draggable="true">a</div><div id="b">b</div>')
    const seen = await refusedOf(page, SEEN.map((make, i) => [`the review's plant ${i + 1}`, make]))
    const own = await refusedOf(page, Object.entries(OWN))
    console.log(`    the wall refused ${seen} of ${SEEN.length} of the review's plants and ${own} of ${Object.keys(OWN).length} of the selftest's own forms, each by name at ${AT.slice(0, -1)}`)
    return seen === SEEN.length && own === Object.keys(OWN).length
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

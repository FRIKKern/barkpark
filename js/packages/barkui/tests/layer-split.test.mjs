// The top layer's readings and census were one selftest run; they are two, so each stays under the selftest's
// time for one case. These hold that every row of the one run is in exactly one of the two, so none was dropped
// to make room, and the check that says so is red by the row's name. And every top-layer case runs in the rest
// job, by the runner's own pick, red by the case's name when one would run in the views job.
import { describe, expect, it } from 'vitest'
import { selftestPick } from '../check/jobs.mjs'
import { LAYER_CASES, rowsMoved, TOP_LAYER_ROWS } from '../check/layer-cases.mjs'
import { CASES } from '../check/selftest.mjs'

// The rows of the one run, as it held them before it was split in two.
const ONE_RUN = [
  'a named popover, opened by a click, read open',
  'a named hint, opened by hover, read open',
  'a box open from the start, named by no layer, in the reading',
  'a tooltip open only at its Tab stop, named by no layer',
  'a tooltip shown 400 ms after focus or hover, named by no layer',
  'a tooltip on hover over a plain span, named by no layer',
  'a dialog never opened, named by no layer',
  'a box with popover made and gone again between looks',
  'a box given popover and losing it again between looks',
  'a box in a shadow root attached after its host is in the page, gone before the next look',
  'a dialog in a shadow root attached late inside another late root',
  "a box in a shadow root attached by a frame's attachShadow",
  'a box in a shadow root parsed from markup, with no attachShadow call',
  'a frame in the page, refused by name',
  "a box made as the page loads and gone before the check's first look",
  'a named box that opens 400 ms after its input',
  'every layer that opens at once read in every view',
  'the looks were made',
]

describe('the two top-layer runs', () => {
  it('hold every row of the one run they replace, each in exactly one of them', () => {
    expect(rowsMoved(ONE_RUN, TOP_LAYER_ROWS)).toEqual([])
  })

  it('are red by the row’s name when a row is dropped or doubled', () => {
    const row = 'a frame in the page, refused by name'
    const { popover, census } = TOP_LAYER_ROWS
    expect(rowsMoved(ONE_RUN, { popover, census: census.filter((r) => r !== row) })).toEqual([`the row "${row}" is in neither top-layer run`])
    expect(rowsMoved(ONE_RUN, { popover: [...popover, row], census })).toEqual([`the row "${row}" is in both top-layer runs (popover, census)`])
    expect(rowsMoved(ONE_RUN, { popover, census: [...census, row] })).toEqual([`the row "${row}" is in the census run 2 times`])
  })
})

/** Each top-layer case among `cases` that the rest job does not run, by name. */
const notInRest = (cases) => {
  const rest = new Set(selftestPick(cases, 'rest').map((c) => c.name))
  return LAYER_CASES.filter((c) => !rest.has(c.name)).map((c) => `the top-layer case "${c.name}" is not in the rest job`)
}

describe('the top-layer cases', () => {
  it('each run in the rest job, by the runner’s own pick', () => {
    expect(notInRest(CASES)).toEqual([])
  })

  it('are red by the case’s name when one loses its `layers` flag', () => {
    for (const c of LAYER_CASES.filter((x) => x.layers)) {
      const planted = CASES.map((x) => (x === c ? { ...x, layers: undefined } : x))
      expect(notInRest(planted)).toEqual([`the top-layer case "${c.name}" is not in the rest job`])
    }
  })
})

// The top layer's readings and census were one selftest run; they are three, so each stays under the selftest's
// time for one case. These hold that every row of the one run is in exactly one of the three, so none was dropped
// to make room, and the check that says so is red by the row's name. And every top-layer case runs in the layers
// job or the open job split off it, by the runner's own pick, red by the case's name when one would run in a job
// that reads the views.
import { describe, expect, it } from 'vitest'
import { layerMisplaced, rowsMoved, selftestPick } from '../check/jobs.mjs'
import { LAYER_CASES, TOP_LAYER_ROWS } from '../check/layer-cases.mjs'
import { FRAME, REFUSED, topLayerTouch, UNNAMED, UNNAMED_CAN } from '../check/layers.mjs'
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

describe('the three top-layer runs', () => {
  it('hold every row of the one run they replace, each in exactly one of them', () => {
    expect(rowsMoved(ONE_RUN, TOP_LAYER_ROWS, 'top-layer')).toEqual([])
  })

  it('are red by the row’s name when a row is dropped or doubled', () => {
    const row = 'a frame in the page, refused by name'
    const { popover, unnamed, census } = TOP_LAYER_ROWS
    expect(rowsMoved(ONE_RUN, { popover, unnamed, census: census.filter((r) => r !== row) }, 'top-layer')).toEqual([`the row "${row}" is in no top-layer run`])
    expect(rowsMoved(ONE_RUN, { popover: [...popover, row], unnamed, census }, 'top-layer')).toEqual([`the row "${row}" is in 2 top-layer runs (popover, census)`])
    expect(rowsMoved(ONE_RUN, { popover, unnamed, census: [...census, row] }, 'top-layer')).toEqual([`the row "${row}" is in the census top-layer run 2 times`])
  })
})

/** Each top-layer case among `cases` that neither the layers job nor the open job split off it runs, by name. */
const notInLayers = (cases) => {
  const layers = new Set(['layers', 'open'].flatMap((k) => selftestPick(cases, k)).map((c) => c.name))
  return LAYER_CASES.filter((c) => !layers.has(c.name)).map((c) => `the top-layer case "${c.name}" is not in the layers job`)
}

describe('the top-layer cases', () => {
  it('each run in the layers job or the open job, by the runner’s own pick', () => {
    expect(notInLayers(CASES)).toEqual([])
  })

  it('are red by the case’s name when one loses its `layers` flag', () => {
    for (const c of LAYER_CASES.filter((x) => x.layers)) {
      const planted = CASES.map((x) => (x === c ? { ...x, layers: undefined } : x))
      expect(notInLayers(planted)).toEqual([`the top-layer case "${c.name}" is not in the layers job`])
    }
  })
})

// The runner asks every case it runs how its run touched the top layer, so a NEW case that forgets the flag is
// caught by what it does (it names a layer, or its run says a top-layer fail), not by a list of names.
describe('a case that opens a layer or holds a layer refusal', () => {
  const proof = (line) => ({ parts: { button: { lights: { skins: { pass: false, fails: [`brand light on base: ${line}`] } } } } })
  const plain = proof('drawn text 3.10:1 at span "Save"')

  it('is told by what its run did', () => {
    expect(topLayerTouch([{ box: '#x' }], plain)).toBe('its part names a layer')
    for (const line of [UNNAMED('div#x "X"'), UNNAMED_CAN('div#x "X"'), FRAME('iframe#x ""'), REFUSED['window.open'], REFUSED['document.open'], REFUSED.page])
      expect(topLayerTouch(undefined, proof(line)), line).toMatch(/^its run says "/)
    expect(topLayerTouch(undefined, plain)).toBe('')
    expect(topLayerTouch([], plain)).toBe('')
  })

  it('is red by the case’s name when it would run in a job that reads the views, and a layers case that does neither is red too', () => {
    const fresh = { name: 'a new top-layer case', only: ['skins'], plant: () => {} }
    const touch = topLayerTouch(undefined, proof(UNNAMED_CAN('div#x "X"')))
    expect(layerMisplaced(fresh, touch)).toMatch(/^"a new top-layer case" runs in the views job, but its run says "can open in the top layer/)
    expect(layerMisplaced({ ...fresh, layers: true }, touch)).toBe('')
    expect(layerMisplaced({ ...fresh, layers: true }, '')).toBe('"a new top-layer case" is a layers case, but its run opens no layer and holds no layer refusal')
    expect(layerMisplaced(fresh, '')).toBe('')
    // A case that reads every surface reads the views too, and is red the same way.
    expect(layerMisplaced({ ...fresh, surfaces: true }, touch)).toMatch(/^"a new top-layer case" runs in the surfaces job, but its run says "can open in the top layer/)
    // A states case runs in the rest or the states job whatever it touches.
    expect(layerMisplaced({ ...fresh, states: true }, touch)).toBe('')
    expect(layerMisplaced({ ...fresh, states: true, css: 'x' }, touch)).toBe('')
  })
})

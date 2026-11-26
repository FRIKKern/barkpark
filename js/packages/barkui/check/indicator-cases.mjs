// The selftest's cases for the sliding indicator of UI SDK's tabs and segmented control (check/placement.mjs SLOTS):
// the six places UI SDK writes on each indicator pass there, and only there, only as a number of pixels.
import { appendFileSync } from 'node:fs'
import { join } from 'node:path'
import { NOT_PLACEMENT, SLOT_VALUE, SLOTS } from './placement.mjs'
import { all, edit, inDemo, each, lights } from './plants.mjs'
import { slider, withSlider } from './slider-cases.mjs'

// demo.mjs's lint refuses the word "style" spelled out: the plants spell it in two.
const S = "const S = 'sty' + 'le'"
const row = (d, html) => appendFileSync(join(d, 'example.html'), `<div data-demo-row>\n<span data-demo-label>Indicators</span>\n${html}\n</div>\n`)
const withBoth = (d) => edit(join(d, 'part.json'), (s) => JSON.stringify({ ...JSON.parse(s), imports: [...JSON.parse(s).imports, '@ui-sdk/web/tabs', '@ui-sdk/web/segmented-control'] }, null, 2))
const said = (p) => JSON.stringify(p?.parts?.button ?? {})
const has = (s) => (p) => said(p).includes(JSON.stringify(s).slice(1, -1))
const STYLE_FAIL = /in a style attribute|carries a style attribute/

/** UI SDK tabs, two tabs, with the sliding indicator in the list. */
const tabs = (id) =>
  `<ui-tabs id="${id}" default-value="a"><ui-tabs-list id="${id}-list" aria-label="Pick">` +
  `<ui-tabs-tab value="a"><button id="${id}-a" type="button">First</button></ui-tabs-tab>` +
  `<ui-tabs-tab value="b"><button id="${id}-b" type="button">Second</button></ui-tabs-tab>` +
  `<ui-tabs-indicator id="${id}-ind"></ui-tabs-indicator></ui-tabs-list></ui-tabs>`
/** A UI SDK segmented control, two items, with its sliding indicator. */
const segmented = (id) => `<ui-segmented-control id="${id}" default-value="a" aria-label="Pick one">
  <ui-segmented-control-item id="${id}-a" value="a">One</ui-segmented-control-item>
  <ui-segmented-control-item id="${id}-b" value="b">Two</ui-segmented-control-item>
  <ui-segmented-control-indicator id="${id}-ind"></ui-segmented-control-indicator>
</ui-segmented-control>`

// A click on the second tab, then on the second item, moves each choice; each indicator then carries the six places
// UI SDK measured on the one chosen.
const STEPS = `
steps.push({
  name: 'A click on the second tab selects it, and UI SDK has written the six places on its indicator',
  click: '#button-it-b',
  expect: (root) => {
    const b = root.querySelector('#button-it-b')
    const sides = ['left', 'right', 'top', 'bottom', 'width', 'height']
    const ind = root.querySelector('#button-it-ind')
    const bare = sides.filter((s) => !ind.style.getPropertyValue('--active-tab-' + s))
    return (b.getAttribute('aria-selected') === 'true' && !bare.length) || \`second tab selected: \${b.getAttribute('aria-selected')}, places not written: \${bare.join(', ') || 'none'}\`
  },
})
steps.push({
  name: 'A click on the second item checks it, and UI SDK has written the six places on its indicator',
  click: '#button-is-b',
  expect: (root) => {
    const b = root.querySelector('#button-is-b')
    const sides = ['left', 'right', 'top', 'bottom', 'width', 'height']
    const ind = root.querySelector('#button-is-ind')
    const bare = sides.filter((s) => !ind.style.getPropertyValue('--segmented-control-indicator-' + s))
    return (b.getAttribute('aria-checked') === 'true' && !bare.length) || \`second item checked: \${b.getAttribute('aria-checked')}, places not written: \${bare.join(', ') || 'none'}\`
  },
})
`

// Places UI SDK can write, as layoutBox measures them: a hair under 0, and a float's error as an exponent. Written a
// frame after both are made; UI SDK writes over them as it measures again, and the log holds both.
const EDGES = [
  S,
  "Promise.all([customElements.whenDefined('ui-tabs-indicator'), customElements.whenDefined('ui-segmented-control-indicator')]).then(() => requestAnimationFrame(() => {",
  "  root.querySelector('#button-it-ind')[S]['set' + 'Property']('--active-tab-right', '-0.3125px')",
  "  root.querySelector('#button-is-ind')[S]['set' + 'Property']('--segmented-control-indicator-right', '1.1368683772161603e-13px')",
  '}))',
].join('\n')

// Written as the page loads, a frame after both are made: a tab's place on a tab and on the tab list, a segmented
// place on an item, each part's place on the other part's indicator, places that are not a number of pixels (a
// percentage, px with no number, NaN and Infinity), and a number of pixels on a slider's piece, which UI SDK writes
// only as a percentage.
const WRITES = [
  S,
  "Promise.all([customElements.whenDefined('ui-tabs-indicator'), customElements.whenDefined('ui-segmented-control-indicator')]).then(() => requestAnimationFrame(() => {",
  "  const set = (sel, prop, value) => root.querySelector(sel)[S]['set' + 'Property'](prop, value)",
  "  set('#button-itx-a', '--active-tab-left', '0px')",
  "  set('#button-itx-list', '--active-tab-width', '40px')",
  "  set('#button-isx-a', '--segmented-control-indicator-left', '0px')",
  "  set('#button-isx-ind', '--active-tab-width', '40px')",
  "  set('#button-itx-ind', '--segmented-control-indicator-top', '0px')",
  "  set('#button-isx-ind', '--segmented-control-indicator-height', '50%')",
  "  set('#button-itx-ind', '--active-tab-left', 'px')",
  "  set('#button-itx-ind', '--active-tab-top', 'NaNpx')",
  "  set('#button-itx-ind', '--active-tab-width', 'Infinitypx')",
  "  set('#button-slpx-indicator', '--slider-indicator-start', '12px')",
  '}))',
].join('\n')
const SEGMENTED = 'ui-segmented-control-indicator'
const TABS = 'ui-tabs-indicator'
const TABS_AT = 'ui-tabs-indicator#button-itx-ind ""'
const SLIDER = 'ui-slider-indicator'
// A write the list does not hold stands in with no value, so on a list without it each row is read and is not caught.
const write = (name, property) => SLOTS.find((s) => s.slot === name)?.writes.find((w) => w.property === property) ?? { property, values: [] }

export const INDICATOR_CASES = [
  {
    name: 'placement: UI SDK tabs and a segmented control, each choice moved by a click, write only their six places on their own sliding indicator, and that passes, a place a hair under 0 or with an exponent among them',
    only: ['pressed'],
    green: true,
    plant: all((d) => row(d, `${tabs('button-it')}\n${segmented('button-is')}`), withBoth, (d) => appendFileSync(join(d, 'press.mjs'), STEPS), (d) => inDemo(d, EDGES)),
    expect: each({
      'every press step passed, each choice moved and both indicators written among them': (p) => lights(p).pressed?.pass === true && (p?.parts?.button?.steps ?? []).length > 0,
      'no fail names a style attribute: not on either indicator': (p) => !STYLE_FAIL.test(said(p)),
      'a place a hair under 0, -0.3125px, passes on the tabs indicator': (p) => !said(p).includes('-0.3125px'),
      'a place written with an exponent, 1.1368683772161603e-13px, passes on the segmented indicator': (p) => !said(p).includes('e-13px'),
    }),
  },
  {
    name: "placement: an indicator's places stand only on its own part's indicator, as a number of pixels: one on a tab, the tab list or an item, one part's on the other's indicator, a place that is not a number of pixels, and pixels on a slider's piece fail by name",
    only: ['pressed'],
    plant: all((d) => row(d, `${tabs('button-itx')}\n${segmented('button-isx')}\n${slider('button-slpx', '40')}`), withBoth, withSlider, (d) => inDemo(d, WRITES)),
    expect: each({
      "a tab's place on a tab fails by name": has(NOT_PLACEMENT('button#button-itx-a "First"', '--active-tab-left')),
      "a tab's place on the tab list fails by name": has(NOT_PLACEMENT('ui-tabs-list#button-itx-list "FirstSecond"', '--active-tab-width')),
      "a segmented place on an item fails by name": has(NOT_PLACEMENT('ui-segmented-control-item#button-isx-a "One"', '--segmented-control-indicator-left')),
      "a tab's place on the segmented indicator fails by name": has(NOT_PLACEMENT('ui-segmented-control-indicator#button-isx-ind ""', '--active-tab-width')),
      "a segmented place on the tabs indicator fails by name": has(NOT_PLACEMENT('ui-tabs-indicator#button-itx-ind ""', '--segmented-control-indicator-top')),
      'a segmented place of 50% on its own indicator fails by name, with its value': has(SLOT_VALUE('ui-segmented-control-indicator#button-isx-ind ""', '--segmented-control-indicator-height', '50%', SEGMENTED, write(SEGMENTED, '--segmented-control-indicator-height'))),
      'a tab place of px with no number fails by name, with its value': has(SLOT_VALUE(TABS_AT, '--active-tab-left', 'px', TABS, write(TABS, '--active-tab-left'))),
      'a tab place of NaNpx fails by name, with its value': has(SLOT_VALUE(TABS_AT, '--active-tab-top', 'NaNpx', TABS, write(TABS, '--active-tab-top'))),
      'a tab place of Infinitypx fails by name, with its value': has(SLOT_VALUE(TABS_AT, '--active-tab-width', 'Infinitypx', TABS, write(TABS, '--active-tab-width'))),
      "a number of pixels on a slider's indicator, which UI SDK writes only as a percentage, fails by name": has(SLOT_VALUE('ui-slider-indicator#button-slpx-indicator ""', '--slider-indicator-start', '12px', SLIDER, write(SLIDER, '--slider-indicator-start'))),
    }),
  },
]

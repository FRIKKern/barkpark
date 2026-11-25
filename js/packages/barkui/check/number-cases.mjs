// The selftest's cases for a UI SDK number input (check/placement.mjs SLOTS): what UI SDK writes on a number input's
// step buttons and scrub area passes there, and only there, only as UI SDK writes it.
import { appendFileSync } from 'node:fs'
import { join } from 'node:path'
import { NOT_PLACEMENT, SLOT_VALUE, SLOTS } from './placement.mjs'
import { all, edit, each, inDemo, lights } from './plants.mjs'

// demo.mjs's lint refuses the word "style" spelled out: the plants spell it in two.
const S = "const S = 'sty' + 'le'"
const row = (d, html) => appendFileSync(join(d, 'example.html'), `<div data-demo-row>\n<span data-demo-label>Number input</span>\n${html}\n</div>\n`)
const withNumber = (d) => edit(join(d, 'part.json'), (s) => JSON.stringify({ ...JSON.parse(s), imports: [...JSON.parse(s).imports, '@ui-sdk/web/number-input'] }, null, 2))
const said = (p) => JSON.stringify(p?.parts?.button ?? {})
const has = (s) => (p) => said(p).includes(JSON.stringify(s).slice(1, -1))
const STYLE_FAIL = /in a style attribute|carries a style attribute/

/** A UI SDK number input with its scrub area and both step buttons. */
const numberInput = (id) => `<ui-number-input id="${id}" default-value="2" min="0" max="9">
  <ui-number-input-scrub-area id="${id}-scrub"><span>Count</span></ui-number-input-scrub-area>
  <ui-number-input-group>
    <ui-number-input-decrement><button id="${id}-less" type="button">Less</button></ui-number-input-decrement>
    <ui-number-input-control><input id="${id}-control" type="text" aria-label="Count"></ui-number-input-control>
    <ui-number-input-increment><button id="${id}-more" type="button">More</button></ui-number-input-increment>
  </ui-number-input-group>
</ui-number-input>`

// A click on the increment button steps the value; both step buttons and the scrub area then carry what UI SDK wrote.
const PIECES = '#button-ni-scrub, #button-ni-less, #button-ni-more'
const STEP = `
steps.push({
  name: 'A click on the increment button steps the value, and UI SDK has written on every step button and the scrub area',
  click: '#button-ni-more',
  expect: (root) => {
    // The check reads from its own world, where the element's own properties are not seen: the input's value is.
    const v = root.querySelector('#button-ni-control').value
    const bare = [...root.querySelectorAll(${JSON.stringify(PIECES)})].filter((e) => !e.hasAttribute('sty' + 'le')).length
    return (v === '3' && !bare) || \`value \${v}, \${bare} piece(s) with nothing written\`
  },
})
`

// Written as the page loads, a frame after the number input is made: a step button's property on a span and on the
// input, the hold delay on the scrub area (UI SDK writes it only on a step button), and on a step button a hold delay
// and a touch-action UI SDK does not write there, and on the scrub area the step button's touch-action.
const WRITES = [
  S,
  "customElements.whenDefined('ui-number-input-increment').then(() => requestAnimationFrame(() => {",
  "  root.querySelector('#button-not-number').setAttribute(S, 'user-select: none')",
  "  root.querySelector('#button-nix-control')[S].touchAction = 'manipulation'",
  "  const scrub = root.querySelector('#button-nix-scrub')",
  "  scrub[S]['set' + 'Property']('--hold-delay', '400ms')",
  "  scrub[S].touchAction = 'manipulation'",
  "  const more = root.querySelector('#button-nix-more')",
  "  more[S]['set' + 'Property']('--hold-delay', '500ms')",
  "  more[S].touchAction = 'none'",
  '}))',
].join('\n')
const BUTTON = 'the button in ui-number-input-increment or ui-number-input-decrement'
const SCRUB = 'ui-number-input-scrub-area'
// A write the list does not hold stands in with no value, so on a list without it each row is read and is not caught.
const write = (name, property) => SLOTS.find((s) => s.slot === name)?.writes.find((w) => w.property === property) ?? { property, values: [] }
const MORE = 'button#button-nix-more "More"'
const SCRUB_AT = 'ui-number-input-scrub-area#button-nix-scrub "Count"'

export const NUMBER_CASES = [
  {
    name: 'placement: a UI SDK number input, stepped by a click on its increment button, writes only what UI SDK writes on its step buttons and scrub area, and that passes',
    only: ['pressed'],
    green: true,
    plant: all((d) => row(d, numberInput('button-ni')), withNumber, (d) => appendFileSync(join(d, 'press.mjs'), STEP)),
    expect: each({
      'every press step passed, the value stepped and every step button and the scrub area written among them': (p) => lights(p).pressed?.pass === true && (p?.parts?.button?.steps ?? []).length > 0,
      'no fail names a style attribute: not a step button and not the scrub area': (p) => !STYLE_FAIL.test(said(p)),
    }),
  },
  {
    name: "placement: a number input's properties stand only on its step buttons and scrub area, as UI SDK writes them: one on a span or on the input, a hold delay on the scrub area, and a value UI SDK does not write fail by name",
    only: ['pressed'],
    plant: all((d) => row(d, `${numberInput('button-nix')}\n<span id="button-not-number">Not a number input</span>`), withNumber, (d) => inDemo(d, WRITES)),
    expect: each({
      "a step button's user-select on a span fails by name": has(NOT_PLACEMENT('span#button-not-number "Not a number input"', 'user-select')),
      "a step button's touch-action on the input fails by name": has(NOT_PLACEMENT('input#button-nix-control ""', 'touch-action')),
      'a hold delay on the scrub area, which UI SDK writes only on a step button, fails by name': has(NOT_PLACEMENT(SCRUB_AT, '--hold-delay')),
      'a hold delay of 500ms on a step button fails by name, with its value': has(SLOT_VALUE(MORE, '--hold-delay', '500ms', BUTTON, write(BUTTON, '--hold-delay'))),
      'a touch-action of none on a step button fails by name, with its value': has(SLOT_VALUE(MORE, 'touch-action', 'none', BUTTON, write(BUTTON, 'touch-action'))),
      "the step button's touch-action on the scrub area fails by name, with its value": has(SLOT_VALUE(SCRUB_AT, 'touch-action', 'manipulation', SCRUB, write(SCRUB, 'touch-action'))),
    }),
  },
]

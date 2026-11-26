// The selftest's cases for a UI SDK slider (check/placement.mjs SLOTS, probes.mjs shownAs): what UI SDK writes on a
// slider's own pieces passes there, and only there, only as UI SDK writes it; the range input UI SDK hides in each
// thumb is read on that thumb, for its ring, its boundary and whether it shows anything, and base.css draws the one
// ring there.
import { appendFileSync } from 'node:fs'
import { join } from 'node:path'
import { NOT_PLACEMENT, SLOT_VALUE, SLOTS } from './placement.mjs'
import { all, edit, each, esc, inDemo, lights, skinsSay } from './plants.mjs'

// demo.mjs's lint refuses the word "style" spelled out: the plants spell it in two.
const S = "const S = 'sty' + 'le'"
const row = (d, html) => appendFileSync(join(d, 'example.html'), `<div data-demo-row>\n<span data-demo-label>Slider</span>\n${html}\n</div>\n`)
export const withSlider = (d) => edit(join(d, 'part.json'), (s) => JSON.stringify({ ...JSON.parse(s), imports: [...JSON.parse(s).imports, '@ui-sdk/web/slider'] }, null, 2))
const said = (p) => JSON.stringify(p?.parts?.button ?? {})
const has = (s) => (p) => said(p).includes(JSON.stringify(s).slice(1, -1))
const STYLE_FAIL = /in a style attribute|carries a style attribute/

/** A UI SDK slider, one thumb per value ("20/60" is two), across or down. */
export const slider = (id, value, down = false) => `<ui-slider id="${id}" default-value="${value}"${down ? ' orientation="vertical"' : ''}>
  <ui-slider-control id="${id}-control"><ui-slider-track><ui-slider-indicator id="${id}-indicator"></ui-slider-indicator>${value
    .split('/')
    .map((_, i) => `<ui-slider-thumb id="${id}-thumb${i}" aria-label="Level ${i + 1}"></ui-slider-thumb>`)
    .join('')}</ui-slider-track></ui-slider-control>
</ui-slider>`

// A click on the track moves the across slider's thumb; every piece of all three sliders then carries what UI SDK wrote.
const PIECES = 'ui-slider-control, ui-slider-track, ui-slider-indicator, ui-slider-thumb, ui-slider-thumb-input > input'
const MOVE = `
steps.push({
  name: 'A click on the track moves the thumb, and UI SDK has laid out every piece',
  click: '#button-sl-control',
  expect: (root) => {
    // The check reads from its own world, where the element's own properties are not seen: the input's value is.
    const v = root.querySelector('#button-sl-thumb0 input').value
    const bare = [...root.querySelectorAll(${JSON.stringify(PIECES)})].filter((e) => !e.hasAttribute('sty' + 'le')).length
    return (v !== '40' && root.querySelectorAll(${JSON.stringify(PIECES)}).length === 17 && !bare) || \`value \${v}, \${bare} piece(s) with nothing written\`
  },
})
`

// Written as the page loads, a frame after the sliders are made: two of the slider's properties on a span, a width on
// a thumb (UI SDK writes it on the indicator and the input, never the thumb), a top on a thumb other than UI SDK's
// 50%, an inset on a thumb not in UI SDK's form, a place past 100% on a thumb and on the indicator, and the hidden
// input made opaque.
const WRITES = [
  S,
  "customElements.whenDefined('ui-slider-thumb').then(() => requestAnimationFrame(() => {",
  "  root.querySelector('#button-not-slider').setAttribute(S, '--slider-thumb-position: 50%; touch-action: none')",
  "  const t = root.querySelector('#button-slx-thumb0')",
  "  t[S].width = '40px'",
  "  t[S].top = '10px'",
  "  t[S].insetInlineStart = '7px'",
  "  t[S]['set' + 'Property']('--slider-thumb-position', '250%')",
  "  root.querySelector('#button-slx-indicator')[S].width = '400%'",
  "  t.querySelector('input')[S].opacity = '1'",
  '}))',
].join('\n')
const slot = (name) => SLOTS.find((s) => s.slot === name)
const write = (name, property) => slot(name).writes.find((w) => w.property === property)
const THUMB = 'ui-slider-thumb#button-slx-thumb0 ""'
const INDICATOR = 'ui-slider-indicator#button-slx-indicator ""'
const INPUT = 'the range input in ui-slider-thumb-input'

// Two sliders for the ring: on the first, the hidden input's own ring taken away (a ring read on the input would find
// none); on the second, the thumb's ring, fill and edge taken away. Plain rules of the selftest's own sheet, unlayered,
// so they win over every layer.
const RING_CSS = ['#button-sla input { box-shadow: none; }', '#button-slb-thumb0 { box-shadow: none; border-color: transparent; background: transparent; }'].join('\n')

export const SLIDER_CASES = [
  {
    name: 'placement: UI SDK sliders across, down and with two thumbs, moved by a click on the track, write only what UI SDK writes on their own pieces, and that passes',
    only: ['pressed'],
    green: true,
    plant: all((d) => row(d, [slider('button-sl', '40'), slider('button-sld', '30', true), slider('button-slr', '20/60')].join('\n')), withSlider, (d) => appendFileSync(join(d, 'press.mjs'), MOVE)),
    expect: each({
      'every press step passed, the thumb moved and every piece laid out among them': (p) => lights(p).pressed?.pass === true && (p?.parts?.button?.steps ?? []).length > 0,
      "no fail names a style attribute: not a slider's control, track, indicator, thumb or input": (p) => !STYLE_FAIL.test(said(p)),
    }),
  },
  {
    name: "placement: a slider's properties stand only on its own pieces, as UI SDK writes them: one on a span, a width on a thumb, a top or an inset UI SDK does not write, a place past 100% and an opaque thumb input fail by name",
    only: ['pressed'],
    plant: all((d) => row(d, `${slider('button-slx', '40')}\n<span id="button-not-slider">Not a slider</span>`), withSlider, (d) => inDemo(d, WRITES)),
    expect: each({
      "--slider-thumb-position on a span fails by name": has(NOT_PLACEMENT('span#button-not-slider "Not a slider"', '--slider-thumb-position')),
      'touch-action on a span fails by name': has(NOT_PLACEMENT('span#button-not-slider "Not a slider"', 'touch-action')),
      'a width on a thumb, which UI SDK writes only on the indicator and the input, fails by name': has(NOT_PLACEMENT(THUMB, 'width')),
      'a top on a thumb other than the one UI SDK writes fails by name, with its value': has(SLOT_VALUE(THUMB, 'top', '10px', 'ui-slider-thumb', write('ui-slider-thumb', 'top'))),
      'an inset on a thumb not in the form UI SDK writes fails by name, with its value': has(SLOT_VALUE(THUMB, 'inset-inline-start', '7px', 'ui-slider-thumb', write('ui-slider-thumb', 'inset-inline'))),
      'a place of 250% on a thumb fails by name, with its value': has(SLOT_VALUE(THUMB, '--slider-thumb-position', '250%', 'ui-slider-thumb', write('ui-slider-thumb', '--slider-thumb-position'))),
      'a width of 400% on the indicator fails by name, with its value': has(SLOT_VALUE(INDICATOR, 'width', '400%', 'ui-slider-indicator', write('ui-slider-indicator', 'width'))),
      "the thumb's hidden input made opaque fails by name, with its value": (p) => new RegExp(esc(JSON.stringify(SLOT_VALUE('INPUT', 'opacity', '1', INPUT, write(INPUT, 'opacity'))).slice(1, -1)).replace('INPUT', 'input#[\\w-]+ \\\\"\\\\"')).test(said(p)),
    }),
  },
  {
    name: "focus: a slider's hidden thumb input is read on its thumb: the ring base.css draws there passes once, and a thumb with no ring, no fill and no edge, or nothing to show, fails by name",
    only: ['skins'],
    css: RING_CSS,
    plant: all((d) => row(d, [slider('button-sla', '40'), slider('button-slb', '60')].join('\n')), withSlider),
    expect: each({
      // The second slider's red, below, says the Tab stops were read as far as it, past the first.
      "the first slider's ring is read on its thumb, drawn once, and passes though its input has none": (p) =>
        /focus on ui-slider-thumb#button-slb-thumb0/.test(said(p)) && !/focus on (input|ui-slider-thumb#button-sla-thumb0)/.test(said(p)),
      "the second slider's thumb with its ring taken away fails on the thumb": skinsSay(/focus on ui-slider-thumb#button-slb-thumb0 "": no gap-edge-halo ring/),
      "the second slider's thumb with no fill and no edge fails its boundary on the thumb": skinsSay(/control boundary 1(\.00)?:1 at ui-slider-thumb#button-slb-thumb0/),
      "the first slider's thumb, which draws only its own fill and edge, shows nothing, and fails on the thumb": skinsSay(/control has nothing to show at ui-slider-thumb#button-sla-thumb0/),
    }),
  },
]

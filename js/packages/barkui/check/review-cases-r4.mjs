// Review throwaway for #28122 round 4 (never merges). Tries to get round the census: each probe is a box that can
// open in the top layer, made or given popover by script, open for one task at most, so no open-box look sees it.
import { appendFileSync } from 'node:fs'
import { join } from 'node:path'
import { all, each, esc, inDemo, lights, skinsSay } from './plants.mjs'
import { UNNAMED_CAN } from './layers.mjs'

const HTML = `
<div data-demo-row id="button-r5-row">
  <span data-demo-label>Probes</span>
  <ui-button><button id="button-r5a-open" data-slot="button" type="button">A</button></ui-button>
  <div id="button-r5a">Probe A</div>
  <ui-button><button id="button-r5b-open" data-slot="button" type="button">B</button></ui-button>
  <ui-button><button id="button-r5c-open" data-slot="button" type="button">C</button></ui-button>
  <ui-button><button id="button-r5e-open" data-slot="button" type="button">E</button></ui-button>
  <span id="button-r5e-host"></span>
  <ui-button><button id="button-r5f-open" data-slot="button" type="button">F</button></ui-button>
</div>
`
// Each probe fires on the first focus of its own button in a page, so focus moved by a modal dialog cannot loop it.
const JS = [
  "const once = (id, fn) => { let done = false; root.querySelector(id).addEventListener('focus', () => { if (!done) { done = true; fn() } }) }",
  // A: popover set by script just before showPopover, then hidden and taken off in the next task.
  "once('#button-r5a-open', () => { const t = root.querySelector('#button-r5a'); t.setAttribute('popover', 'manual'); t.showPopover(); setTimeout(() => { t.hidePopover(); t.removeAttribute('popover') }, 0) })",
  // B: a dialog made by script on focus, shown modal, closed and removed in the next task.
  "once('#button-r5b-open', () => { const d = document.createElement('dialog'); d.id = 'button-r5b'; d.textContent = 'Probe B'; root.querySelector('#button-r5-row').append(d); d.showModal(); setTimeout(() => { d.close(); d.remove() }, 0) })",
  // C: a box outside the stage, on document.body, made on focus and gone in the next task.
  "once('#button-r5c-open', () => { const b = document.createElement('div'); b.id = 'button-r5c'; b.textContent = 'Probe C'; b.popover = 'manual'; document.body.append(b); b.showPopover(); setTimeout(() => b.remove(), 0) })",
  // D: a box outside the stage, on document.body, put there at load and never opened.
  "{ const b = document.createElement('div'); b.id = 'button-r5d'; b.textContent = 'Probe D'; b.popover = 'manual'; document.body.append(b) }",
  // E: an open shadow root made at load; on focus a box is made inside it, shown, and gone in the next task.
  "{ const r = root.querySelector('#button-r5e-host').attachShadow({ mode: 'open' }); once('#button-r5e-open', () => { const p = document.createElement('div'); p.id = 'button-r5e'; p.textContent = 'Probe E'; p.popover = 'manual'; r.append(p); p.showPopover(); setTimeout(() => p.remove(), 0) }) }",
  // F: on focus a host is put in the stage; in the next task it gets an open shadow root with a box, shown; in the
  // task after, the host is gone. Like a web component whose definition loads after its tag is in the page.
  "once('#button-r5f-open', () => { const h = document.createElement('span'); h.id = 'button-r5f-host'; root.querySelector('#button-r5-row').append(h); setTimeout(() => { const p = document.createElement('div'); p.id = 'button-r5f'; p.textContent = 'Probe F'; p.popover = 'manual'; h.attachShadow({ mode: 'open' }).append(p); p.showPopover(); setTimeout(() => { p.hidePopover(); h.remove() }, 0) }, 0) })",
].join('\n')

const PROBES = {
  'A: popover set just before showPopover': 'div#button-r5a "Probe A"',
  'B: a dialog made on focus': 'dialog#button-r5b "Probe B"',
  'C: a box made on document.body on focus': 'div#button-r5c "Probe C"',
  'D: a box put on document.body at load': 'div#button-r5d "Probe D"',
  'E: a box made on focus in an open shadow root made at load': 'div#button-r5e "Probe E"',
  'F: a box in an open shadow root made after its host is in the page, host gone in the next task': 'div#button-r5f "Probe F"',
}

export const REVIEW_CASES = [
  {
    name: 'review plant R5: boxes made or given popover by script, open one task at most, are named by the census',
    only: ['skins'],
    plant: all((d) => appendFileSync(join(d, 'example.html'), HTML), (d) => inDemo(d, JS)),
    expect: (p, ...rest) => {
      const s = Object.entries(lights(p)).flatMap(([l, x]) => (x.fails ?? [x.detail ?? '']).filter((f) => f.includes('button-r5')).map((f) => `${l}: ${f}`))
      console.log(`    r5: ${s.length} fails name a probe${s.length ? `; ${s.join(' | ').slice(0, 3000)}` : ''}`)
      return each(Object.fromEntries(Object.entries(PROBES).map(([k, at]) => [k, skinsSay(new RegExp(esc(UNNAMED_CAN(at))))])))(p, ...rest)
    },
  },
]

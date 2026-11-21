// Review throwaway for #28122 round 5 (never merges). Round 4's probes A to F again, and new tries at a shadow root
// or a window the census does not see. Each box is open for one task at most, so no open-box look sees it. Each
// probe also writes console.error lines, so the log shows what really happened in the page (a "console:" fail).
import { appendFileSync } from 'node:fs'
import { join } from 'node:path'
import { all, each, esc, inDemo, lights, skinsSay } from './plants.mjs'
import { FRAME, UNNAMED_CAN } from './layers.mjs'
import { REVIEW_CASES as R4 } from './review-cases-r4.mjs'

const HTML = `
<div data-demo-row id="button-r6-row">
  <span data-demo-label>Probes</span>
  <ui-button><button id="button-r6g-open" data-slot="button" type="button">G</button></ui-button>
  <span id="button-r6g-host"></span>
  <ui-button><button id="button-r6h1-open" data-slot="button" type="button">H1</button></ui-button>
  <span id="button-r6h1-host"></span>
  <ui-button><button id="button-r6h3-open" data-slot="button" type="button">H3</button></ui-button>
  <ui-button><button id="button-r6i-open" data-slot="button" type="button">I</button></ui-button>
  <ui-button><button id="button-r6j-open" data-slot="button" type="button">J</button></ui-button>
</div>
`
const later = (f) => `setTimeout(() => { ${f} }, 0)`
const JS = [
  "const once = (id, fn) => { let done = false; root.querySelector(id).addEventListener('focus', () => { if (!done) { done = true; fn() } }) }",
  "const row = root.querySelector('#button-r6-row')",
  "const box = (id, text) => { const b = document.createElement('div'); b.id = id; b.textContent = text; b.popover = 'manual'; return b }",
  "const say = (s) => console.error('review r6: ' + s)",
  // G: another realm's attachShadow, from a frame made and removed in one task; used a task later on a host
  // already in the page; the box is gone a task after that.
  `once('#button-r6g-open', () => { const f = document.createElement('iframe'); document.body.append(f); const att = f.contentWindow.Element.prototype.attachShadow; f.remove(); ${later(`const r = att.call(root.querySelector('#button-r6g-host'), { mode: 'open' }), b = box('button-r6g', 'Probe G'); r.append(b); b.showPopover(); say('G open ' + b.matches(':popover-open')); ${later('b.remove()')}`)} })`,
  // H1: a declared root parsed straight onto a host already in the page (setHTMLUnsafe with a top-level template),
  // no attachShadow call and no new host; shown a task later, gone the task after.
  `once('#button-r6h1-open', () => { const h = root.querySelector('#button-r6h1-host'); h.setHTMLUnsafe('<template shadowrootmode="open"><div id="button-r6h1" popover="manual">Probe H1</div></template>'); say('H1 root ' + !!h.shadowRoot); ${later(`const b = h.shadowRoot?.querySelector('#button-r6h1'); if (b) { b.showPopover(); say('H1 open ' + b.matches(':popover-open')); ${later('b.remove()')} }`)} })`,
  // H3: a host with a declared root, parsed in another document (Document.parseHTMLUnsafe) and moved into the stage.
  `once('#button-r6h3-open', () => { const d = Document.parseHTMLUnsafe('<span><template shadowrootmode="open"><div id="button-r6h3" popover="manual">Probe H3</div></template></span>'); const s = d.body.firstElementChild; row.append(s); say('H3 root ' + !!s.shadowRoot); ${later(`const b = s.shadowRoot?.querySelector('#button-r6h3'); if (b) { b.showPopover(); say('H3 open ' + b.matches(':popover-open')) } ${later('s.remove()')}`)} })`,
  // I: a clonable root, cloned (no attachShadow call for the copy), the copy put in the stage.
  `once('#button-r6i-open', () => { const t = document.createElement('span'); t.attachShadow({ mode: 'open', clonable: true }).append(box('button-r6i', 'Probe I')); const c = t.cloneNode(true); row.append(c); say('I root ' + !!c.shadowRoot); ${later(`const b = c.shadowRoot?.querySelector('#button-r6i'); if (b) { b.showPopover(); say('I open ' + b.matches(':popover-open')) } ${later('c.remove()')}`)} })`,
  // J: a root attached while its host is out of the page (the hook's event reaches no window); the host goes in a
  // task later, empty; the box goes in a task after that, shown, and the host is gone the task after.
  `once('#button-r6j-open', () => { const h = document.createElement('span'), r = h.attachShadow({ mode: 'open' }); ${later(`row.append(h); ${later(`const b = box('button-r6j', 'Probe J'); r.append(b); b.showPopover(); say('J open ' + b.matches(':popover-open')); ${later('h.remove()')}`)}`)} })`,
].join('\n')

// P, in its own run: another window that is not window.open and not a frame, opened by a link with
// target=_blank. Its page reaches its opener and attaches a root on a host already in the stage with its own
// window's attachShadow, holding a box shown at once and gone a task later. Two ways in: a blob: page (Pb), and a
// javascript: link run in the new window (Pj). Every step reports to the page's console, so the log shows whether
// the window opened, whether it reached the page, and why not. rel=opener: a target=_blank link is noopener by
// default, and its page then has no opener to reach.
const ATTACH = (t) => `opener.postMessage('P${t} alive', '*'); try { const d = opener.document, h = d.querySelector('#button-r6p-host-${t}'); const r = Element.prototype.attachShadow.call(h, { mode: 'open' }); const b = d.createElement('div'); b.id = 'button-r6p${t}'; b.textContent = 'Probe P${t}'; b.popover = 'manual'; r.append(b); b.showPopover(); opener.console.error('review r6: P${t} open ' + b.matches(':popover-open')); opener.setTimeout(() => b.remove(), 0) } catch (e) { opener.postMessage('P${t} err ' + e.name + ': ' + e.message, '*') } window.close()`
const BLOB = '<script>' + ATTACH('b') + '</' + 'script>'
const HTML_P = `
<div data-demo-row id="button-r6p-row">
  <span data-demo-label>Probe P</span>
  <ui-button><button id="button-r6pb-open" data-slot="button" type="button">Pb</button></ui-button>
  <span id="button-r6p-host-b"></span>
  <ui-button><button id="button-r6pj-open" data-slot="button" type="button">Pj</button></ui-button>
  <span id="button-r6p-host-j"></span>
</div>
`
const lit = (s) => JSON.stringify(s).replace(/<\//g, '<\\/')
const JS_P = [
  "addEventListener('message', (e) => console.error('review r6: P msg ' + e.data))",
  "const link = (id, href) => { let done = false; root.querySelector(id).addEventListener('focus', () => { if (done) return; done = true; console.error('review r6: ' + id + ' activation ' + navigator.userActivation.isActive); const a = document.createElement('a'); a.href = href(); a.target = '_blank'; a.rel = 'opener'; root.querySelector('#button-r6p-row').append(a); a.click(); a.remove(); console.error('review r6: ' + id + ' clicked') }) }",
  `link('#button-r6pb-open', () => URL.createObjectURL(new Blob([${lit(BLOB)}], { type: 'text/html' })))`,
  `link('#button-r6pj-open', () => 'javascript:' + encodeURIComponent(${lit(ATTACH('j'))}))`,
].join('\n')

const report = (tag) => (p) => {
  const s = Object.entries(lights(p)).flatMap(([l, x]) => (x.fails ?? [x.detail ?? '']).filter((f) => f.includes(tag) || f.includes('review r6')).map((f) => `${l}: ${f}`))
  console.log(`    ${tag}: ${s.length} fails${s.length ? `; ${s.join(' | ').slice(0, 4000)}` : ''}`)
}
const can = (at) => skinsSay(new RegExp(esc(UNNAMED_CAN(at))))
const caughtAs = (at, frame) => (p) => can(at)(p) || (frame ? skinsSay(new RegExp(esc(FRAME(frame))))(p) : false)

export const REVIEW_CASES = [
  ...R4,
  {
    name: 'review plant R6: roots that come by another realm, a parsed or cloned root, or a root made out of the page, are named by the census',
    only: ['skins'],
    plant: all((d) => appendFileSync(join(d, 'example.html'), HTML), (d) => inDemo(d, JS)),
    expect: (p, ...rest) => {
      report('button-r6')(p)
      return each({
        'G: a frame made and removed in one task lends its attachShadow (named, or the frame refused)': caughtAs('div#button-r6g "Probe G"', 'iframe ""'),
        'H1: a declared root parsed onto a host already in the page': can('div#button-r6h1 "Probe H1"'),
        'H3: a host with a declared root from Document.parseHTMLUnsafe': can('div#button-r6h3 "Probe H3"'),
        'I: a clone of a clonable root': can('div#button-r6i "Probe I"'),
        'J: a root made while its host is out of the page': can('div#button-r6j "Probe J"'),
      })(p, ...rest)
    },
  },
  {
    name: 'review plant R6P: a window opened by a link, attaching a root with its own attachShadow, is named or refused',
    only: ['skins'],
    plant: all((d) => appendFileSync(join(d, 'example.html'), HTML_P), (d) => inDemo(d, JS_P)),
    expect: (p, ...rest) => {
      report('button-r6p')(p)
      return each({
        'Pb: a box in a root attached from a blob: window a link opened': can('div#button-r6pb "Probe Pb"'),
        'Pj: a box in a root attached from a javascript: link in a new window': can('div#button-r6pj "Probe Pj"'),
      })(p, ...rest)
    },
  },
]

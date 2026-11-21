// Review throwaway for #28122 round 2 (never merges). Each row is written as the fix should hold: a FAIL row is a hole.
// Every row prints what the check said about the planted box, so a pass or a FAIL can be read from the log alone.
import { appendFileSync } from 'node:fs'
import { join } from 'node:path'
import { all, edit, inDemo, lights } from './plants.mjs'

const row = (html) => (d) => appendFileSync(join(d, 'example.html'), `\n${html}\n`)
const BOX = 'position: absolute; inset: auto; left: 8px; top: 8px; margin: 0; padding: 8px 12px; border: 0; background-color: rgb(255, 255, 255); color: rgb(185, 185, 185); font: 16px/1.4 sans-serif;'
const UNNAMED = (id) => new RegExp(`${id} "Saved two minutes ago" is open in the top layer during the reading, and no layer in part.json names it`)
/** Every fail any light gives that names `id`, printed; `re` decides. */
const said = (id, re) => (p, html, ok, logs) => {
  const s = Object.entries(lights(p)).flatMap(([l, x]) => (x.fails ?? [x.detail ?? '']).filter((f) => f.includes(id)).map((f) => `${l}: ${f}`))
  console.log(`    ${id}: ${s.length} fails name it${s.length ? `; first: ${s.slice(0, 3).join(' | ').slice(0, 900)}` : ''}`)
  if (!p) console.log(`    no proof; last logs: ${logs.slice(-6).join(' | ').slice(0, 900)}`)
  return s.some((f) => re.test(f))
}
const TIP = '<div data-demo-row><span data-demo-label>Tip</span><ui-button><button id="button-tip-open" data-slot="button" type="button">Info</button></ui-button><div id="button-tip" popover="manual">Saved two minutes ago</div></div>'
const SPAN_TIP = '<div data-demo-row><span data-demo-label>Tip</span><span id="button-tip-open">Info</span><div id="button-tip" popover="manual">Saved two minutes ago</div></div>'
// show/hide on the given events; `ms` is the delay before showing (a hide clears it), as real tooltips do.
const tipJs = (shows, hides, ms = 0) => `{ const b = root.querySelector('#button-tip-open'), t = root.querySelector('#button-tip'); let k = 0; const on = () => { clearTimeout(k); k = setTimeout(() => { if (!t.matches(':popover-open')) t.showPopover() }, ${ms}) }; const off = () => { clearTimeout(k); if (t.matches(':popover-open')) t.hidePopover() }; for (const e of ${JSON.stringify(shows)}) b.addEventListener(e, on); for (const e of ${JSON.stringify(hides)}) b.addEventListener(e, off) }`
const layer = (open, close) => (d) => edit(join(d, 'part.json'), (s) => JSON.stringify({ ...JSON.parse(s), layers: [{ box: '#button-tip', open, close }] }, null, 2))
const css = `#button-tip { ${BOX} }`
const base = { only: ['skins'], secs: 900, css }

export const REVIEW_CASES = [
  { ...base, name: 'review plant R3 K1: an unnamed tooltip on focus or hover, hidden on blur or leave, states on, is named', states: true, plant: all(row(TIP), (d) => inDemo(d, tipJs(['focus', 'mouseenter'], ['blur', 'mouseleave']))), expect: said('div#button-tip', UNNAMED('div#button-tip')) },
  { ...base, name: 'review plant R3 K1d: an unnamed tooltip on focus, hidden on blur, states off, is named', plant: all(row(TIP), (d) => inDemo(d, tipJs(['focus'], ['blur']))), expect: said('div#button-tip', UNNAMED('div#button-tip')) },
  { ...base, name: 'review plant R3 K7: an unnamed tooltip shown 400 ms after focus or hover, hidden on blur or leave, states on, is named', states: true, plant: all(row(TIP), (d) => inDemo(d, tipJs(['focus', 'mouseenter'], ['blur', 'mouseleave'], 400))), expect: said('div#button-tip', UNNAMED('div#button-tip')) },
  { ...base, name: 'review plant R3 K8: an unnamed tooltip on hover over a plain span, states on, is named', states: true, plant: all(row(SPAN_TIP), (d) => inDemo(d, tipJs(['mouseenter'], ['mouseleave']))), expect: said('div#button-tip', UNNAMED('div#button-tip')) },
  { ...base, name: 'review plant R3 K9: a named tooltip shown 400 ms after hover, closed by leave, is read with it open', plant: all(row(TIP), (d) => inDemo(d, tipJs(['mouseenter'], ['mouseleave'], 400)), layer({ hover: '#button-tip-open' }, { leave: true })), expect: said('div#button-tip', /with #button-tip open: drawn text [\d.]+:1 at div#button-tip/) },
  { ...base, name: 'review plant R3 K10: a named tooltip opened by focus and closed by Tab, as PARTS.md says, is read with it open', plant: all(row(TIP), (d) => inDemo(d, tipJs(['focus'], ['blur'])), layer({ focus: '#button-tip-open' }, { keys: ['Tab'] })), expect: said('div#button-tip', /with #button-tip open: drawn text [\d.]+:1 at div#button-tip/) },
]

// Review throwaway for #28122 round 3 (never merges). REVIEW_KILL turns one look off, for kill runs of the folded row.
import { appendFileSync } from 'node:fs'
import { join } from 'node:path'
import { all, inDemo, lights } from './plants.mjs'

const row = (html) => (d) => appendFileSync(join(d, 'example.html'), `\n${html}\n`)
const BOX = 'position: absolute; inset: auto; left: 8px; top: 8px; margin: 0; padding: 8px 12px; border: 0; background-color: rgb(255, 255, 255); color: rgb(185, 185, 185); font: 16px/1.4 sans-serif;'
const TIP = '<div data-demo-row><span data-demo-label>Tip</span><ui-button><button id="button-tip-open" data-slot="button" type="button">Info</button></ui-button><div id="button-tip" popover="manual">Saved two minutes ago</div></div>'
const JS = "{ const b = root.querySelector('#button-tip-open'), t = root.querySelector('#button-tip'); b.addEventListener('mouseenter', () => { if (!t.matches(':popover-open')) t.showPopover() }); b.addEventListener('mouseleave', () => { if (t.matches(':popover-open')) t.hidePopover() }) }"
const RE = /real hover[^:]* on [^:]*button#button-tip-open[^:]*: div#button-tip "Saved two minutes ago" is open in the top layer during the reading, and no layer in part.json names it/

export const REVIEW_CASES = [
  {
    name: 'review plant R4 PA: an unnamed tooltip on hover only, states on, is named at the state drive',
    only: ['skins'], states: true, secs: 900, css: `#button-tip { ${BOX} }`,
    plant: all(row(TIP), (d) => inDemo(d, JS)),
    expect: (p, html, ok, logs) => {
      const s = Object.entries(lights(p)).flatMap(([l, x]) => (x.fails ?? [x.detail ?? '']).filter((f) => f.includes('button-tip')).map((f) => `${l}: ${f}`))
      console.log(`    button-tip: ${s.length} fails name it${s.length ? `; first: ${s.slice(0, 3).join(' | ').slice(0, 900)}` : ''}`)
      return s.some((f) => RE.test(f))
    },
  },
]

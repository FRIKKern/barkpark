// Review throwaway for #28122 (never merges). Each row is written as the fix should hold: a FAIL row is a hole.
// Every row prints what the check said about the planted box, so a pass or a FAIL can be read from the log alone.
import { appendFileSync, cpSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { chromium } from 'playwright'
import { partsDir } from '../build/parts.mjs'
import { buildShowroom } from '../build/showroom.mjs'
import { open } from './proofs.mjs'
import { readView, verdict } from './reading.mjs'
import { all, edit, inDemo, lights } from './plants.mjs'

const row = (html) => (d) => appendFileSync(join(d, 'example.html'), `\n${html}\n`)
const BOX = 'position: absolute; inset: auto; left: 8px; top: 8px; margin: 0; padding: 8px 12px; border: 0; background-color: rgb(255, 255, 255); color: rgb(185, 185, 185); font: 16px/1.4 sans-serif;'
const UNNAMED = (id) => new RegExp(`${id} "Saved two minutes ago" is open in the top layer during the reading, and no layer in part.json names it`)
/** Every fail any light gives that names `id`, printed; true when one of them is the unnamed-box fail. */
const named = (id) => (p, html, ok, logs) => {
  const said = Object.entries(lights(p)).flatMap(([l, x]) => (x.fails ?? [x.detail ?? '']).filter((f) => f.includes(id)).map((f) => `${l}: ${f}`))
  const held = said.some((f) => UNNAMED(id).test(f))
  console.log(`    ${id}: ${said.length} fails name it${said.length ? `; first: ${said.slice(0, 3).join(' | ').slice(0, 900)}` : ''}`)
  if (!p) console.log(`    no proof; last logs: ${logs.slice(-6).join(' | ').slice(0, 900)}`)
  return held
}

/** A box straddling two grounds: `share` of it over white, the rest over black, light grey text, no fill. */
async function straddle(share) {
  const scratch = mkdtempSync(join(tmpdir(), 'barkui-review-'))
  const browser = await chromium.launch({ args: ['--disable-lcd-text'] })
  try {
    const dir = join(scratch, 'parts')
    cpSync(join(partsDir, 'button'), join(dir, 'button'), { recursive: true })
    row('<div data-demo-row><span data-demo-label>Popover</span><ui-button><button id="button-pop-open" data-slot="button" type="button" popovertarget="button-pop">Details</button></ui-button><div id="button-pop" popover>Saved two minutes ago</div></div>')(join(dir, 'button'))
    edit(join(dir, 'button', 'part.json'), (s) => JSON.stringify({ ...JSON.parse(s), layers: [{ box: '#button-pop', open: { click: '#button-pop-open' }, close: { keys: ['Escape'] } }] }, null, 2))
    row('<div data-demo-row><div id="button-white"></div><div id="button-black"></div></div>')(join(dir, 'button'))
    const css = [
      '#button-white, #button-black { display: block; width: 320px; height: 96px; }',
      '#button-white { background-color: rgb(255, 255, 255); }',
      '#button-black { background-color: rgb(0, 0, 0); }',
      '#button-pop { position: absolute; inset: auto; margin: 0; padding: 8px 12px; border: 0; background-color: transparent; color: rgb(170, 170, 170); font: 16px/1.4 sans-serif; }',
    ].join('\n')
    const built = await buildShowroom({ dir, out: join(scratch, 'out'), proof: join(scratch, 'proof.json'), quiet: true, plantCss: css })
    const part = built.parts.find((x) => x.name === 'button')
    const page = await open({ browser, url: pathToFileURL(built.file).href, part: part.name, errors: [] }, { scale: 2, height: 1600 })
    await page.click('#button-pop-open')
    const where = await page.barkCheck((k) => {
      const w = document.getElementById('button-white').getBoundingClientRect()
      const b = document.getElementById('button-black').getBoundingClientRect()
      const pop = document.getElementById('button-pop')
      const pr = pop.getBoundingClientRect()
      const side = b.left >= w.right - 1 ? 'x' : 'y'
      if (side === 'x') {
        pop.style.setProperty('left', `${Math.round(w.right + scrollX - pr.width * k)}px`)
        pop.style.setProperty('top', `${Math.round(w.top + scrollY + 24)}px`)
      } else {
        pop.style.setProperty('left', `${Math.round(w.left + scrollX + 24)}px`)
        pop.style.setProperty('top', `${Math.round(w.bottom + scrollY - pr.height * k)}px`)
      }
      return side
    }, share)
    await page.barkCheck(() => window.__barkCheck.settle())
    const v = await readView(page, part)
    const t = v.things.find((x) => x.kind === 'text' && x.at.startsWith('div#button-pop '))
    const fails = verdict(v).fails.filter((f) => f.includes('div#button-pop '))
    console.log(`    ${Math.round(share * 100)}% over white (grounds split on ${where}): ratio ${t?.ratio}, match ${t?.match}, draws ${t?.draws}; fails: ${JSON.stringify(fails).slice(0, 600)}`)
    return fails.length > 0
  } finally {
    await browser.close()
    rmSync(scratch, { recursive: true, force: true })
  }
}

const TIP = '<div data-demo-row><span data-demo-label>Tip</span><ui-button><button id="button-tip-open" data-slot="button" type="button">Info</button></ui-button><div id="button-tip" popover="manual">Saved two minutes ago</div></div>'
const TIP_JS = "{ const b = root.querySelector('#button-tip-open'), t = root.querySelector('#button-tip'); const on = () => { if (!t.matches(':popover-open')) t.showPopover() }; const off = () => { if (t.matches(':popover-open')) t.hidePopover() }; b.addEventListener('focus', on); b.addEventListener('blur', off); b.addEventListener('mouseenter', on); b.addEventListener('mouseleave', off) }"

const POP = '<div data-demo-row><span data-demo-label>Popover</span><ui-button><button id="button-pop-open" data-slot="button" type="button" popovertarget="button-pop">Details</button></ui-button><div id="button-pop" popover>Saved two minutes ago</div></div>'
const layer = (open, close) => (d) => edit(join(d, 'part.json'), (s) => JSON.stringify({ ...JSON.parse(s), layers: [{ box: '#button-pop', open, close }] }, null, 2))
const says_any = (re) => (p, html, ok, logs) => {
  const said = Object.entries(lights(p)).flatMap(([l, x]) => (x.fails ?? [x.detail ?? '']).filter((f) => f.includes('#button-pop')).map((f) => `${l}: ${f}`))
  console.log(`    #button-pop: ${said.length} fails name it${said.length ? `; first: ${said.slice(0, 3).join(' | ').slice(0, 900)}` : ''}`)
  if (!p) console.log(`    no proof; last logs: ${logs.slice(-6).join(' | ').slice(0, 900)}`)
  return said.some((f) => re.test(f))
}

export const REVIEW_CASES = [
  {
    name: 'review plant K1: an unnamed tooltip open only while its button has focus or the pointer is named',
    only: ['skins'],
    states: true,
    secs: 900,
    plant: all(row(TIP), (d) => inDemo(d, TIP_JS)),
    css: `#button-tip { ${BOX} }`,
    expect: named('div#button-tip'),
  },
  {
    name: 'review plant K2: an unnamed modal dialog the demo opens is named',
    only: ['skins'],
    secs: 900,
    plant: all(row('<div data-demo-row><span data-demo-label>Dialog</span><dialog id="button-dlg">Saved two minutes ago</dialog></div>'), (d) => inDemo(d, "root.querySelector('#button-dlg').showModal()")),
    css: `#button-dlg { ${BOX} }`,
    expect: named('dialog#button-dlg'),
  },
  {
    name: 'review plant K3: an unnamed popover the demo opens outside the stage is named',
    only: ['skins'],
    secs: 900,
    plant: (d) => inDemo(d, "{ const p = document.createElement('div'); p.id = 'button-out'; p.setAttribute('popover', 'manual'); p.textContent = 'Saved two minutes ago'; p.style.cssText = 'position: absolute; inset: auto; left: 8px; top: 8px; margin: 0; padding: 8px 12px; border: 0; background: rgb(255, 255, 255); color: rgb(185, 185, 185); font: 16px/1.4 sans-serif;'; document.body.append(p); p.showPopover() }"),
    expect: named('div#button-out'),
  },
  {
    name: 'review plant K5: a layer whose open input does not open it fails by name',
    only: ['skins'],
    secs: 900,
    plant: all(row(POP), layer({ focus: '#button-pop-open' }, { keys: ['Escape'] })),
    css: `#button-pop { ${BOX} }`,
    expect: says_any(/the layer #button-pop is not open in the top layer after its "open" input/),
  },
  {
    name: 'review plant K6: a layer whose close input does not close it fails by name',
    only: ['skins'],
    secs: 900,
    plant: all(row(POP), layer({ click: '#button-pop-open' }, { keys: ['Shift'] })),
    css: `#button-pop { ${BOX} }`,
    expect: says_any(/the layer #button-pop is still open after its "close" input/),
  },
  { name: 'review plant K4a: a box 40% over white and 60% over black, light grey text, is red', direct: () => straddle(0.4) },
  { name: 'review plant K4b: a box 20% over white and 80% over black, light grey text, is red', direct: () => straddle(0.2) },
]

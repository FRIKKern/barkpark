// The selftest's cases for the top layer (check/layers.mjs): a box the part names is read open, on the ground the
// page really draws behind it, and a box open in the top layer that no layer names is a fail by name.
import { appendFileSync, cpSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { chromium } from 'playwright'
import { partsDir } from '../build/parts.mjs'
import { buildShowroom } from '../build/showroom.mjs'
import { open } from './proofs.mjs'
import { readView, verdict } from './reading.mjs'
import { all, both, edit, inDemo } from './plants.mjs'

// A details popover the "Details" button opens by a click, drawn in the top layer at the page's top left: outside
// the stage's own box, and over the page header, not over its DOM parent.
const POPOVER = `
<div data-demo-row>
  <span data-demo-label>Popover</span>
  <ui-button><button id="button-pop-open" data-slot="button" type="button" popovertarget="button-pop">Details</button></ui-button>
  <div id="button-pop" popover>Saved two minutes ago</div>
</div>
`
const withPopover = (d) => appendFileSync(join(d, 'example.html'), POPOVER)
const LAYER = { box: '#button-pop', open: { click: '#button-pop-open' }, close: { keys: ['Escape'] } }
const named = (d) => edit(join(d, 'part.json'), (s) => JSON.stringify({ ...JSON.parse(s), layers: [LAYER] }, null, 2))
const FAINT = '#button-pop { position: absolute; inset: auto; left: 8px; top: 8px; margin: 0; padding: 8px 12px; border: 0; background-color: rgb(255, 255, 255); color: rgb(185, 185, 185); font: 16px/1.4 sans-serif; }'

/** The same box over two grounds of the page: white and black. Its text is mid grey, under 4.5:1 on white and over
    it on black; the box itself has no fill, so the only ground is what the page draws behind it. */
async function overTwoGrounds() {
  const scratch = mkdtempSync(join(tmpdir(), 'barkui-selftest-'))
  const browser = await chromium.launch({ args: ['--disable-lcd-text'] })
  try {
    const dir = join(scratch, 'parts')
    cpSync(join(partsDir, 'button'), join(dir, 'button'), { recursive: true })
    withPopover(join(dir, 'button'))
    named(join(dir, 'button'))
    appendFileSync(join(dir, 'button', 'example.html'), '<div data-demo-row><div id="button-white"></div><div id="button-black"></div></div>\n')
    const css = [
      '#button-white, #button-black { display: block; width: 320px; height: 96px; }',
      '#button-white { background-color: rgb(255, 255, 255); }',
      '#button-black { background-color: rgb(0, 0, 0); }',
      '#button-pop { position: absolute; inset: auto; margin: 0; padding: 8px 12px; border: 0; background-color: transparent; color: rgb(140, 140, 140); font: 16px/1.4 sans-serif; }',
    ].join('\n')
    const built = await buildShowroom({ dir, out: join(scratch, 'out'), proof: join(scratch, 'proof.json'), quiet: true, plantCss: css })
    const part = built.parts.find((x) => x.name === 'button')
    const page = await open({ browser, url: pathToFileURL(built.file).href, part: part.name, errors: [] }, { scale: 2, height: 1600 })
    await page.click('#button-pop-open')
    const readings = {}
    for (const ground of ['white', 'black']) {
      // The check moves the box over the middle of that ground: the box's DOM parent stays the same row.
      await page.barkCheck((id) => {
        const g = document.getElementById(id).getBoundingClientRect()
        const pop = document.getElementById('button-pop')
        pop.style.setProperty('left', `${Math.round(g.left + scrollX + 24)}px`)
        pop.style.setProperty('top', `${Math.round(g.top + scrollY + 24)}px`)
      }, `button-${ground}`)
      await page.barkCheck(() => window.__barkCheck.settle())
      const v = await readView(page, part)
      const t = v.things.find((x) => x.kind === 'text' && x.at.startsWith('div#button-pop '))
      readings[ground] = { ratio: t?.ratio, draws: t?.draws, share: t?.share, fails: verdict(v).fails.filter((f) => f.includes('div#button-pop ')) }
    }
    const { white, black } = readings
    const held =
      white.draws && black.draws && white.share >= 0.9 && black.share >= 0.9 && white.ratio < 4.5 && black.ratio > 4.5 && black.ratio - white.ratio > 1.5 &&
      white.fails.length === 1 && /^drawn text [\d.]+:1 at div#button-pop /.test(white.fails[0]) && black.fails.length === 0
    if (!held) console.log(`    over white: ${JSON.stringify(white)}; over black: ${JSON.stringify(black)}`)
    return held
  } finally {
    await browser.close()
    rmSync(scratch, { recursive: true, force: true })
  }
}

export const LAYER_CASES = [
  {
    name: 'faint text in a popover the part names is read with it open, outside the stage, in both schemes',
    only: ['skins'],
    plant: all(withPopover, named),
    css: FAINT,
    expect: both(/with #button-pop open: drawn text [\d.]+:1 at div#button-pop "Saved two minutes ago"/),
  },
  {
    name: 'a box open in the top layer that no layer in part.json names fails by name',
    only: ['skins'],
    plant: all(withPopover, (d) => inDemo(d, "root.querySelector('#button-pop').showPopover()")),
    css: FAINT,
    expect: both(/div#button-pop "Saved two minutes ago" is open in the top layer during the reading, and no layer in part.json names it/),
  },
  {
    name: 'the same box over two grounds of the page reads two ways: the ground is what is behind it, not its parent',
    direct: overTwoGrounds,
  },
]

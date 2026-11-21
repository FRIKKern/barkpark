// The selftest's cases for placement in a style attribute (check/placement.mjs): UI SDK's own placement passes; any
// other property, a box property off a box, an anchor name no box hangs from, and a property held only while a box
// was open fail by name; and on a stage with no script any style attribute fails.
import { appendFileSync, cpSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { chromium } from 'playwright'
import { partsDir } from '../build/parts.mjs'
import { buildShowroom } from '../build/showroom.mjs'
import { noscript } from './proofs.mjs'
import { NO_SCRIPT, NOT_A_BOX, NOT_ANCHORED, NOT_PLACEMENT } from './placement.mjs'
import { all, edit, each, inDemo } from './plants.mjs'

// demo.mjs's lint refuses the word "style" spelled out: the plants spell it in two.
const S = "const S = 'sty' + 'le'"
const row = (d, html) => appendFileSync(join(d, 'example.html'), `<div data-demo-row>\n<span data-demo-label>Placement</span>\n${html}\n</div>\n`)
const json = (d, f) => edit(join(d, 'part.json'), (s) => JSON.stringify(f(JSON.parse(s)), null, 2))
/** Every word the part's run left: its lights, their fails, and why it failed. */
const said = (p) => JSON.stringify(p?.parts?.button ?? {})
const has = (s) => (p) => said(p).includes(JSON.stringify(s).slice(1, -1))
const STYLE_FAIL = /in a style attribute|carries a style attribute/

const SELECT = `<ui-select id="button-sel" default-value="beta">
  <ui-select-trigger><button id="button-sel-open" type="button" aria-label="Pick one"><ui-select-value></ui-select-value></button></ui-select-trigger>
  <ui-select-content><ui-select-item value="alpha">Alpha</ui-select-item><ui-select-item value="beta">Beta</ui-select-item></ui-select-content>
</ui-select>
<span id="button-empty">Empty</span>`
const SELECT_LAYER = { box: 'ui-select-content', open: { click: '#button-sel-open' }, close: { keys: ['Escape'] } }

// Each written as the page loads; the last is written while its box is open and taken away as it closes, in one task,
// so no look ever finds it.
const WRITES = [
  S,
  "root.querySelector('#button-box').setAttribute(S, 'position: fixed; opacity: 0.5')",
  "root.querySelector('#button-placed').setAttribute(S, 'top: 4px')",
  "root.querySelector('#button-anchor').setAttribute(S, 'anchor-name: --nobody')",
  "{ const f = root.querySelector('#button-flash'); f.showPopover(); f[S]['set' + 'Property']('color', 'rgb(255, 0, 0)'); f.removeAttribute(S); f.hidePopover() }",
].join('\n')
const PLACED = `<div id="button-box" popover="manual">A box</div>
<span id="button-placed">Placed</span>
<span id="button-anchor">Anchored</span>
<div id="button-flash" popover="manual">Flash</div>`

/** The no-script stage with a box holding a listed property and a span holding an empty attribute: example.html may
    carry neither (the build refuses style=), so they are written into the built page. */
async function noScriptStage() {
  const scratch = mkdtempSync(join(tmpdir(), 'barkui-selftest-'))
  const browser = await chromium.launch({ args: ['--disable-lcd-text'] })
  try {
    const dir = join(scratch, 'parts')
    cpSync(join(partsDir, 'button'), join(dir, 'button'), { recursive: true })
    row(join(dir, 'button'), '<div id="button-box" popover="manual">A box</div>\n<span id="button-plain">Plain</span>')
    const built = await buildShowroom({ dir, out: join(scratch, 'out'), proof: join(scratch, 'proof.json'), quiet: true })
    const html = readFileSync(built.file, 'utf8')
    const planted = html.replace('id="button-box"', 'id="button-box" style="position: fixed"').replace('id="button-plain"', 'id="button-plain" style=""')
    if (planted === html || !planted.includes('style=""')) return console.log('    the plant did not apply'), false
    writeFileSync(built.file, planted)
    const part = built.parts.find((x) => x.name === 'button')
    const l = await noscript({ browser, url: pathToFileURL(built.file).href, part: part.name, errors: [] }, part)
    const want = [NO_SCRIPT('div#button-box "A box"'), NO_SCRIPT('span#button-plain "Plain"')]
    const held = !l.pass && l.detail === want[0] && want.every((w) => l.fails?.includes(w))
    if (!held) console.log(`    the no-script light: ${JSON.stringify(l)}`)
    return held
  } finally {
    await browser.close()
    rmSync(scratch, { recursive: true, force: true })
  }
}

export const PLACEMENT_CASES = [
  {
    name: 'placement: a UI SDK select opened and closed by its layer in every view writes only placement, and an empty style attribute holds nothing; both pass',
    only: ['skins'],
    layers: true,
    plant: all(
      (d) => row(d, SELECT),
      (d) => json(d, (j) => ({ ...j, imports: [...j.imports, '@ui-sdk/web/select'], layers: [SELECT_LAYER] })),
      (d) => inDemo(d, `${S}\nroot.querySelector('#button-empty').setAttribute(S, '')`),
    ),
    expect: each({
      'the select read open in every view': (p) => p?.parts?.button?.measures?.layers?.readings === 10,
      "no fail names a style attribute: the select's trigger, its box, or the empty one": (p) => !STYLE_FAIL.test(said(p)),
    }),
  },
  {
    name: 'placement: what is not placement fails by name: an unlisted property beside a listed one, a box property off a box, an anchor name no box hangs from, a property held only while a box was open',
    only: ['pressed'],
    plant: all((d) => row(d, PLACED), (d) => inDemo(d, WRITES)),
    expect: each({
      'opacity beside position on a box fails by opacity, and position passes': (p) => has(NOT_PLACEMENT('div#button-box "A box"', 'opacity'))(p) && !/div#button-box \\"A box\\" was given position/.test(said(p)),
      'top on an element that cannot open in the top layer fails by name': has(NOT_A_BOX('span#button-placed "Placed"', 'top')),
      'anchor-name on an element no box anchors to fails by name': has(NOT_ANCHORED('span#button-anchor "Anchored"', '--nobody')),
      'color written while a box is open and taken away as it closes fails by name': has(NOT_PLACEMENT('div#button-flash "Flash"', 'color')),
    }),
  },
  {
    name: 'placement: on the stage with no script any style attribute fails by name, a listed property on a box and an empty one alike',
    direct: noScriptStage,
  },
]

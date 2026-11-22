// The selftest's cases for placement in a style attribute (check/placement.mjs): UI SDK's own placement passes; any
// other property, a box property off a box, an anchor name no box hangs from, and a property held only while a box
// was open fail by name; on an element that holds a stage only UI SDK's scroll lock passes, on the root element or
// body while a dialog is open; and on a stage with no script any style attribute fails.
import { appendFileSync, cpSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { chromium } from 'playwright'
import { partsDir } from '../build/parts.mjs'
import { buildShowroom } from '../build/showroom.mjs'
import { noscript } from './proofs.mjs'
import { LOCK_VALUE, NO_DIALOG, NO_SCRIPT, NOT_A_BOX, NOT_ANCHORED, NOT_LOCK, NOT_PLACEMENT, NOT_VALUE, ON_ANCESTOR, OUT_OF_DOCUMENT, SCROLL_LOCK, SHADOW_ABOVE, TRANSITION } from './placement.mjs'
import { all, edit, each, inDemo, lights } from './plants.mjs'

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
// Two press steps after the part's own: a click opens the select, Escape closes it; the guard judges each.
const SELECT_STEPS = `
steps.push(
  { name: 'A click opens the select', click: '#button-sel-open', expect: (root) => root.querySelector('ui-select-content').matches(':popover-open') || 'the select is not open' },
  { name: 'Escape closes it', keys: ['Escape'], expect: (root) => !root.querySelector('ui-select-content').matches(':popover-open') || 'the select is still open' },
)
`

const DIALOG = `<ui-dialog id="button-dlg-ui">
  <ui-dialog-trigger><button id="button-dlg-open" type="button">Open dialog</button></ui-dialog-trigger>
  <ui-dialog-content hidden><ui-dialog-title>Details</ui-dialog-title><ui-dialog-close><button id="button-dlg-close" type="button">Close</button></ui-dialog-close></ui-dialog-content>
</ui-dialog>`
const DIALOG_LAYER = { box: 'ui-dialog-content', open: { click: '#button-dlg-open' }, close: { keys: ['Escape'] } }
const DIALOG_STEPS = `
steps.push(
  { name: 'A click opens the dialog', click: '#button-dlg-open', expect: (root) => root.querySelector('ui-dialog-content').matches(':popover-open, :modal') || 'the dialog is not open' },
  { name: 'Escape closes it', keys: ['Escape'], expect: (root) => !root.querySelector('ui-dialog-content').matches(':popover-open, :modal') || 'the dialog is still open' },
)
`
// On the elements that hold the stage, as the page loads, with no dialog open: one off the scroll lock on the root
// element, the scroll lock on body, and anything on the wrapper between body and the stage.
const ABOVE = [
  S,
  "document.documentElement.setAttribute(S, 'color: rgb(255, 0, 0)')",
  "document.body.setAttribute(S, 'overflow: hidden')",
  "root.parentElement.setAttribute(S, 'margin-top: 0px')",
].join('\n')

// The lock's order, in one task as the page loads: two dialog boxes open; the lock on the root element; one closes and
// the lock stays and grows while the other is open, then goes; body is given two values the lock never writes and
// then the lock, left there as the last box closes.
const TWO = `<div id="button-dlg-a" popover="manual" role="dialog">First</div>
<div id="button-dlg-b" popover="manual" role="dialog">Second</div>`
const ORDER = [
  S,
  "const a = root.querySelector('#button-dlg-a'), b = root.querySelector('#button-dlg-b'), h = document.documentElement, y = document.body",
  'a.showPopover(); b.showPopover()',
  "h.setAttribute(S, 'overflow: hidden; scroll-behavior: auto')",
  'b.hidePopover()',
  "h[S]['set' + 'Property']('scrollbar-gutter', 'stable')",
  "y.setAttribute(S, 'scroll-behavior: smooth; --scrollbar-width: 1em')",
  "y.setAttribute(S, 'overflow: hidden')",
  'h.removeAttribute(S)',
  'a.hidePopover()',
].join('\n')
const lock = (p) => SCROLL_LOCK.find((e) => e.property === p)

// Shadow roots above the stage, as the page loads: an open one attached first and the stage moved in after; a closed
// one declared in markup (no attachShadow); a closed one attached after the stage is already inside its host; an open
// one on the section that already holds the stage. Each slots the stage on.
const SLOT = "'<div><slot></slot></div>'"
const ABOVE_ROOTS = [
  S,
  "const sec = root.parentElement, one = document.createElement('div'), two = document.createElement('div')",
  "const made = document.createElement('div'); made.setHTMLUnsafe('<div id=\"button-sh3\"><template shadowrootmode=\"closed\"><b><slot></slot></b></template></div>'); const three = made.firstChild",
  "one.id = 'button-sh1'; two.id = 'button-sh2'; root.before(two); two.append(three); three.append(one)",
  `const r1 = one.attachShadow({ mode: 'open' }); r1.innerHTML = ${SLOT}; r1.firstChild[S].letterSpacing = '6px'; one.append(root)`,
  `const r2 = two.attachShadow({ mode: 'closed' }); r2.innerHTML = ${SLOT}; r2.firstChild[S].letterSpacing = '6px'`,
  `const r3 = sec.attachShadow({ mode: 'open' }); r3.innerHTML = ${SLOT}; r3.firstChild[S].letterSpacing = '6px'`,
].join('\n')
// The stage moved into an open shadow root, with nothing styled around it.
const INTO_ROOT = [
  "const host = document.createElement('div')",
  "host.id = 'button-sh4'; root.before(host); host.attachShadow({ mode: 'open' }).append(root)",
].join('\n')
const STAGE = 'div[data-part="button"]'

// Each written as the page loads; the last is written while its box is open and taken away as it closes, in one task,
// so no look ever finds it.
const WRITES = [
  S,
  "root.querySelector('#button-box').setAttribute(S, 'position: fixed; opacity: 0.5')",
  "root.querySelector('#button-placed').setAttribute(S, 'top: 4px')",
  "root.querySelector('#button-anchor').setAttribute(S, 'anchor-name: --nobody')",
  "{ const f = root.querySelector('#button-flash'); f.showPopover(); f[S]['set' + 'Property']('color', 'rgb(255, 0, 0)'); f.removeAttribute(S); f.hidePopover() }",
  "root.querySelector('#button-still').setAttribute(S, 'transition: none')",
  "root.querySelector('#button-fading').setAttribute(S, 'transition: opacity 1s')",
  "root.querySelector('#button-slowed').setAttribute(S, 'transition-duration: 0.2s')",
  // removeAttribute taken from another window's Element, after a write through el.style, in one task.
  "{ const t = root.querySelector('#button-framed'), f = document.createElement('iframe'); document.body.append(f); const rm = f.contentWindow.Element.prototype.removeAttribute; t[S]['set' + 'Property']('color', 'rgb(255, 0, 0)'); rm.call(t, S); f.remove() }",
].join('\n')
const PLACED = `<div id="button-box" popover="manual">A box</div>
<span id="button-placed">Placed</span>
<span id="button-anchor">Anchored</span>
<div id="button-flash" popover="manual">Flash</div>
<span id="button-still">Still</span>
<div id="button-fading" popover="manual">Fading</div>
<div id="button-slowed" popover="manual">Slowed</div>
<span id="button-framed">Framed</span>`

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
    name: 'placement: a UI SDK select opened by a click and closed by Escape writes only placement, and an empty style attribute holds nothing; both pass',
    only: ['pressed'],
    layers: true,
    green: true,
    plant: all(
      (d) => row(d, SELECT),
      (d) => json(d, (j) => ({ ...j, imports: [...j.imports, '@ui-sdk/web/select'], layers: [SELECT_LAYER] })),
      (d) => inDemo(d, `${S}\nroot.querySelector('#button-empty').setAttribute(S, '')`),
      (d) => appendFileSync(join(d, 'press.mjs'), SELECT_STEPS),
    ),
    expect: each({
      'every press step passed, the select opened and closed among them': (p) => lights(p).pressed?.pass === true && (p?.parts?.button?.steps ?? []).length > 0,
      "no fail names a style attribute: the select's trigger, its box, or the empty one": (p) => !STYLE_FAIL.test(said(p)),
    }),
  },
  {
    name: 'placement: what is not placement fails by name: an unlisted property beside a listed one, a box property off a box, an anchor name no box hangs from, a property held only while a box was open, a transition other than none on a box or none off one, and a value removed by a method from another window',
    only: ['pressed'],
    plant: all((d) => row(d, PLACED), (d) => inDemo(d, WRITES)),
    expect: each({
      'opacity beside position on a box fails by opacity, and position passes': (p) => has(NOT_PLACEMENT('div#button-box "A box"', 'opacity'))(p) && !/div#button-box \\"A box\\" was given position/.test(said(p)),
      'top on an element that cannot open in the top layer fails by name': has(NOT_A_BOX('span#button-placed "Placed"', 'top')),
      'anchor-name on an element no box anchors to fails by name': has(NOT_ANCHORED('span#button-anchor "Anchored"', '--nobody')),
      'color written while a box is open and taken away as it closes fails by name': has(NOT_PLACEMENT('div#button-flash "Flash"', 'color')),
      'transition: none on an element that is not a box fails by name': has(NOT_A_BOX('span#button-still "Still"', 'transition-duration')),
      'a transition other than none on a box fails by name, with its value': has(NOT_VALUE('div#button-fading "Fading"', 'transition-duration', '1s', TRANSITION)),
      'one transition longhand that is not none (a duration) on a box fails by name': has(NOT_VALUE('div#button-slowed "Slowed"', 'transition-duration', '0.2s', TRANSITION)),
      "removeAttribute taken from a frame's window after an el.style write: the value is still seen": has(NOT_PLACEMENT('span#button-framed "Framed"', 'color')),
    }),
  },
  {
    name: 'placement: a UI SDK dialog opened by a click and closed by Escape writes its scroll lock on the root element while it is open, and that passes',
    only: ['pressed'],
    layers: true,
    green: true,
    plant: all(
      (d) => row(d, DIALOG),
      (d) => json(d, (j) => ({ ...j, imports: [...j.imports, '@ui-sdk/web/dialog'], layers: [DIALOG_LAYER] })),
      (d) => appendFileSync(join(d, 'press.mjs'), DIALOG_STEPS),
    ),
    expect: each({
      'every press step passed, the dialog opened and closed among them': (p) => lights(p).pressed?.pass === true && (p?.parts?.button?.steps ?? []).length > 0,
      'no fail names a style attribute: not the root element, not the dialog': (p) => !STYLE_FAIL.test(said(p)),
    }),
  },
  {
    name: 'placement: on an element that holds a stage, a property off the scroll lock on the root element, the scroll lock on body with no dialog open, and any property on a wrapper fail by name',
    only: ['pressed'],
    plant: all((d) => inDemo(d, ABOVE)),
    expect: each({
      'color on the root element fails by name': has(NOT_LOCK('html', 'color')),
      'the scroll lock on body with no dialog open fails by name': has(NO_DIALOG('body', 'overflow-y')),
      'margin-top on the wrapper between body and the stage fails by name': has(ON_ANCESTOR('section#part-button', 'margin-top')),
    }),
  },
  {
    name: 'placement: the scroll lock stays while one of two dialog boxes is still open, and fails by name when left after the last one closes or given a value it never writes',
    only: ['pressed'],
    plant: all((d) => row(d, TWO), (d) => inDemo(d, ORDER)),
    expect: each({
      'the lock on the root element, kept and grown while one of two boxes is open, passes': (p) => /body was given/.test(said(p)) && !/html was given/.test(said(p)),
      'the lock left on body after the last box closed fails by name': has(NO_DIALOG('body', 'overflow-x')),
      'scroll-behavior: smooth fails by name, with its value': has(LOCK_VALUE('body', 'scroll-behavior', 'smooth', lock('scroll-behavior'))),
      '--scrollbar-width in em fails by name, with its value': has(LOCK_VALUE('body', '--scrollbar-width', '1em', lock('--scrollbar-width'))),
    }),
  },
  {
    name: 'placement: an element that holds a stage and hosts a shadow root fails by name, whatever its mode, however it was made, and whether it was made before or after the stage moved in',
    only: ['pressed'],
    plant: all((d) => inDemo(d, ABOVE_ROOTS)),
    expect: each({
      'an open root attached first, the stage moved in after': has(SHADOW_ABOVE('div#button-sh1')),
      'a closed root attached after the stage was inside its host': has(SHADOW_ABOVE('div#button-sh2')),
      'a closed root declared in markup, made by no attachShadow': has(SHADOW_ABOVE('div#button-sh3')),
      'an open root on the section that already holds the stage': has(SHADOW_ABOVE('section#part-button')),
    }),
  },
  {
    name: 'placement: a stage moved into a shadow root, with nothing styled around it, fails by name',
    only: ['pressed'],
    plant: all((d) => inDemo(d, INTO_ROOT)),
    expect: each({ 'the stage is outside the document itself': has(OUT_OF_DOCUMENT(STAGE)) }),
  },
  {
    name: 'placement: on the stage with no script any style attribute fails by name, a listed property on a box and an empty one alike',
    direct: noScriptStage,
  },
]

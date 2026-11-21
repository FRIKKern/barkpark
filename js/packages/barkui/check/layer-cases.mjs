// The selftest's cases for the top layer (check/layers.mjs): a box the part names is read open, on the ground the
// page really draws behind it; what can open in the top layer and no layer names is a fail by name, open or not;
// and a named box that opens late fails by name.
import { appendFileSync, cpSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { chromium } from 'playwright'
import { partsDir } from '../build/parts.mjs'
import { buildShowroom } from '../build/showroom.mjs'
import { open } from './proofs.mjs'
import { readView, verdict } from './reading.mjs'
import { all, both, each, edit, esc, inDemo, skinsSay } from './plants.mjs'
import { LATE, looks, UNNAMED_CAN } from './layers.mjs'

// A details popover the "Details" button opens by a click, drawn in the top layer at the page's top left: outside
// the stage's own box, and over the page header, not over its DOM parent.
const POPOVER = `
<div data-demo-row>
  <span data-demo-label>Popover</span>
  <ui-button><button id="button-pop-open" data-slot="button" type="button" popovertarget="button-pop">Details</button></ui-button>
  <div id="button-pop" popover>Saved two minutes ago</div>
</div>
`
// Three more boxes for the run that holds every top-layer reading at once: one the demo opens at the start and
// keeps open (no layer names it), a tooltip shown only while its button has focus (no layer names it), and a hint
// shown only while the pointer is on its button (a layer names it, opened by hover, closed by the pointer leaving).
const MORE = `
<div data-demo-row>
  <span data-demo-label>More boxes</span>
  <div id="button-open" popover="manual">Always open</div>
  <ui-button><button id="button-tip-open" data-slot="button" type="button">Info</button></ui-button>
  <div id="button-tip" popover="manual">Shown on focus</div>
  <ui-button><button id="button-hint-open" data-slot="button" type="button">Hint</button></ui-button>
  <div id="button-hint" popover="manual">Shown on hover</div>
</div>
<div data-demo-row>
  <span data-demo-label>Never read open</span>
  <ui-button><button id="button-late-open" data-slot="button" type="button">Later</button></ui-button>
  <div id="button-late" popover="manual">Shown late</div>
  <span id="button-span">On a span</span>
  <div id="button-span-tip" popover="manual">Shown on the span</div>
  <dialog id="button-dlg">Never opened</dialog>
  <div id="button-plain">Given popover</div>
  <ui-button><button id="button-slow-open" data-slot="button" type="button">Slow</button></ui-button>
  <div id="button-slow" popover="manual">Shown slowly</div>
</div>
`
const MORE_JS = [
  "root.querySelector('#button-open').showPopover()",
  "{ const b = root.querySelector('#button-tip-open'), t = root.querySelector('#button-tip'); b.addEventListener('focus', () => t.showPopover()); b.addEventListener('blur', () => t.hidePopover()) }",
  "{ const b = root.querySelector('#button-hint-open'), t = root.querySelector('#button-hint'); b.addEventListener('mouseenter', () => t.showPopover()); b.addEventListener('mouseleave', () => t.hidePopover()) }",
  // Shown 400 ms after focus or hover, as real tooltips are; leaving clears the timer.
  "{ const late = (b, t, shows, hides) => { let k = 0; for (const e of shows) b.addEventListener(e, () => { clearTimeout(k); k = setTimeout(() => t.matches(':popover-open') || t.showPopover(), 400) }); for (const e of hides) b.addEventListener(e, () => { clearTimeout(k); if (t.matches(':popover-open')) t.hidePopover() }) }; late(root.querySelector('#button-late-open'), root.querySelector('#button-late'), ['focus', 'mouseenter'], ['blur', 'mouseleave']); late(root.querySelector('#button-slow-open'), root.querySelector('#button-slow'), ['mouseenter'], ['mouseleave']) }",
  // On hover over a plain span, which the check never drives.
  "{ const b = root.querySelector('#button-span'), t = root.querySelector('#button-span-tip'); b.addEventListener('mouseenter', () => t.showPopover()); b.addEventListener('mouseleave', () => t.hidePopover()) }",
  // On focus, a box that carries popover is made and gone again within the task, and a plain box carries popover
  // as long: neither is in the document as such at any look.
  "root.querySelector('#button-tip-open').addEventListener('focus', () => { const row = root.querySelector('#button-plain'), made = document.createElement('div'); made.id = 'button-made'; made.textContent = 'Made on focus'; made.popover = 'manual'; row.after(made); row.popover = 'manual'; setTimeout(() => { made.remove(); row.removeAttribute('popover') }, 0) })",
  // Shadow roots attached after their host is in the page, each gone again before the next look: on focus, an
  // empty host; a task later, a root on it holding a box shown at once and a second host; a task later, a root on
  // that one holding a dialog; and a root attached by another window's attachShadow (a frame's). A task after,
  // all of it is gone.
  "root.querySelector('#button-tip-open').addEventListener('focus', () => { const row = root.querySelector('#button-plain'), host = document.createElement('div'), far = document.createElement('div'), frame = document.createElement('iframe'); row.after(host, far); document.body.append(frame); const attach = frame.contentWindow.Element.prototype.attachShadow; setTimeout(() => { const r = host.attachShadow({ mode: 'open' }), box = document.createElement('div'), inner = document.createElement('span'); box.id = 'button-in-root'; box.textContent = 'In a late root'; box.popover = 'manual'; r.append(box, inner); box.showPopover(); const f = attach.call(far, { mode: 'open' }); f.innerHTML = '<div id=\"button-by-frame\" popover=\"manual\">By a frame</div>'; setTimeout(() => { inner.attachShadow({ mode: 'open' }).innerHTML = '<dialog id=\"button-in-inner\">In a root in a late root</dialog>'; setTimeout(() => { host.remove(); far.remove(); frame.remove() }, 0) }, 0) }, 0) })",
  // A root that comes with no attachShadow call: parsed from markup (a declarative root) on focus, gone a task later.
  "root.querySelector('#button-tip-open').addEventListener('focus', () => { const row = root.querySelector('#button-plain'), box = document.createElement('div'); row.after(box); box.setHTMLUnsafe('<div><template shadowrootmode=\"open\"><div id=\"button-parsed\" popover=\"manual\">In a parsed root</div></template></div>'); setTimeout(() => box.remove(), 0) })",
  // Made by the demo as the page loads and gone a task later, before the check's first look.
  "{ const made = document.createElement('div'); made.id = 'button-at-load'; made.textContent = 'Made at load'; made.popover = 'manual'; root.querySelector('#button-plain').after(made); setTimeout(() => made.remove(), 0) }",
].join('\n')
const HINT = { box: '#button-hint', open: { hover: '#button-hint-open' }, close: { leave: true } }
const SLOW = { box: '#button-slow', open: { hover: '#button-slow-open' }, close: { leave: true } }
const since = { n: 0, ms: 0 }
const withPopover = (d) => appendFileSync(join(d, 'example.html'), POPOVER)
const LAYER = { box: '#button-pop', open: { click: '#button-pop-open' }, close: { keys: ['Escape'] } }
const named = (d, layers = [LAYER]) => edit(join(d, 'part.json'), (s) => JSON.stringify({ ...JSON.parse(s), layers }, null, 2))
/** Faint text in a white box drawn in the top layer at the page's left edge, `top` px down: outside the stage. */
const faint = (id, top) => `#${id} { position: absolute; inset: auto; left: 8px; top: ${top}px; margin: 0; padding: 8px 12px; border: 0; background-color: rgb(255, 255, 255); color: rgb(185, 185, 185); font: 16px/1.4 sans-serif; }`
const UNNAMED_AT = (box) => `${box} is open in the top layer during the reading, and no layer in part.json names it`
const can = (box) => skinsSay(new RegExp(esc(UNNAMED_CAN(box))))

/** The same box over two grounds of the page: white and black. Its text is mid grey, under 4.5:1 on white and over
    it on black; the box itself has no fill, so the only ground is what the page draws behind it. On white it fails
    by its contrast alone; on black it passes, drawn as itself against its words drawn alone on that same ground. */
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
      readings[ground] = { ratio: t?.ratio, draws: t?.draws, match: t?.match, share: t?.share, fails: verdict(v).fails.filter((f) => f.includes('div#button-pop ')) }
    }
    const { white, black } = readings
    const held =
      white.draws && black.draws && white.ratio < 4.5 && black.ratio > 4.5 && black.ratio - white.ratio > 1.5 &&
      white.fails.length === 1 && /^drawn text [\d.]+:1 at div#button-pop /.test(white.fails[0]) && black.fails.length === 0
    if (!held) console.log(`    over white: ${JSON.stringify(white)}; over black: ${JSON.stringify(black)}`)
    return held
  } finally {
    await browser.close()
    rmSync(scratch, { recursive: true, force: true })
  }
}

// One run holds every top-layer reading at once (each plant asserts its own fail), so the selftest pays for one
// check run, not four.
export const LAYER_CASES = [
  {
    name: 'top layer: a named popover and a named hover hint are read open; a box open from the start and a tooltip open only at a Tab stop, named by no layer, fail by name; so do boxes no layer names that never open while the check looks; a named box that opens late fails by name',
    only: ['skins'],
    plant: all(
      () => Object.assign(since, looks),
      withPopover,
      (d) => appendFileSync(join(d, 'example.html'), MORE),
      (d) => inDemo(d, MORE_JS),
      (d) => named(d, [LAYER, HINT, SLOW]),
    ),
    css: [faint('button-pop', 8), faint('button-open', 72), faint('button-tip', 136), faint('button-hint', 200)].join('\n'),
    expect: (p, ...rest) => {
      // What one open state and the looks after real input cost on this runner, for the record (the hosted job prints it).
      const m = p?.parts?.button?.measures?.layers
      if (m) console.log(`    the top layer: ${m.readings} readings open in ${m.seconds} s, ${(m.seconds / m.readings).toFixed(2)} s each`)
      const n = looks.n - since.n
      const s = (looks.ms - since.ms) / 1000
      console.log(`    looks for a box no layer names: ${n} in ${s.toFixed(1)} s, ${n ? ((s * 1000) / n).toFixed(1) : 0} ms each`)
      return each({
        'a named popover, opened by a click, read open': both(/with #button-pop open: drawn text [\d.]+:1 at div#button-pop "Saved two minutes ago"/),
        'a named hint, opened by hover, read open': both(/with #button-hint open: drawn text [\d.]+:1 at div#button-hint "Shown on hover"/),
        // In the reading's own form ("<skin> <scheme> on base: …"), so only the reading holds it, not the looks.
        'a box open from the start, named by no layer, in the reading': both(new RegExp(`^\\w+ (light|dark) on base: ${esc(UNNAMED_AT('div#button-open "Always open"'))}$`)),
        'a tooltip open only at its Tab stop, named by no layer': both(new RegExp(`^\\w+ (light|dark): Tab to button#button-tip-open "Info": ${esc(UNNAMED_AT('div#button-tip "Shown on focus"'))}$`)),
        'a tooltip shown 400 ms after focus or hover, named by no layer': can('div#button-late "Shown late"'),
        'a tooltip on hover over a plain span, named by no layer': can('div#button-span-tip "Shown on the span"'),
        'a dialog never opened, named by no layer': can('dialog#button-dlg "Never opened"'),
        'a box with popover made and gone again between looks': can('div#button-made "Made on focus"'),
        'a box given popover and losing it again between looks': can('div#button-plain "Given popover"'),
        'a box in a shadow root attached after its host is in the page, gone before the next look': can('div#button-in-root "In a late root"'),
        'a dialog in a shadow root attached late inside another late root': can('dialog#button-in-inner "In a root in a late root"'),
        "a box in a shadow root attached by a frame's attachShadow": can('div#button-by-frame "By a frame"'),
        'a box in a shadow root parsed from markup, with no attachShadow call': can('div#button-parsed "In a parsed root"'),
        "a box made as the page loads and gone before the check's first look": can('div#button-at-load "Made at load"'),
        'a named box that opens 400 ms after its input': both(new RegExp(esc(LATE('the layer #button-slow')))),
        'every layer that opens at once read in every view': () => m?.readings === 20,
        'the looks were made': () => n > 0,
      })(p, ...rest)
    },
  },
  {
    name: 'the same box over two grounds of the page reads two ways: the ground is what is behind it, not its parent',
    direct: overTwoGrounds,
  },
]

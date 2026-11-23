// The selftest's cases for the top layer (check/layers.mjs): a box the part names is read open, on the ground the
// page really draws behind it; what can open in the top layer and no layer names is a fail by name, open or not;
// and a named box that opens late fails by name.
import { clickOn, launch, press } from './acts.mjs'
import { appendFileSync, cpSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { partsDir } from '../build/parts.mjs'
import { buildShowroom } from '../build/showroom.mjs'
import { open } from './proofs.mjs'
import { readView, verdict } from './reading.mjs'
import { all, both, each, edit, esc, inDemo, reasons, skinsSay } from './plants.mjs'
import { FRAME, installCensus, LATE, looks, NOT_OWN, REFUSED, UNNAMED_CAN } from './layers.mjs'
import { LISTS } from './motion.mjs'
import { VIEW_PAGES } from './view-pages.mjs'
import { installHelpers, source } from './probes.mjs'

// A details popover the "Details" button opens by a click, drawn in the top layer at the page's top left: outside
// the stage's own box, and over the page header, not over its DOM parent.
const POPOVER = `
<div data-demo-row>
  <span data-demo-label>Popover</span>
  <ui-button><button id="button-pop-open" data-slot="button" type="button" popovertarget="button-pop">Details</button></ui-button>
  <div id="button-pop" popover>Saved two minutes ago</div>
</div>
`
// More boxes for the two top-layer runs: one the demo opens at the start and keeps open (no layer names it), a
// tooltip shown only while its button has focus (no layer names it), and a hint shown only while the pointer is on
// its button (opened by hover, closed by the pointer leaving).
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
// The hint the hint run reads open: shown while the pointer is on its button.
const HINT_JS = "{ const b = root.querySelector('#button-hint-open'), t = root.querySelector('#button-hint'); b.addEventListener('mouseenter', () => t.showPopover()); b.addEventListener('mouseleave', () => t.hidePopover()) }"
// What the unnamed and census runs both plant: the boxes that open, at once or late.
const BOXES_JS = [
  "root.querySelector('#button-open').showPopover()",
  "{ const b = root.querySelector('#button-tip-open'), t = root.querySelector('#button-tip'); b.addEventListener('focus', () => t.showPopover()); b.addEventListener('blur', () => t.hidePopover()) }",
  HINT_JS,
  // Shown 400 ms after focus or hover, as real tooltips are; leaving clears the timer.
  "{ const late = (b, t, shows, hides) => { let k = 0; for (const e of shows) b.addEventListener(e, () => { clearTimeout(k); k = setTimeout(() => t.matches(':popover-open') || t.showPopover(), 400) }); for (const e of hides) b.addEventListener(e, () => { clearTimeout(k); if (t.matches(':popover-open')) t.hidePopover() }) }; late(root.querySelector('#button-late-open'), root.querySelector('#button-late'), ['focus', 'mouseenter'], ['blur', 'mouseleave']); late(root.querySelector('#button-slow-open'), root.querySelector('#button-slow'), ['mouseenter'], ['mouseleave']) }",
].join('\n')
// What only the census run plants: boxes that never open while the check looks.
const CENSUS_JS = [
  // On hover over a plain span, which the check never drives.
  "{ const b = root.querySelector('#button-span'), t = root.querySelector('#button-span-tip'); b.addEventListener('mouseenter', () => t.showPopover()); b.addEventListener('mouseleave', () => t.hidePopover()) }",
  // On focus, a box that carries popover is made and gone again within the task, and a plain box carries popover
  // as long: neither is in the document as such at any look.
  "root.querySelector('#button-tip-open').addEventListener('focus', () => { const row = root.querySelector('#button-plain'), made = document.createElement('div'); made.id = 'button-made'; made.textContent = 'Made on focus'; made.popover = 'manual'; row.after(made); row.popover = 'manual'; setTimeout(() => { made.remove(); row.removeAttribute('popover') }, 0) })",
  // Shadow roots attached after their host is in the page, each gone again before the next look: on focus, an
  // empty host; a task later, a root on it holding a box shown at once and a second host; a task later, a root on
  // that one holding a dialog; and a root attached by another window's attachShadow (a frame's). A task after,
  // all of it is gone.
  "root.querySelector('#button-tip-open').addEventListener('focus', () => { const row = root.querySelector('#button-plain'), host = document.createElement('div'), far = document.createElement('div'), frame = document.createElement('iframe'); frame.id = 'button-frame'; row.after(host, far); document.body.append(frame); const attach = frame.contentWindow.Element.prototype.attachShadow; setTimeout(() => { const r = host.attachShadow({ mode: 'open' }), box = document.createElement('div'), inner = document.createElement('span'); box.id = 'button-in-root'; box.textContent = 'In a late root'; box.popover = 'manual'; r.append(box, inner); box.showPopover(); const f = attach.call(far, { mode: 'open' }); f.innerHTML = '<div id=\"button-by-frame\" popover=\"manual\">By a frame</div>'; setTimeout(() => { inner.attachShadow({ mode: 'open' }).innerHTML = '<dialog id=\"button-in-inner\">In a root in a late root</dialog>'; setTimeout(() => { host.remove(); far.remove(); frame.remove() }, 0) }, 0) }, 0) })",
  // A root that comes with no attachShadow call: parsed from markup (a declarative root) on focus, gone a task later.
  "root.querySelector('#button-tip-open').addEventListener('focus', () => { const row = root.querySelector('#button-plain'), box = document.createElement('div'); row.after(box); box.setHTMLUnsafe('<div><template shadowrootmode=\"open\"><div id=\"button-parsed\" popover=\"manual\">In a parsed root</div></template></div>'); setTimeout(() => box.remove(), 0) })",
  // Made by the demo as the page loads and gone a task later, before the check's first look.
  "{ const made = document.createElement('div'); made.id = 'button-at-load'; made.textContent = 'Made at load'; made.popover = 'manual'; root.querySelector('#button-plain').after(made); setTimeout(() => made.remove(), 0) }",
].join('\n')
const HINT = { box: '#button-hint', open: { hover: '#button-hint-open' }, close: { leave: true } }
const SLOW = { box: '#button-slow', open: { hover: '#button-slow-open' }, close: { leave: true } }
const since = { n: 0, ms: 0 }
export const withPopover = (d) => appendFileSync(join(d, 'example.html'), POPOVER)
const LAYER = { box: '#button-pop', open: { click: '#button-pop-open' }, close: { keys: ['Escape'] } }
export const named = (d, layers = [LAYER]) => edit(join(d, 'part.json'), (s) => JSON.stringify({ ...JSON.parse(s), layers }, null, 2))
/** Faint text in a white box drawn in the top layer at the page's left edge, `top` px down: outside the stage. */
const faint = (id, top) => `#${id} { position: absolute; inset: auto; left: 8px; top: ${top}px; margin: 0; padding: 8px 12px; border: 0; background-color: rgb(255, 255, 255); color: rgb(185, 185, 185); font: 16px/1.4 sans-serif; }`
const UNNAMED_AT = (box) => `${box} is open in the top layer during the reading, and no layer in part.json names it`
const can = (box) => skinsSay(new RegExp(esc(UNNAMED_CAN(box))))

// The census knows the check's own two pages by identity, and the list is closed both ways: a page the check's own
// code opens after the census is refused like any other, and a census set before the reference page is open, or on
// a context that holds a third page, is red by name. The rows that always make a page keep the case from passing
// by making none.
async function ownTwoPages() {
  const browser = await launch()
  const part = { name: 'x', json: {} }
  const two = async () => {
    const context = await browser.newContext()
    const page = await context.newPage()
    const ref = await context.newPage()
    return { context, page, ref }
  }
  const look = async (page, own) => {
    const census = await installCensus(page, own)
    await page.setContent('<!doctype html><p>A page</p>')
    return census
  }
  const red = async (run) => run().then(() => false, (e) => e.message === NOT_OWN)
  try {
    const rows = {}
    {
      const { context, page, ref } = await two()
      rows["the check's own two pages, opened before the census, are not refused"] = (await (await look(page, [page, ref]))(part)).length === 0
      await context.close()
    }
    {
      const { context, page, ref } = await two()
      const census = await look(page, [page, ref])
      const third = await context.newPage()
      if (!third.isClosed()) await third.waitForEvent('close', { timeout: 5000 }).catch(() => {})
      const said = await census(part)
      rows["a third page the check's own code opens after the census, refused by name and closed"] = third.isClosed() && said.length === 1 && said[0] === REFUSED.page
      await context.close()
    }
    {
      const context = await browser.newContext()
      const page = await context.newPage()
      rows['the reference page opened after the census: a census set on the part\'s page alone is red by name'] = await red(() => installCensus(page, [page]))
      rows['a list that names one page twice, red by name'] = await red(() => installCensus(page, [page, page]))
      await context.close()
    }
    {
      const { context, page, ref } = await two()
      await context.newPage()
      rows['a census set on a context that holds a third page, red by name'] = await red(() => installCensus(page, [page, ref]))
      await context.close()
    }
    // Ways that may make a page or not, by the machine (the modifier for a background tab is not the same on every
    // system): each says whether it made one, and a page it made is refused by name and closed, once.
    // The checker's input (check/acts.mjs) reads its rest step through the page's helpers: here in the page's own world.
    const helped = async (page) => {
      page.barkCheck = (fn, arg = null) => page.evaluate(`(async () => { await globalThis.__barkCheck?.toRest?.(); return (${source(fn)})(${JSON.stringify(arg)}) })()`)
      await page.barkCheck(installHelpers, LISTS)
    }
    const MAY = {
      'Control click on a link': async (page) => {
        await helped(page)
        await clickOn(page, '#a', { modifiers: ['Control'] })
      },
      'Control+Enter on a link': async (page) => {
        await helped(page)
        await page.evaluate(() => document.getElementById('a').focus({ preventScroll: true }))
        await press(page, 'Control+Enter')
      },
      'a script Control click on a link': (page) => page.evaluate(() => document.getElementById('a').dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, ctrlKey: true }))),
    }
    // Side by side, each in a context of its own: the case waits once, not once per way.
    const tried = await Promise.all(
      Object.entries(MAY).map(async ([way, act]) => {
        const { context, page, ref } = await two()
        const census = await installCensus(page, [page, ref])
        await page.setContent('<!doctype html><a id="a" href="about:blank#a">A link</a>')
        const made = []
        context.on('page', (p) => made.push(p))
        await act(page)
        await page.waitForTimeout(700)
        await Promise.all(made.map((p) => p.isClosed() || p.waitForEvent('close', { timeout: 5000 }).catch(() => {})))
        const said = await census(part)
        const ok = made.length ? made.length === 1 && made[0].isClosed() && said.length === 1 && said[0] === REFUSED.page : said.length === 0
        await context.close()
        return [way, made.length > 0, ok]
      }),
    )
    for (const [way, made, ok] of tried) {
      console.log(`    ${way}: made a page: ${made ? 'yes' : 'no'}`)
      rows[`${way}: a page it makes is refused by name and closed, once`] = ok
    }
    return each(Object.fromEntries(Object.entries(rows).map(([k, v]) => [k, () => v])))()
  } finally {
    await browser.close()
  }
}

/** The same box over two grounds of the page: white and black. Its text is mid grey, under 4.5:1 on white and over
    it on black; the box itself has no fill, so the only ground is what the page draws behind it. On white it fails
    by its contrast alone; on black it passes, drawn as itself against its words drawn alone on that same ground. */
async function overTwoGrounds() {
  const scratch = mkdtempSync(join(tmpdir(), 'barkui-selftest-'))
  const browser = await launch({ args: ['--disable-lcd-text'] })
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
    await clickOn(page, '#button-pop-open')
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

// Four runs hold the top-layer readings and the census (each plant asserts its own fail), each under the selftest's
// time for one case: the first reads the named popover open, the second unnamed boxes open and a named box late,
// the third the named hint open, the fourth the boxes the census must name.
const BOXES_CSS = [faint('button-pop', 8), faint('button-open', 72), faint('button-tip', 136), faint('button-hint', 200)].join('\n')
/** What one open state and the looks after real input cost on this runner, for the record (the hosted job prints it). */
const measured = (p) => {
  const m = p?.parts?.button?.measures?.layers
  if (m) console.log(`    the top layer: ${m.readings} readings open in ${m.seconds} s, ${(m.seconds / m.readings).toFixed(2)} s each`)
  return m
}
/** The first run's rows: the named popover read open. `m` is the part's measure of its layers. */
const popoverRows = (m) => ({
  'a named popover, opened by a click, read open': both(/with #button-pop open: drawn text [\d.]+:1 at div#button-pop "Saved two minutes ago"/),
  'every layer that opens at once read in every view': () => m?.readings === 10,
})
/** The second run's rows: boxes no layer names read open, and a named box that opens late. */
const unnamedRows = () => ({
  // In the reading's own form ("<skin> <scheme> on base: …"), so only the reading holds it, not the looks.
  'a box open from the start, named by no layer, in the reading': both(new RegExp(`^\\w+ (light|dark) on base: ${esc(UNNAMED_AT('div#button-open "Always open"'))}$`)),
  'a tooltip open only at its Tab stop, named by no layer': both(new RegExp(`^\\w+ (light|dark): Tab to button#button-tip-open "Info": ${esc(UNNAMED_AT('div#button-tip "Shown on focus"'))}$`)),
  'a named box that opens 400 ms after its input': both(new RegExp(esc(LATE('the layer #button-slow')))),
})
/** The third run's rows: the named hint read open. `m` is the part's measure of its layers. */
const hintRows = (m) => ({
  'a named hint, opened by hover, read open': both(/with #button-hint open: drawn text [\d.]+:1 at div#button-hint "Shown on hover"/),
  'the named hint read in every view': () => m?.readings === 10,
})
/** The fourth run's rows: every box the census must name. `n` is the looks made. */
const censusRows = (n) => ({
  'a tooltip shown 400 ms after focus or hover, named by no layer': can('div#button-late "Shown late"'),
  'a tooltip on hover over a plain span, named by no layer': can('div#button-span-tip "Shown on the span"'),
  'a dialog never opened, named by no layer': can('dialog#button-dlg "Never opened"'),
  'a box with popover made and gone again between looks': can('div#button-made "Made on focus"'),
  'a box given popover and losing it again between looks': can('div#button-plain "Given popover"'),
  'a box in a shadow root attached after its host is in the page, gone before the next look': can('div#button-in-root "In a late root"'),
  'a dialog in a shadow root attached late inside another late root': can('dialog#button-in-inner "In a root in a late root"'),
  "a box in a shadow root attached by a frame's attachShadow": can('div#button-by-frame "By a frame"'),
  'a box in a shadow root parsed from markup, with no attachShadow call': can('div#button-parsed "In a parsed root"'),
  'a frame in the page, refused by name': skinsSay(new RegExp(esc(FRAME('iframe#button-frame ""')))),
  "a box made as the page loads and gone before the check's first look": can('div#button-at-load "Made at load"'),
  'the looks were made': () => n > 0,
})
/** The rows of the four top-layer runs, by run, as their cases hold them. */
export const TOP_LAYER_ROWS = { popover: Object.keys(popoverRows()), unnamed: Object.keys(unnamedRows()), hint: Object.keys(hintRows()), census: Object.keys(censusRows()) }
// Each top-layer case is `layers`: it opens its boxes by real input (a click, a hover, a Tab) or holds a refusal,
// and runs in the selftest's rest job by its one rule (check/jobs.mjs).
export const LAYER_CASES = [
  {
    name: 'top layer: a named popover is read open, in every view',
    only: ['skins'],
    layers: true,
    plant: all(withPopover, (d) => named(d, [LAYER])),
    css: BOXES_CSS,
    expect: (p, ...rest) => each(popoverRows(measured(p)))(p, ...rest),
  },
  {
    name: 'top layer: a box open from the start and a tooltip open only at a Tab stop, named by no layer, fail by name; a named box that opens late fails by name',
    only: ['skins'],
    layers: true,
    plant: all(
      (d) => appendFileSync(join(d, 'example.html'), MORE),
      (d) => inDemo(d, BOXES_JS),
      (d) => named(d, [SLOW]),
    ),
    css: BOXES_CSS,
    expect: each(unnamedRows()),
  },
  {
    name: 'top layer: a named hover hint is read open, in every view',
    only: ['skins'],
    layers: true,
    plant: all(
      (d) => appendFileSync(join(d, 'example.html'), MORE),
      (d) => inDemo(d, HINT_JS),
      (d) => named(d, [HINT]),
    ),
    css: BOXES_CSS,
    expect: (p, ...rest) => each(hintRows(measured(p)))(p, ...rest),
  },
  // Its own run, with no layer named and no sheet of its own: the census names boxes that never open while the check
  // looks, so it reads no layer open.
  {
    name: 'top layer: boxes no layer names that never open while the check looks fail by name, wherever they come from: late, made and gone, in a late shadow root, by a frame, parsed from markup, or at load',
    only: ['skins'],
    layers: true,
    plant: all(
      () => Object.assign(since, looks),
      (d) => appendFileSync(join(d, 'example.html'), MORE),
      (d) => inDemo(d, [BOXES_JS, CENSUS_JS].join('\n')),
    ),
    expect: (p, ...rest) => {
      const n = looks.n - since.n
      const s = (looks.ms - since.ms) / 1000
      console.log(`    looks for a box no layer names: ${n} in ${s.toFixed(1)} s, ${n ? ((s * 1000) / n).toFixed(1) : 0} ms each`)
      return each(censusRows(n))(p, ...rest)
    },
  },
  // Its own run: were either call let through, it would take the page away and every other row with it. The first
  // focus makes three pages the check did not open, in three ways, and calls window.open: each page is refused, once.
  // The demo runs on each page the skins light reads its views on (check/view-pages.mjs), so it makes three on each.
  {
    name: "top layer: what would take the page out of the census's sight is refused by name: a page the check did not open, window.open, and markup written into the parsed page (document.write)",
    only: ['skins'],
    layers: true,
    plant: (d) => inDemo(d, "root.querySelector('#button-primary').addEventListener('focus', () => { const a = document.createElement('a'); a.href = 'about:blank'; document.body.append(a); a.target = '_blank'; a.rel = 'opener'; a.click(); a.removeAttribute('target'); a.removeAttribute('rel'); for (const init of [{ shiftKey: true }, { button: 1 }]) a.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, ...init })); a.remove(); window.open(''); document.write('<p>Written late</p>') }, { once: true })"),
    expect: each({
      'window.open, refused by name': skinsSay(new RegExp(esc(REFUSED['window.open']))),
      'every page the check did not open, refused by name, once each': (p) => {
        const n = (s) => reasons(p, 'skins').filter((f) => f.includes(s)).length
        const made = 3 * VIEW_PAGES
        console.log(`    pages the check did not open, refused: ${n(REFUSED.page)} of the ${made} made, 3 on each of the light's ${VIEW_PAGES} pages`)
        return n(REFUSED.page) === made
      },
      'document.write into the parsed page, refused by name': skinsSay(new RegExp(esc(REFUSED['document.write']))),
    }),
  },
  {
    name: "top layer: the part's context holds the check's own two pages and no other, known by identity",
    direct: ownTwoPages,
  },
  {
    name: 'the same box over two grounds of the page reads two ways: the ground is what is behind it, not its parent',
    direct: overTwoGrounds,
  },
]

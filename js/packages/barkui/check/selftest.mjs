// node check/selftest.mjs [--job <key>] [words]: proves the check can still lose. Each case copies
// the button into a scratch parts folder, plants breaks, runs the check on it
// and asserts the run fails for the right reason. A part's own files may not
// style the stage except through part.css, so breaks in paint go in through
// `css`, a sheet the check adds to the build for the selftest alone; other cases
// prove that demo.mjs cannot be that route.
//
// One plant per reading, and plants on different controls share a run: a light
// carries every reason it is off (`fails`), and each plant asserts that one of
// them names its own control. The ladder measures what the label reading's
// limit costs and holds docs/PARTS.md's sentence to it.
import { launch, press, refusals } from './acts.mjs'
import { wallLine } from './wall.mjs'
import { appendFileSync, cpSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { discoverParts, partsDir } from '../build/parts.mjs'
import { CASE_SECONDS, capacitySentence, PER_JOB, SELFTEST_CEILINGS, selftestSentence } from './capacity.mjs'
import { enforceCeiling } from './ceiling.mjs'
import { layerMisplaced, SELFTEST_JOBS, selftestPick } from './jobs.mjs'
import { selftestReport } from './selftest-report.mjs'
import { runCheck } from './check.mjs'
import { open } from './proofs.mjs'
import { readView } from './reading.mjs'
import { readPartCss, sameAsShipped } from './cssom.mjs'
import { buildShowroom } from '../build/showroom.mjs'
import { LAYER_CASES } from './layer-cases.mjs'
import { PLACEMENT_CASES } from './placement-cases.mjs'
import { NUMBER_CASES } from './number-cases.mjs'
import { SLIDER_CASES } from './slider-cases.mjs'
import { REST_CASES } from './rest-cases.mjs'
import { POINTER_CASES } from './pointer-cases.mjs'
import { lightLines, PAGE_CASES } from './page-cases.mjs'
import { VERDICT_CASES } from './verdict-cases.mjs'
import { createHash } from 'node:crypto'
import { PLANTED, WALL_CASES } from './wall-cases.mjs'
import { TIME_CASES } from './time-cases.mjs'
import { CHECKED_CASES, STATE_CASES, SURFACE_CASES } from './unfolded-cases.mjs'
import { holderSentence, topLayerTouch } from './layers.mjs'
import { edit, inDemo, mark, wrap, inCss, all, copyAs, lights, reasons, skinsSay, phoneSays, failedSay, DRAWN, drawnOff, both, refused, each, ladderHtml, ladderCss, ladderHolds, CEILING_CASES } from './plants.mjs'

export const CASES = [
  // The label reading: the six plants it was built for, and the ladder that measures its limit.
  {
    name: 'a label not drawn as itself turns both wide lights off at its control, and the ladder holds docs/PARTS.md to its numbers',
    only: ['skins', 'schemes'],
    plant: (d) => appendFileSync(join(d, 'example.html'), `\n${ladderHtml}\n`),
    css: [
      '#button-after { text-decoration-line: line-through; text-decoration-thickness: 0.9em; }',
      '#button-destructive { position: relative; }',
      '#button-destructive::after { content: "Cancel"; position: absolute; inset: 0; display: grid; place-items: center; background: var(--bark-button-bg); color: var(--bark-button-fg); }',
      '#button-secondary { scale: -1 1; }',
      '[data-slot="button"][data-size="lg"] { scale: 0.95; }',
      '#button-primary { position: relative; }',
      '#button-primary::after { content: ""; position: absolute; right: var(--bark-button-pad); top: 0; width: 8px; height: 50%; background: var(--bark-button-bg); }',
      '#button-save { clip-path: inset(0 calc(var(--bark-button-pad) + 6px) 0 0); }',
      ladderCss,
    ].join('\n'),
    expect: each({
      'a 0.9em line-through': drawnOff('button#button-after "Duplicate"'),
      'an ::after "Cancel" over "Delete"': drawnOff('button#button-destructive "Delete"'),
      'a mirrored label': drawnOff('button#button-secondary "Save draft"'),
      'a label scaled to 0.95': drawnOff('button "Large"'),
      'an 8px cover on a corner': drawnOff('button#button-primary "Publish"'),
      'the last 5px clipped': drawnOff('button#button-save "Save changes"'),
      'the ladder': ladderHolds,
    }),
  },
  // Every other drawn reading, one plant each, on its own control.
  {
    name: 'each drawn reading turns both wide lights off at its own control',
    only: ['skins', 'schemes'],
    motion: true,
    plant: all(wrap, inCss('#button-after > span { color: var(--ui-background); }'), (d) =>
      appendFileSync(join(d, 'example.html'), `\n<div data-demo-row>\n${['ok', 'low', 'cut', 'clear'].map((v) => `  <input id="button-val-${v}" value="Typed ${v}">`).join('\n')}\n</div>\n`)),
    css: [
      '[id^="button-val-"] { font: inherit; padding: 4px 8px; border: 1px solid var(--ui-foreground); background: var(--ui-background); color: var(--ui-foreground); }',
      '#button-val-low { color: var(--ui-border); }',
      '#button-val-cut { box-sizing: border-box; height: 8px; padding: 0 8px; }',
      '#button-val-clear { color: transparent; }',
      '[data-slot="button"][data-size="sm"] { font-size: 0; }',
      'ui-button:has(> #button-secondary) { display: inline-flex; opacity: 0.15; }',
      'button:not(#button-more) > svg { opacity: 0.1; }',
      '#button-more > svg { clip-path: inset(0 0 60% 0); }',
      '#button-after { --bark-button-edge: transparent; --bark-button-bg: transparent; }',
      'ui-button:has(> #button-primary) { display: inline-block; padding: 12px; background-color: var(--ui-primary); }',
      '#button-quiet { mix-blend-mode: overlay; }',
      '#button-destructive { filter: opacity(0.15); }',
      // Beyond the lint and the browser-read walls (this sheet is the selftest's own): a rule only motion applies.
      '@keyframes x { to { color: var(--ui-primary) } }',
      '@media (prefers-reduced-motion: no-preference) { #button-primary { animation: x 1ms forwards; } }',
    ].join('\n'),
    expect: each({
      'a typed value under 4.5:1 on its ground': both(/drawn text [\d.]+:1 at input#button-val-low "" value/),
      'a typed value cut by a box too low for it': both(/label is cut: \d+% of it draws at input#button-val-cut "" value/),
      'a typed value painted transparent': both(/text does not draw at input#button-val-clear "" value/),
      'a typed value that draws in full stays on': (p) => !['skins', 'schemes'].some((l) => reasons(p, l).some((f) => /at input#button-val-ok "" value/.test(f))),
      'a size with no font': drawnOff('button "Small"'),
      'opacity on an ancestor': drawnOff('button#button-secondary "Save draft"'),
      'an icon faded out': drawnOff('button "New page" svg'),
      'an icon clipped': drawnOff('button#button-more'),
      'a label in a span painted its ground by part.css': drawnOff('span "Duplicate"'),
      'a control with no edge and no fill': both(/control boundary 1(\.00)?:1 at button#button-after/),
      'a focus ring lost on its ground': both(/focus on button#button-primary.*edge [\d.]+:1 against the ground/),
      'mix-blend-mode on one button': drawnOff('button#button-quiet "Cancel"'),
      'filter beyond its one value (vocabulary EXTRA)': drawnOff('button#button-destructive "Delete"'),
      'a label hidden only when motion is allowed': skinsSay(new RegExp(`motion allowed, .* animations finished: .*${DRAWN} at button#button-primary`)),
    }),
  },
  // The paint trace: every colour an element shows is one skin variable in every skin and scheme.
  {
    name: 'each colour that is not one skin variable turns "every skin" off, by name',
    only: ['skins', 'schemes'],
    plant: (d) => {
      mark(d, 'button-disabled')
      edit(join(d, 'part.css'), (s) => s.replace('--bark-button-edge: var(--ui-input);', '--bark-button-edge: var(--ui-border);'))
      edit(join(d, 'part.json'), (s) => s.replace(', "border-top-color": "--ui-input"', '').replace('"textOnly": ["[data-variant=\\"ghost\\"]"]', '"textOnly": ["[data-variant=\\"ghost\\"]", "[data-slot=\\"button\\"]:not([data-variant])"]'))
    },
    css: [
      '#button-after { background-color: #ffffff; color: #111111; }',
      '#button-primary { background-image: linear-gradient(#ff0000, #ff0000); }',
      '#button-secondary { box-shadow: 0 0 0 3px #ff0000; }',
      '#button-quiet { background-image: url(data:image/gif;base64,R0lGODlhAQABAAAAACw=); }',
      '#button-destructive { border-right-color: #ff0000; }',
      '#button-more svg { fill: #ff0000; }',
      '[data-slot="button"][data-size="lg"]::before { content: "\\25CF  "; color: #ff0000; }',
      '#button-disabled { background-color: #ffffff; color: #eeeeee; }',
      // The trace reads caret-color from style, never while the readings hide the caret with a sheet of their own.
      '#button-save { caret-color: #ff0000; }',
    ].join('\n'),
    expect: each({
      'a frozen colour': skinsSay(/button#button-after .* is not one skin variable/),
      'a gradient': skinsSay(/button#button-primary .*background-image #1 is not one skin variable/),
      'a shadow colour': skinsSay(/button#button-secondary .*box-shadow #1 is not one skin variable/),
      'a bitmap image': skinsSay(/button#button-quiet .*shows an image that is not a data: SVG/),
      'a right border colour': skinsSay(/button#button-destructive .*border-right-color is not one skin variable/),
      'an icon in its own fill': skinsSay(/svg .* fill is not one skin variable/),
      'a red ::before': skinsSay(/button "Large"::before color is not one skin variable/),
      'a caret colour': skinsSay(/button#button-save .*caret-color is not one skin variable/),
      'a paint-free element with its own fill': skinsSay(/paint-free button#button-disabled .* carries its own background/),
      'text-only on controls that draw an edge': skinsSay(/text-only button.* draws its (edge|fill) at [\d.]+:1/),
    }),
  },
  {
    name: 'a demo that patches getComputedStyle, getClientRects and querySelector cannot hide a red label from the trace',
    only: ['skins', 'schemes'],
    css: '#button-after { color: #ff0000; }',
    plant: (d) => inDemo(d, [
      "const k = 'getComputed' + 'Style'; const g = window[k]; window[k] = (el, p) => g(el && el.id === 'button-after' ? document.querySelector('#button-secondary') : el, p)",
      "const P = Element['proto' + 'type']; const r = P.getClientRects; P.getClientRects = function () { return this.id === 'button-after' ? [] : r.call(this) }",
      "const D = Document['proto' + 'type']; const q = D.querySelector; D.querySelector = function (s) { return q.call(this, s === '[data-part=\"button\"]' ? '.sr-title' : s) }",
    ].join('\n')),
    expect: skinsSay(/button#button-after "Duplicate" color is not one skin variable/),
  },
  {
    name: 'an honest decorative dot keeps "every skin" on',
    only: ['skins', 'schemes'],
    green: true,
    plant: inCss('#button-after::before { content: ""; display: inline-block; width: 6px; height: 6px; border-radius: 50%; background: var(--ui-primary); }'),
    expect: (p) => lights(p).skins.pass && lights(p).schemes.pass,
  },
  ...SURFACE_CASES,
  // Phone width: read in full in every skin, scheme and surface. part.css may not change paint at phone width
  // (refused below), so these rules come from the selftest's own sheet, beyond that wall.
  {
    name: 'a label blanked, edges dropped, and a label and edge gone on raised only, at phone width, turn "phone" off, each by name',
    only: ['phone'],
    surfaces: true,
    css: [
      '@media (max-width: 600px) { [data-slot="button"][data-size="lg"] { --bark-button-fg: var(--ui-background); } }',
      '@media (max-width: 600px) { [data-slot="button"]:not([data-variant]):not([data-size]) { --bark-button-edge: transparent; } }',
      '@media (max-width: 600px) { [data-surface="raised"] #button-secondary { --bark-button-fg: var(--bark-button-bg); --bark-button-edge: var(--bark-button-bg); } }',
    ].join('\n'),
    expect: each({
      'a blanked label': phoneSays(new RegExp(`${DRAWN} at button "Large"`)),
      'dropped edges': phoneSays(/control boundary [\d.]+:1 at button/),
      'a label gone on raised only': phoneSays(new RegExp(`on raised: .*${DRAWN} at button#button-secondary`)),
    }),
  },
  {
    name: 'a demo that patches getBoundingClientRect cannot pull a button back inside a phone window',
    only: ['phone'],
    css: '#button-after { position: fixed; left: 370px; top: 0; }',
    plant: (d) => inDemo(d, "const P = Element['proto' + 'type']; const g = P.getBoundingClientRect; P.getBoundingClientRect = function () { const r = g.call(this); return new DOMRect(0, r.y, Math.min(r.width, 1), r.height) }"),
    expect: (p) => /Duplicate ends past the window/.test(lights(p).phone.detail),
  },
  // No script.
  {
    name: 'a paint-free element hidden with no script turns "printed with no script" off',
    only: ['noscript'],
    plant: (d) => mark(d, 'button-after'),
    css: 'ui-button:not(:defined) > [data-paint-free] { visibility: hidden; }',
    expect: (p) => /button#button-after .* is hidden/.test(lights(p).noscript.detail),
  },
  ...[
    ['visibility: hidden', /is hidden/],
    ['opacity: 0', /is hidden|opaque/],
  ].map(([rule, re]) => ({
    name: `no-script content under ${rule} turns "printed with no script" off`,
    only: ['noscript'],
    css: `ui-button:not(:defined) > [data-slot] { ${rule}; }`,
    expect: (p) => re.test(lights(p).noscript.detail),
  })),
  {
    name: 'no-script content clipped to a sliver turns "printed with no script" off',
    only: ['noscript'],
    plant: inCss('ui-button:not(:defined) { display: inline-block; width: 6px; overflow: hidden; }'),
    expect: (p) => /cut off|clipped/.test(lights(p).noscript.detail),
  },
  // Pressed by real keys.
  // A caret blinks while its field is focused, so a reading can catch it in one capture and not another. Two
  // focused empty fields hold each half of that on purpose: each caret is held steady by the browser (no blink),
  // and a sheet of the fixture's own turns it out, or back on, only while the reading has the glyphs unpainted.
  {
    name: 'a reading is the same whether or not the caret is drawn',
    only: ['pressed'],
    states: true,
    green: true,
    css: '#button-caret-drawn { caret-animation: manual; } #button-caret-glyphs { caret-animation: manual; caret-color: transparent; }',
    plant: (d) => {
      appendFileSync(join(d, 'example.html'), `
<div data-demo-row>
  <input id="button-caret-drawn" data-slot="input" placeholder="Spring reading list">
  <input id="button-caret-glyphs" data-slot="input" placeholder="Spring reading list">
</div>
`)
      // Each expect is sent to the page alone, so each step is written out whole, with nothing shared.
      const step = (id, picture, caret) => `
steps.push({
  name: 'a focused empty field whose caret shows in the ${picture} picture only',
  expect: (root) => {
    const field = root.querySelector('#${id}')
    field.focus()
    const sheet = document.createElement('style')
    sheet.textContent = '#${id} { caret-color: ${caret}; }'
    new MutationObserver(() => {
      const unpainted = getComputedStyle(field).webkitTextFillColor === 'rgba(0, 0, 0, 0)'
      if (unpainted && !sheet.isConnected) document.head.append(sheet)
      if (!unpainted && sheet.isConnected) sheet.remove()
    }).observe(document.head, { childList: true })
    return document.activeElement === field || 'the field lost focus'
  },
})
`
      appendFileSync(join(d, 'press.mjs'), step('button-caret-drawn', 'drawn', 'transparent') + step('button-caret-glyphs', 'glyph', 'auto'))
    },
    expect: each({
      'both readings ran': (p) => ['drawn', 'glyph'].every((w) => (p.parts.button.steps ?? []).some((st) => st.name === `a focused empty field whose caret shows in the ${w} picture only`)),
      'a focused empty field with a placeholder draws in full, its caret in the drawn picture only': (p) => (p.parts.button.steps ?? []).some((st) => /caret shows in the drawn picture only/.test(st.name) && st.pass),
      'a focused empty field with a placeholder draws in full, its caret in the glyph picture only': (p) => (p.parts.button.steps ?? []).some((st) => /caret shows in the glyph picture only/.test(st.name) && st.pass),
    }),
  },
  // A Tab into a filled field selects its whole value, and a browser may paint a selection in colours of its own.
  // The fixture plants such colours and holds the value selected by a real Tab; its twin, the same value in the same
  // style, is never selected. The check's own reader reads both in one view.
  {
    name: 'a reading is the same whether or not text in a field is selected',
    direct: async () => {
      const scratch = mkdtempSync(join(tmpdir(), 'barkui-selftest-'))
      const browser = await launch({ args: ['--disable-lcd-text'] })
      try {
        const dir = join(scratch, 'parts')
        cpSync(join(partsDir, 'button'), join(dir, 'button'), { recursive: true })
        appendFileSync(join(dir, 'button', 'example.html'), `
<div data-demo-row>
  <input id="button-sel-before" data-slot="input" placeholder="Before">
  <input id="button-sel" data-slot="input" value="post-1042">
  <input id="button-sel-twin" data-slot="input" value="post-1042">
</div>
`)
        const css = '::selection { color: rgb(255, 255, 255); background-color: rgb(51, 103, 214); }'
        const built = await buildShowroom({ dir, out: join(scratch, 'out'), proof: join(scratch, 'proof.json'), quiet: true, plantCss: css })
        const part = built.parts.find((x) => x.name === 'button')
        const page = await open({ browser, url: pathToFileURL(built.file).href, part: part.name, errors: [] }, { scale: 2, height: 1600 })
        await page.barkCheck(() => document.getElementById('button-sel-before').focus())
        await press(page, 'Tab')
        const held = await page.barkCheck(() => {
          const f = document.getElementById('button-sel')
          return document.activeElement === f && f.selectionStart === 0 && f.selectionEnd === f.value.length
        })
        const { things } = await readView(page, part)
        const of = (id) => things.find((t) => t.at.startsWith(`input#${id} `) && t.kind === 'text')
        const [sel, twin] = [of('button-sel'), of('button-sel-twin')]
        const measures = ['draws', 'ratio', 'share', 'match'].map((k) => [k, ...[sel, twin].map((t) => (typeof t?.[k] === 'number' ? t[k].toFixed(2) : t?.[k]))])
        const same = held && sel && twin && measures.every(([, a, b]) => a === b)
        if (!same) console.log(`    selected by Tab: ${held}; ${measures.map(([k, a, b]) => `${k} ${a} selected, ${b} twin`).join('; ')}`)
        return same
      } finally {
        await browser.close()
        rmSync(scratch, { recursive: true, force: true })
      }
    },
  },
  {
    name: 'a press step that never settles fails by name within its time limit',
    only: ['pressed'],
    plant: (d) => appendFileSync(join(d, 'press.mjs'), "\nsteps.splice(1, 0, { name: 'never settles', expect: () => new Promise(() => {}) })\n"),
    expect: (p) => /never settles.*timed out after/.test(lights(p).pressed.detail),
  },
  {
    name: 'a clear cover over a control a step clicks turns "pressed" off',
    only: ['pressed'],
    css: 'ui-button:has(> #button-disabled) { position: relative; }\nui-button:has(> #button-disabled)::after { content: ""; position: absolute; inset: 0; }',
    expect: (p) => /is not what a click at its centre reaches: ui-button "Unavailable" is on top/.test(lights(p).pressed.detail),
  },
  {
    name: 'pointer-events: none on an enabled control a step clicks turns "pressed" off',
    only: ['pressed'],
    plant: inCss('#button-secondary { pointer-events: none; }'),
    expect: (p) => /#button-secondary is not what a click at its centre reaches/.test(lights(p).pressed.detail),
  },
  {
    name: 'an icon-only button with no name turns "pressed" off',
    only: ['pressed'],
    plant: (d) => edit(join(d, 'example.html'), (s) => s.replace(' aria-label="More actions"', '')),
    expect: (p) => /#button-more name=""/.test(lights(p).pressed.detail),
  },
  {
    name: 'styling that waits until after the demo has run is caught after a press step',
    only: ['pressed'],
    plant: (d) => inDemo(d, "setTimeout(() => { root.querySelector('#button-after')['sty' + 'le'].color = '#ff0000' }, 2500)"),
    expect: failedSay(/after step .*button#button-after "Duplicate" was given color in a style attribute, which is not placement/),
  },
  // The run-time guard: what dodges the lint is caught once the demo has run.
  ...[
    ['an inline style spelled to dodge the lint', "root.querySelector('#button-after')['sty' + 'le'].color = '#ff0000'", /button#button-after "Duplicate" was given color in a style attribute, which is not placement/],
    ['a <style> spelled to dodge the lint', "document.head.append(Object.assign(document.createElement('sty' + 'le'), { textContent: '#button-after::before { content: \"x\"; color: #ff0000 }' }))", /a stylesheet the build did not put there/],
    ['a rule slipped into the UI SDK sheet', "const s = [...document['style' + 'Sheets']].find((x) => !x.href); s['insert' + 'Rule']('#button-after { color: #ff0000 }')", /rules changed/],
    ['an adopted sheet', "const S = window['CSS' + 'StyleSheet']; const s = new S(); s['replace' + 'Sync']('#button-after { color: #ff0000 }'); document['adopted' + 'StyleSheets'] = [s]", /adopted/],
    ['a script animation', "root.querySelector('#button-after')['ani' + 'mate']([{ color: '#ff0000' }, { color: '#ff0000' }], { duration: 1e7 })", /a script animation/],
  ].map(([what, code, re]) => ({
    name: `${what} in demo.mjs fails the run, naming what changed`,
    only: ['pressed'],
    plant: (d) => inDemo(d, code),
    expect: failedSay(re),
  })),
  {
    name: 'styling at the top of demo.mjs, outside its function, fails the run',
    only: ['pressed'],
    plant: (d) => appendFileSync(join(d, 'demo.mjs'), "\ndocument.head.append(Object.assign(document.createElement('sty' + 'le'), { textContent: '#button-after { color: #ff0000 }' }))\n"),
    expect: failedSay(/a stylesheet the build did not put there/),
  },
  {
    name: 'a console error lights nothing, and the page says the run failed',
    only: ['pressed'],
    plant: (d) => inDemo(d, "  console.error('planted')"),
    expect: (p, html) => p.parts.button.failed && !lights(p).pressed.pass && !html.includes('data-on="true"') && html.includes('The last check run failed'),
  },
  // Refused before a browser opens.
  {
    name: 'a span coloured by demo.mjs is refused at discovery',
    only: ['pressed'],
    plant: all(wrap, (d) => inDemo(d, "root.querySelector('#button-after > span').style.color = '#ff0000'")),
    expect: refused(/demo\.mjs line 3: sets an inline style/),
  },
  {
    name: 'a class part.css never declares, added by demo.mjs, is refused at discovery',
    only: ['pressed'],
    plant: (d) => inDemo(d, "root.querySelector('#button-after').classList.add('loud')"),
    expect: refused(/demo\.mjs line 3: classList\.add uses "loud"/),
  },
  {
    name: 'a colour that only applies when motion is allowed is refused at discovery',
    only: ['pressed'],
    plant: inCss('@media (prefers-reduced-motion: no-preference) { [data-slot="button"][data-size="lg"] { color: var(--ui-background); } }'),
    expect: refused(/part\.css line \d+: .*prefers-reduced-motion.* only transition, animation and scroll-behavior/),
  },
  {
    name: 'filter at any value but none in part.css is refused at discovery',
    only: ['pressed'],
    plant: inCss('#button-after { filter: opacity(0.1); }'),
    expect: refused(/part\.css line \d+: filter: opacity\(0\.1\); part\.css may only set filter to none/),
  },
  // What a part does not cover is a row of part.json "notCovered" (build/parts.mjs): prose that says something is
  // not covered and names no row is refused by name; with the row, the same part is read.
  {
    name: 'a summary or part.css note that says something is not covered is refused at discovery unless part.json "notCovered" names it',
    direct: () => {
      const root = mkdtempSync(join(tmpdir(), 'barkui-selftest-'))
      try {
        const dir = join(root, 'button')
        cpSync(join(partsDir, 'button'), dir, { recursive: true })
        const json = JSON.parse(readFileSync(join(dir, 'part.json'), 'utf8'))
        const css = readFileSync(join(dir, 'part.css'), 'utf8')
        const plant = (summary, notes, list) => {
          writeFileSync(join(dir, 'part.json'), JSON.stringify({ ...json, summary: `${json.summary} ${summary}`.trim(), ...(list && { notCovered: list }) }))
          writeFileSync(join(dir, 'part.css'), `${css}\n/* ${notes} */\n`)
          try {
            discoverParts(root)
            return ''
          } catch (e) {
            return e.message
          }
        }
        const said = [
          /^parts\/button: part\.json "summary" says something is not covered \("Its ui-badge is not styled\."\), and part\.json "notCovered" names none of it/.test(plant('Its ui-badge is not styled.', 'Nothing more.')),
          /^parts\/button: part\.css's notes says something is not covered \("The ripple is not proved\."\)/.test(plant('', 'The ripple is not proved.')),
          plant('Its ui-badge is not styled.', 'The ripple is not proved.', [{ name: 'ui-badge', why: 'A planted reason.' }, { name: 'ripple', why: 'A planted reason.' }]) === '',
        ]
        if (!said.every(Boolean)) console.log(`    not as wanted: input ${said.flatMap((ok, k) => (ok ? [] : [k + 1])).join(', ')}`)
        return said.every(Boolean)
      } finally {
        rmSync(root, { recursive: true, force: true })
      }
    },
  },
  // The reviewer's own inputs: each refused before a browser opens, and each refused again by the browser's reading.
  ...[
    ['its own keyframes, run only when motion is allowed', '@keyframes x { to { color: var(--ui-primary) } }\n@media (prefers-reduced-motion: no-preference) { #button-primary { animation: x 1ms forwards; } }', /a part defines no keyframes/],
    ['an escaped @media for a width the check never renders', String.raw`@\6d edia (min-width: 1600px) { [data-slot="button"] { color: var(--ui-background); } }`, /a backslash/],
    ['an escaped filter', String.raw`#button-after { fil\000074er: blur(2px); }`, /a backslash/],
    ['an escaped outline', String.raw`#button-after { outl\000069ne: none; }`, /a backslash/],
    ['a paint change at phone width, on one surface', '@media (max-width: 600px) { [data-surface="raised"] #button-secondary { --bark-button-fg: var(--bark-button-bg); --bark-button-edge: var(--bark-button-bg); } }', /--bark-button-fg inside @media \(max-width: 600px\): only layout and type/],
    ['a brace that closes the bark-parts layer early', '} [data-slot="button"] { box-shadow: none; } @layer bark-parts {', /a \} with no \{ before it/],
    // The forms a part sheet is written in (build/css-lint.mjs sheetForms), each refused by name outside them.
    ['a url( with no quoted string straight after it', '#button-after { --bark-i: url(data:image/svg+xml,%3Csvg%20fill=currentColor/%3E); }', /url\( with no quoted string straight after it/],
    ['a string that runs past the end of its line', '#button-after { --bark-y: "a\n; }', /a string runs past the end of its line/],
    ['a comment inside a value', '#button-after { gap: 0px /* x */; }', /a comment inside a selector, a condition or a value/],
    ['a comment inside a selector', '#button-after /* x */ span { gap: 0px; }', /a comment inside a selector, a condition or a value/],
    ['a comment opened in an unquoted url( that hides a dropped rule', '[data-slot="button"] { --bark-i: url(data:image/svg+xml,%3Csvg%20fill=currentColor%3E/*%3C/svg%3E); }\n[data-slot="button"]:bark-made-up { color: var(--ui-foreground); }\n[data-slot="button"] { --bark-i: url(data:image/svg+xml,%3Csvg%20fill=currentColor%3E*/}[data-slot="button"]{%3C/svg%3E); }', /url\( with no quoted string straight after it/],
  ].map(([what, css, re]) => ({
    name: `part.css with ${what} is refused at discovery`,
    only: ['pressed'],
    plant: inCss(css),
    expect: refused(re),
  })),
  {
    name: "the browser's reading of part.css refuses the same inputs with no help from the text lint",
    direct: async () => {
      const browser = await launch()
      try {
        const said = []
        for (const [css, re] of [
          ['@keyframes x { to { color: var(--ui-primary) } }\n@media (prefers-reduced-motion: no-preference) { #button-primary { animation: x 1ms forwards; } }', /CSSKeyframesRule/],
          [String.raw`@\6d edia (min-width: 1600px) { a { gap: 1px; } }`, /@media \(min-width: 1600px\): not a view the check renders/],
          [String.raw`a { fil\000074er: blur(2px); }`, /filter: blur\(2px\); it may only be none/],
          [String.raw`a { outl\000069ne: none; }`, /outline-style is outside part\.css's vocabulary/],
          ['} a { box-shadow: none; } @layer bark-parts {', /where part\.css's one bark-parts layer belongs/],
          ['@media (max-width: 600px) { [data-surface="raised"] #button-secondary { --bark-button-fg: var(--bark-button-bg); --bark-button-edge: var(--bark-button-bg); } }', /--bark-button-edge inside @media \(max-width: 600px\): only layout and type/],
          // A state on the host, where no pin reaches; and states and pseudo-elements outside the allow-list.
          ['ui-button:hover > [data-slot="button"] { --bark-button-hover-fg: var(--bark-button-hover-bg); }', /ui-button:hover > \[data-slot="button"\]: :hover is on a host, ancestor or sibling/],
          ['a { &:hover { & svg { gap: 0; } } }', /& svg: the rule it is nested in pins a state/],
          ['a:target { gap: 0; }', /:target is not a pseudo-class part\.css may use/],
          ['a::first-line { gap: 0; }', /::first-line is not a pseudo-element the check reads/],
          // What the text lint also refuses, refused by the parse itself.
          ['a { gap: 1px !important; }', /row-gap is !important/],
          ['@media (prefers-reduced-motion: reduce) { a { --bark-button-fg: var(--ui-primary); } }', /--bark-button-fg inside @media \(prefers-reduced-motion\)/],
          ['a { color: var(--ui-primary, var(--ui-background)); }', /var\(--ui-primary,… gives a variable a fallback/],
          // An open parenthesis at the end runs on into the next part on the page.
          ['a { gap: 0; }\nb:not([data-size] { gap: 0; }', /part\.css does not end where its rules end/],
        ]) said.push((await readPartCss(browser, css)).found.some((f) => re.test(f)))
        if (!said.every(Boolean)) console.log(`    not caught: input ${said.indexOf(false) + 1}`)
        return said.every(Boolean)
      } finally {
        await browser.close()
      }
    },
  },
  // What ships is what was judged: the page loads every part in one barkui.css.
  {
    name: 'a part whose open parenthesis would run into the next part on the page is refused by name, and the next part is not blamed',
    only: ['pressed'],
    plant: (d) => {
      const to = copyAs(d, 'aa-button')
      edit(join(to, 'part.css'), (t) => `${t.replace(/^\[data-slot="button"\] \{/m, '[data-part="aa-button"] [data-slot="button"] {')}\n[data-part="aa-button"] [data-slot="button"]:not([data-size] { gap: calc(var(--ui-spacing) * 2); }\n`)
    },
    expect: (p, html, ok, logs) => refused(/parts\/aa-button\/part\.css, as the browser reads it: part\.css does not end where its rules end/)(p, html, ok, logs) && !logs.some((l) => l.includes('parts/button/')),
  },
  {
    name: "a page whose barkui.css differs from a part as it was judged alone fails, naming that part and no other",
    direct: async () => {
      const scratch = mkdtempSync(join(tmpdir(), 'barkui-selftest-'))
      const browser = await launch()
      try {
        const dir = join(scratch, 'parts')
        cpSync(join(partsDir, 'button'), join(dir, 'button'), { recursive: true })
        copyAs(join(dir, 'button'), 'aa-button')
        const out = join(scratch, 'out')
        const built = await buildShowroom({ dir, out, proof: join(scratch, 'proof.json'), quiet: true })
        const judged = []
        for (const part of built.parts) judged.push({ name: part.name, rules: (await readPartCss(browser, part.css)).rules })
        const sheet = join(out, 'barkui.css')
        const honest = await sameAsShipped(browser, sheet, judged)
        // Drop one declaration from the first part's section only, as a page that ships other rules would.
        const text = readFileSync(sheet, 'utf8')
        const at = text.indexOf('/* parts/aa-button/part.css */')
        writeFileSync(sheet, text.slice(0, at) + text.slice(at).replace('min-width: var(--bark-button-height);', ''))
        const found = await sameAsShipped(browser, sheet, judged)
        const held = !honest.length && found.length === 1 && found[0].startsWith('parts/aa-button/part.css: ')
        if (!held) console.log(`    honest: ${honest.join('; ')}\n    planted: ${found.join('; ')}`)
        return held
      } finally {
        await browser.close()
        rmSync(scratch, { recursive: true, force: true })
      }
    },
  },
  // States: one allowed form, and the real state held to its pin.
  {
    name: 'a state on the host in part.css is refused at the browser read, where no pin reaches it',
    only: ['pressed'],
    plant: inCss('ui-button:hover > [data-slot="button"] { --bark-button-hover-fg: var(--bark-button-hover-bg); --bark-button-hover-edge: var(--bark-button-hover-bg); }'),
    expect: refused(/ui-button:hover > \[data-slot="button"\]: :hover is on a host, ancestor or sibling/),
  },
  {
    name: 'a list inside :is() in part.css is refused from the text, as a branch coverage cannot see',
    only: ['pressed'],
    plant: inCss('[data-slot="button"]:is([data-size="sm"], [data-size="huge"]) { --bark-button-text: 0.875rem; }'),
    expect: refused(/:is\(\[data-size="sm"\], \[data-size="huge"\]\) holds a list of 2; coverage reads a rule branch by branch/),
  },
  // One arm the browser does not know: :is() and :where() drop it and keep the rule, so the text is read, not what
  // the browser hands back. A list in them is refused from the text; a single unknown arm, or one in a nested rule,
  // is read alone and refused by name; a plain list with one drops the whole rule.
  ...[
    ['a list in :is() with one unknown arm', '[data-slot="button"]:is([data-size="sm"], [data-size="sm"]:bark-made-up) { gap: 0px; }', /:is\(\[data-size="sm"\], \[data-size="sm"\]:bark-made-up\) holds a list of 2/],
    ['a list in :where() with one unknown arm', '[data-slot="button"]:where([data-size="sm"], :bark-made-up) { gap: 0px; }', /:where\(\[data-size="sm"\], :bark-made-up\) holds a list of 2/],
    ['an unknown arm alone in :is()', '[data-slot="button"]:is(:bark-made-up) { gap: 0px; }', /the arm :bark-made-up is one the browser drops/],
    ['an unknown arm alone in :where()', '[data-slot="button"]:where(:bark-made-up) { gap: 0px; }', /the arm :bark-made-up is one the browser drops/],
    ['an unknown arm in :is() in a nested rule', '[data-slot="button"] { &:is(:bark-made-up) { gap: 0px; } }', /&:is\(:bark-made-up\): the arm :bark-made-up is one the browser drops/],
    ['an unknown arm in a plain list', '[data-slot="button"][data-size="sm"], [data-slot="button"]:bark-made-up { gap: 0px; }', /\[data-slot="button"\]:bark-made-up: the browser drops this rule/],
  ].map(([what, css, re]) => ({ name: `part.css with ${what} is refused by name`, only: ['pressed'], plant: inCss(css), expect: refused(re) })),
  {
    name: 'a rule the browser drops is refused by name, at the top of part.css and nested',
    only: ['pressed'],
    plant: all(
      inCss('[data-slot="button"]:bark-made-up { color: var(--ui-foreground); }'),
      inCss('[data-slot="button"] { &:bark-made-up-too { color: var(--ui-foreground); } }'),
    ),
    expect: (...a) => refused(/\[data-slot="button"\]:bark-made-up: the browser drops this rule, so nothing would judge it/)(...a) && refused(/&:bark-made-up-too: the browser drops this rule/)(...a),
  },
  {
    // Refused at discovery by the part-sheet forms; the browser's reading refuses the same sheet on its own (the
    // direct case below names the dropped rule).
    name: 'a dropped rule beside a string broken by a newline is refused at discovery, naming the string',
    only: ['pressed'],
    plant: inCss('[data-slot="button"]:bark-made-up { color: var(--ui-foreground); }\n[data-slot="button"] { --bark-y: "a\n; }\n[data-slot="button"].k { gap: 0px; }'),
    expect: refused(/part\.css line \d+: a string runs past the end of its line/),
  },
  {
    name: 'a sheet the check cannot read rule for rule the way the browser does is refused, and one it reads is not',
    direct: async () => {
      const browser = await launch()
      const cannot = /the check cannot read this sheet the way the browser does/
      const either = /the check cannot read this sheet the way the browser does|the browser drops this rule/
      try {
        const said = []
        for (const [css, re, wanted] of [
          // A string left open at a newline, between a dropped rule and a plain one.
          ['[data-slot="button"]:bark-made-up { color: var(--ui-foreground); }\n[data-slot="button"] { --bark-y: "a\n; }\n[data-slot="button"].k { gap: 0px; }', /\[data-slot="button"\]:bark-made-up: the browser drops this rule/, true],
          // A rule with no block, so the counts would even out: the dropped rule is still named, and the count refused.
          ['@layer x;\na:bark-made-up { gap: 0; }', /^a:bark-made-up: the browser drops this rule/, true],
          ['@layer x;\na:bark-made-up { gap: 0; }', /does: at the top of part\.css: part\.css writes 0 rule\(s\) the browser reads alone, and the browser reads 1/, true],
          // A brace inside an unquoted url(), which the text reader takes for a block.
          ['a { --x: url({); }\nb { gap: 0; }', cannot, true],
          // A comment opened inside an unquoted url(), which hides a dropped rule from the text reader.
          ['[data-slot="button"] { --bark-i: url(data:image/svg+xml,%3Csvg%20fill=currentColor%3E/*%3C/svg%3E); }\n[data-slot="button"]:bark-made-up { color: var(--ui-foreground); }\n[data-slot="button"] { --bark-i: url(data:image/svg+xml,%3Csvg%20fill=currentColor%3E*/}[data-slot="button"]{%3C/svg%3E); }', cannot, true],
          // Nothing refused where the two readings agree.
          ['[title="{"] { content: "}"; } a\\{b { gap: 0 } /* } */ c { gap: 0; }', either, false],
          ['a { gap: 0; &:hover { gap: 1px; } gap: 2px; @media (max-width: 600px) { gap: 3px; } }', either, false],
          ['@keyframes bark-x { from { gap: 0; } to { gap: 1px; } }\n@media (prefers-reduced-motion: no-preference) { a { & > b { gap: 0; } } }', either, false],
        ]) said.push((await readPartCss(browser, css)).found.some((f) => re.test(f)) === wanted)
        if (!said.every(Boolean)) console.log(`    not as wanted: input ${said.indexOf(false) + 1}`)
        return said.every(Boolean)
      } finally {
        await browser.close()
      }
    },
  },
  {
    name: 'an arm inside :is() or :where() that the browser drops in its place is refused by name, and one it keeps is not',
    direct: async () => {
      const browser = await launch()
      const any = /the arm |inside :(is|where)\(\) in its place/
      try {
        const said = []
        for (const [css, re, wanted] of [
          ['[data-slot="button"]:is(::before) { gap: 0px; }', /^\[data-slot="button"\]:is\(::before\): the arm ::before is one the browser drops/, true],
          ['[data-slot="button"] { &:is(> span) { gap: 0px; } }', /^&:is\(> span\): the arm > span is one the browser drops/, true],
          ['[data-slot="button"], [data-slot="button"]:is(::before) { gap: 0px; }', /the arm ::before is one the browser drops/, true],
          ['[data-slot="button"]:not(:where(::after)) { gap: 0px; }', /the arm ::after is one the browser drops/, true],
          ['[data-slot="button"]:is(:where(::before)) { gap: 0px; }', /the arm ::before is one the browser drops/, true],
          ['[data-slot="button"]:nth-child(1 of :where(::before)) { gap: 0px; }', /the arm ::before is one the browser drops/, true],
          // Dropped where it stands in its compound, though it reads alone and inside :is() alone.
          ['[data-slot="button"]::before:is(:hover) { gap: 0px; }', /::before:is\(:hover\): the arm :hover is one the browser drops/, true],
          ['[data-slot="button"]::before:is([data-a]) { gap: 0px; }', /::before:is\(\[data-a\]\): the arm \[data-a\] is one the browser drops/, true],
          ['[data-slot="button"]::before:where(:first-child) { gap: 0px; }', /::before:where\(:first-child\): the arm :first-child is one the browser drops/, true],
          ['[data-slot="button"]::placeholder:is(:hover) { gap: 0px; }', /::placeholder:is\(:hover\): the arm :hover is one the browser drops/, true],
          // Kept, though the browser writes it back in its own way.
          ['[data-slot="button"]:is([data-size=sm]) { gap: 0px; }', any, false],
          ['[data-slot="button"] { &:where(:HOVER) { gap: 0px; } }', any, false],
          ['[data-slot="button"]:not([data-a], [data-b]):has(> span) { gap: 0px; }', any, false],
          ['[data-slot="button"]:where([data-size=sm])::before { gap: 0px; }', any, false],
        ]) said.push((await readPartCss(browser, css)).found.some((f) => re.test(f)) === wanted)
        if (!said.every(Boolean)) console.log(`    not as wanted: input ${said.flatMap((ok, k) => (ok ? [] : [k + 1])).join(', ')}`)
        return said.every(Boolean)
      } finally {
        await browser.close()
      }
    },
  },
  {
    name: 'an uppercase :HOVER in part.css is pinned like any other, and a longhand left out but set through a variable is read as computed',
    only: ['skins', 'schemes'],
    plant: all(
      inCss('[data-slot="button"][data-variant="solid"]:HOVER:not([data-disabled]) { --bark-button-hover-fg: var(--bark-button-hover-bg); }'),
      inCss('#button-after { --bark-bgx: var(--bark-button-bg) text; background: var(--bark-bgx); }'),
    ),
    expect: each({
      'the pinned Hover row draws what the uppercase rule does': drawnOff('button "Hover"'),
      'background-clip: text through a variable': skinsSay(/button#button-after "Duplicate" computes background-clip: text/),
    }),
  },
  ...STATE_CASES,
  ...CHECKED_CASES,
  ...CEILING_CASES,
  ...LAYER_CASES,
  ...PLACEMENT_CASES,
  ...SLIDER_CASES,
  ...NUMBER_CASES,
  ...REST_CASES,
  ...POINTER_CASES,
  ...PAGE_CASES,
  ...VERDICT_CASES,
  ...WALL_CASES,
  ...TIME_CASES,
  {
    name: 'one part more than one CI job holds is refused, with the sentence that says how many it holds',
    plant: (d) => {
      for (let i = 0; i < PER_JOB; i++) copyAs(d, `held${String.fromCharCode(97 + i)}-button`)
    },
    expect: (p, html, ok, logs) => !ok && p === null && logs.some((l) => l.includes(`${PER_JOB + 1} parts in one job, more than one CI job holds. ${capacitySentence()}`)),
  },
  {
    name: 'a part.json that names a property to allow is refused at discovery',
    only: ['pressed'],
    plant: (d) => edit(join(d, 'part.json'), (s) => JSON.stringify({ ...JSON.parse(s), allow: { 'mix-blend-mode': 'a reason' } })),
    expect: refused(/part\.json "allow" is gone/),
  },
  {
    name: 'a <style> in example.html fails the run',
    only: ['pressed'],
    plant: (d) => edit(join(d, 'example.html'), (s) => `<style>button { background-image: linear-gradient(#ff0000, #ff0000) }</style>\n${s}`),
    expect: (p, html, ok) => !ok && p === null,
  },
  {
    name: 'a part folder without press.mjs fails the run',
    only: ['pressed'],
    plant: (d) => rmSync(join(d, 'press.mjs')),
    expect: (p, html, ok) => !ok && p === null,
  },
]

/** The part a case runs on: `part` names one of the package's parts (build/parts.mjs, discoverParts); a case
    without the key runs on the button. A name that is not a part, or a key with no name, fails the case by its name. */
export function partOf(c, names = discoverParts().map((p) => p.name)) {
  if (!Object.hasOwn(c, 'part')) return 'button'
  if (typeof c.part === 'string' && names.includes(c.part)) return c.part
  throw new Error(`the case "${c.name}" runs on the part ${JSON.stringify(c.part ?? null)}, which is not one; the parts are ${names.join(', ')} (parts/)`)
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  let failures = 0
  // node check/selftest.mjs --job <key> [words]: the cases that job runs (check/jobs.mjs, selftestJob), under its
  // ceiling; CI runs one job per key. Without --job, every case, under the sum of the jobs' ceilings. With words,
  // only the cases whose name holds them.
  // --report <file>: the job's report for the closing check (check/selftest-report.mjs).
  const args = process.argv.slice(2)
  const at = args.indexOf('--report')
  const report = at < 0 ? null : args.splice(at, 2)[1]
  const key = args[0] === '--job' ? args[1] : null
  if (key !== null && !SELFTEST_JOBS.some((j) => j.key === key)) {
    console.log(`FAIL the selftest has no job ${JSON.stringify(key)}; its jobs are ${SELFTEST_JOBS.map((j) => j.key).join(', ')} (check/jobs.mjs)`)
    process.exit(1)
  }
  const pick = args.slice(key === null ? 0 : 2).join(' ')
  const run = selftestPick(CASES, key, pick)
  if (!run.length) {
    console.log(`FAIL the selftest${key === null ? '' : ` job ${key}`} has no case${pick ? ` whose name holds "${pick}"` : ''} to run; a selftest of nothing is never green`)
    process.exit(1)
  }
  const start = Date.now()
  let now = ''
  const keys = key === null ? SELFTEST_JOBS.map((j) => j.key) : [key]
  const ceiling = keys.reduce((n, k) => n + SELFTEST_CEILINGS[k], 0)
  enforceCeiling(ceiling, (s) => `FAIL the selftest passed its ceiling of ${s} s while "${now}" ran. ${keys.map((k) => selftestSentence(k)).join(' ')} Read it again on CI's runner and put the reading in check/capacity.mjs, or split the selftest again.`)
  const held = []
  // A refusal by the wall (check/acts.mjs) while a case runs, a timer's or a listener's too, makes that case red by
  // the refused name and the file that reached it. The wall's own row plants refusals and counts them itself.
  const refusedIn = (r0) => refusals().slice(r0).filter((r) => !/^check\/wall-(cases|plants)\.mjs:/.test(r.at) && !PLANTED.has(r.n))
  const refusedSay = (list) => `    the wall refused ${list.map((r) => `${r.what}, from ${r.at}`).join('; ')}`
  for (const c of run) {
    now = c.name
    const r0 = refusals().length
    if (c.direct) {
      const t0 = Date.now()
      // A direct case gets the selftest's cases, for one that picks a case by a rule.
      // A case that throws (a refusal by the wall too) is red by what it threw; the run goes on.
      const ok = (await Promise.resolve().then(() => c.direct(CASES)).catch((e) => (console.log(`    threw: ${String(e?.message ?? e).split('\n')[0]}`), false))) && !refusedIn(r0).length
      if (ok) held.push(c.name)
      else failures++
      console.log(`${ok ? 'pass' : 'FAIL'} ${c.name} (${((Date.now() - t0) / 1000).toFixed(1)}s)`)
      if (refusedIn(r0).length) console.log(refusedSay(refusedIn(r0)))
      continue
    }
    const scratch = mkdtempSync(join(tmpdir(), 'barkui-selftest-'))
    try {
      const dir = join(scratch, 'parts')
      const out = join(scratch, 'out')
      let name
      try {
        name = partOf(c)
      } catch (e) {
        failures++
        console.log(`FAIL ${e.message}`)
        continue
      }
      cpSync(join(partsDir, name), join(dir, name), { recursive: true })
      c.plant?.(join(dir, name))
      const t0 = Date.now()
      const logs = []
      const { ok, proof } = await runCheck({ dir, out, proofFile: join(scratch, 'proof.json'), only: c.only, surfaces: c.surfaces ?? false, motion: !!c.motion, states: Array.isArray(c.states) ? c.states : !!c.states, plantCss: c.css, log: (l) => logs.push(l) })
      const secs = (Date.now() - t0) / 1000
      let html = ''
      try {
        html = readFileSync(join(out, 'index.html'), 'utf8')
      } catch {}
      // A case that opens a layer or holds a layer refusal runs in the rest job (check/jobs.mjs, layerMisplaced).
      const misplaced = layerMisplaced(c, topLayerTouch(JSON.parse(readFileSync(join(dir, name, 'part.json'), 'utf8')).layers, proof))
      const refused = refusedIn(r0)
      const pass = (c.green ? ok : !ok) && (await c.expect(proof, html, ok, logs, out)) && secs < CASE_SECONDS && !misplaced && !refused.length
      if (pass) held.push(c.name)
      else failures++
      console.log(`${pass ? 'pass' : 'FAIL'} ${c.name} (${secs.toFixed(1)}s)`)
      // What the run read, so two runs can be held line for line against each other (check/view-pages.mjs).
      const read = lightLines(logs, proof, name)
      console.log(`    the run's lines: ${read.length}, digest ${createHash('sha256').update(read.join('\n')).digest('hex').slice(0, 12)}`)
      if (misplaced) console.log(`    ${misplaced}`)
      if (refused.length) console.log(refusedSay(refused))
      if (!pass) console.log(logs.map((l) => `    ${l}`).join('\n'))
    } catch (e) {
      failures++
      console.log(`FAIL ${c.name}\n    threw: ${String(e?.message ?? e).split('\n')[0]}`)
      if (refusedIn(r0).length) console.log(refusedSay(refusedIn(r0)))
    } finally {
      rmSync(scratch, { recursive: true, force: true })
    }
  }
  const count = { held: run.length - failures, of: run.length }
  console.log(holderSentence())
  console.log(wallLine())
  console.log(`selftest: ${count.held} of ${count.of} cases held, in ${Math.round((Date.now() - start) / 1000)}s`)
  if (report) writeFileSync(report, JSON.stringify(selftestReport({ key, sha: process.env.GITHUB_SHA ?? '', all: CASES.map((c) => c.name), ran: run.map((c) => c.name), held, count })) + '\n')
  process.exit(failures ? 1 : 0)
}

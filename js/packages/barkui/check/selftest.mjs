// node check/selftest.mjs: proves the check can still lose. Each case copies
// the button into a scratch parts folder, plants one break, runs the check on
// it and asserts the run fails for the right reason. A part's own files may not
// style the stage except through part.css, so breaks in paint go in through
// `css`, a sheet the check adds to the build for the selftest alone; other cases
// prove that demo.mjs cannot be that route.
import { appendFileSync, cpSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { partsDir } from '../build/parts.mjs'
import { runCheck } from './check.mjs'

const edit = (file, fn) => writeFileSync(file, fn(readFileSync(file, 'utf8')))
// Runs `code` at the start of the part's demo, with `root` in scope.
const inDemo = (d, code) => edit(join(d, 'demo.mjs'), (s) => s.replace('export default function demo(root) {', `export default function demo(root) {\n${code}`))
const mark = (d) => edit(join(d, 'example.html'), (s) => s.replace('id="button-after"', 'id="button-after" data-paint-free'))
// The "Duplicate" label, wrapped in a plain span.
const wrap = (d) => edit(join(d, 'example.html'), (s) => s.replace('type="button">Duplicate</button>', 'type="button"><span>Duplicate</span></button>'))
const skinsSay = (re) => (p) => re.test(p.parts.button.lights.skins.detail)
const failedSay = (re) => (p) => re.test(p.parts.button.failed ?? '')
// A part.json entry naming a property outside part.css's vocabulary, with its reason (see build/vocabulary.mjs).
const allow = (d, props) => edit(join(d, 'part.json'), (s) => JSON.stringify({ ...JSON.parse(s), allow: { ...JSON.parse(s).allow, ...props } }, null, 2))
const inCss = (rule, props) => (d) => {
  appendFileSync(join(d, 'part.css'), `\n${rule}\n`)
  if (props) allow(d, props)
}
const phoneSays = (re) => (p) => re.test(p.parts.button.lights.phone.detail)
const why = 'planted by the selftest'
const refused = (re) => (p, html, ok, logs) => !ok && p === null && re.test(logs.join('\n'))
const CASES = [
  {
    name: 'a press step that never settles fails by name within its time limit',
    only: ['pressed'],
    plant: (d) => appendFileSync(join(d, 'press.mjs'), "\nsteps.splice(1, 0, { name: 'never settles', expect: () => new Promise(() => {}) })\n"),
    expect: (p) => /never settles.*timed out after/.test(p.parts.button.lights.pressed.detail),
  },
  {
    name: 'one element frozen across skins turns "every skin" off',
    only: ['skins', 'schemes'],
    css: '#button-after { background-color: #ffffff; color: #111111; }',
    expect: skinsSay(/button#button-after .* is not one skin variable/),
  },
  {
    name: 'a paint-free element with its own fill and text turns "every skin" off, by name',
    only: ['skins', 'schemes'],
    plant: mark,
    css: '#button-after { background-color: #ffffff; color: #eeeeee; }',
    expect: skinsSay(/paint-free button#button-after .* carries its own background/),
  },
  {
    name: 'a paint-free wrapper does not hide the button inside it',
    only: ['skins', 'schemes'],
    plant: (d) => edit(join(d, 'example.html'), (s) => s.replace('<ui-button><button id="button-after"', '<ui-button data-paint-free><button id="button-after"')),
    css: '#button-after { background-color: #ffffff; color: #eeeeee; }',
    expect: skinsSay(/button#button-after .* is not one skin variable/),
  },
  {
    name: 'a paint-free element hidden with no script turns "printed with no script" off',
    only: ['noscript'],
    plant: (d) => {
      mark(d)
      inCss('ui-button:not(:defined) > [data-paint-free] { visibility: hidden; }', { visibility: why })(d)
    },
    expect: (p) => /button#button-after .* is hidden/.test(p.parts.button.lights.noscript.detail),
  },
  ...[
    ['a gradient', 'background-image: linear-gradient(#ff0000, #ff0000)', /background-image #1 is not one skin variable/],
    ['a shadow colour', 'box-shadow: 0 0 0 3px #ff0000', /box-shadow #1 is not one skin variable/],
    ['a bitmap image', 'background-image: url(data:image/gif;base64,R0lGODlhAQABAAAAACw=)', /shows an image that is not a data: SVG/],
    ['a right border colour', 'border-right-color: #ff0000', /border-right-color is not one skin variable/],
  ].map(([what, decl, re]) => ({
    name: `${what} on a button turns "every skin" off`,
    only: ['skins', 'schemes'],
    css: `#button-after { ${decl}; }`,
    expect: skinsSay(re),
  })),
  {
    name: 'an icon drawn in its own fill turns "every skin" off',
    only: ['skins', 'schemes'],
    css: '#button-more svg { fill: #ff0000; }',
    expect: skinsSay(/svg .* fill is not one skin variable/),
  },
  {
    name: 'a <style> in example.html fails the run',
    only: ['phone'],
    plant: (d) => edit(join(d, 'example.html'), (s) => `<style>button { background-image: linear-gradient(#ff0000, #ff0000) }</style>\n${s}`),
    expect: (p, html, ok) => !ok && p === null,
  },
  // Round 3: nothing a person can see in the stage goes unread.
  {
    name: 'a label in a plain span, painted the ground colour by part.css, turns "every skin" off',
    only: ['skins', 'schemes'],
    plant: (d) => {
      wrap(d)
      appendFileSync(join(d, 'part.css'), '\n#button-after > span { color: var(--ui-background); }\n')
    },
    expect: skinsSay(/text [\d.]+:1 at span "Duplicate"/),
  },
  {
    name: 'a label in a plain span, painted by part.css through its text fill, turns "every skin" off',
    only: ['skins', 'schemes'],
    plant: (d) => {
      wrap(d)
      inCss('#button-after > span { -webkit-text-fill-color: var(--ui-background); }', { '-webkit-text-fill-color': why })(d)
    },
    expect: skinsSay(/text [\d.]+:1 at span "Duplicate"/),
  },
  {
    name: 'a label in a plain span, faded out by part.css, turns "every skin" off',
    only: ['skins', 'schemes'],
    plant: (d) => {
      wrap(d)
      appendFileSync(join(d, 'part.css'), '\n#button-after > span { opacity: 0.12; }\n')
    },
    expect: skinsSay(/text [\d.]+:1 at span "Duplicate"/),
  },
  {
    name: 'a plain span with a ground of its own turns "every skin" off',
    only: ['skins', 'schemes'],
    plant: wrap,
    css: '#button-after > span { background-color: #ff0000; }',
    expect: skinsSay(/span "Duplicate" background-color is not one skin variable/),
  },
  {
    name: 'a red ::before reaching the page turns "every skin" off',
    only: ['skins', 'schemes'],
    css: '#button-after::before { content: "\\25CF  "; color: #ff0000; }',
    expect: skinsSay(/button#button-after "Duplicate"::before color is not one skin variable/),
  },
  {
    name: 'an ::after label painted the ground colour by part.css turns "every skin" off',
    only: ['skins', 'schemes'],
    plant: (d) => appendFileSync(join(d, 'part.css'), '\n#button-after::after { content: " now"; color: var(--ui-background); }\n'),
    expect: skinsSay(/text [\d.]+:1 at button#button-after "Duplicate"::after/),
  },
  // demo.mjs cannot style: the lint names the line, and the run-time guard catches what dodges the lint.
  {
    name: 'a span coloured by demo.mjs is refused at discovery',
    only: ['phone'],
    plant: (d) => {
      wrap(d)
      inDemo(d, "root.querySelector('#button-after > span').style.color = '#ff0000'")
    },
    expect: refused(/demo\.mjs line 3: sets an inline style/),
  },
  {
    name: 'a class part.css never declares, added by demo.mjs, is refused at discovery',
    only: ['phone'],
    plant: (d) => inDemo(d, "root.querySelector('#button-after').classList.add('loud')"),
    expect: refused(/demo\.mjs line 3: classList\.add uses "loud"/),
  },
  ...[
    ['an inline style spelled to dodge the lint', "root.querySelector('#button-after')['sty' + 'le'].color = '#ff0000'", /button#button-after carries a style attribute/],
    ['a <style> spelled to dodge the lint', "document.head.append(Object.assign(document.createElement('sty' + 'le'), { textContent: '#button-after::before { content: \"x\"; color: #ff0000 }' }))", /a stylesheet the build did not put there/],
    ['a rule slipped into the UI SDK sheet', "const s = [...document['style' + 'Sheets']].find((x) => !x.href); s['insert' + 'Rule']('#button-after { color: #ff0000 }')", /rules changed/],
    ['an adopted sheet', "const S = window['CSS' + 'StyleSheet']; const s = new S(); s['replace' + 'Sync']('#button-after { color: #ff0000 }'); document['adopted' + 'StyleSheets'] = [s]", /adopted/],
    ['a script animation', "root.querySelector('#button-after')['ani' + 'mate']([{ color: '#ff0000' }, { color: '#ff0000' }], { duration: 1e7 })", /a script animation/],
  ].map(([what, code, re]) => ({
    name: `${what} in demo.mjs fails the run, naming what changed`,
    only: ['phone'],
    plant: (d) => inDemo(d, code),
    expect: failedSay(re),
  })),
  {
    name: 'styling at the top of demo.mjs, outside its function, fails the run',
    only: ['phone'],
    plant: (d) => appendFileSync(join(d, 'demo.mjs'), "\ndocument.head.append(Object.assign(document.createElement('sty' + 'le'), { textContent: '#button-after { color: #ff0000 }' }))\n"),
    expect: failedSay(/a stylesheet the build did not put there/),
  },
  {
    name: 'styling that waits until after the demo has run is caught after a press step',
    only: ['pressed'],
    plant: (d) => inDemo(d, "setTimeout(() => { root.querySelector('#button-after')['sty' + 'le'].color = '#ff0000' }, 2500)"),
    expect: failedSay(/after step .*button#button-after carries a style attribute/),
  },
  // Round 4: the check reads from an isolated world, so patching the page's own globals changes nothing it reads.
  // (Spelled so that no lint, now or before, refuses them: these prove the reading, not a pattern.)
  {
    name: 'a demo that replaces getComputedStyle cannot make a red label read as a skin colour',
    only: ['skins', 'schemes'],
    css: '#button-after { color: #ff0000; }',
    plant: (d) => inDemo(d, "const k = 'getComputed' + 'Style'; const g = window[k]; window[k] = (el, p) => g(el && el.id === 'button-after' ? document.querySelector('#button-secondary') : el, p)"),
    expect: skinsSay(/button#button-after "Duplicate" color is not one skin variable/),
  },
  {
    name: 'a demo that patches getClientRects cannot hide a red button from the trace',
    only: ['skins', 'schemes'],
    css: '#button-after { color: #ff0000; }',
    plant: (d) => inDemo(d, "const P = Element['proto' + 'type']; const g = P.getClientRects; P.getClientRects = function () { return this.id === 'button-after' ? [] : g.call(this) }"),
    expect: skinsSay(/button#button-after "Duplicate" color is not one skin variable/),
  },
  {
    name: 'a demo that patches getBoundingClientRect cannot pull a button back inside a phone window',
    only: ['phone'],
    css: '#button-after { position: fixed; left: 370px; top: 0; }',
    plant: (d) => inDemo(d, "const P = Element['proto' + 'type']; const g = P.getBoundingClientRect; P.getBoundingClientRect = function () { const r = g.call(this); return new DOMRect(0, r.y, Math.min(r.width, 1), r.height) }"),
    expect: (p) => /Duplicate ends past the window/.test(p.parts.button.lights.phone.detail),
  },
  {
    name: 'a demo that patches querySelector cannot point the check at another element',
    only: ['skins', 'schemes'],
    css: '#button-after { color: #ff0000; }',
    plant: (d) => inDemo(d, "const P = Document['proto' + 'type']; const q = P.querySelector; P.querySelector = function (s) { return q.call(this, s === '[data-part=\"button\"]' ? '.sr-title' : s) }"),
    expect: skinsSay(/button#button-after "Duplicate" color is not one skin variable/),
  },
  {
    name: 'a control edge under 3:1 turns "every skin" off',
    only: ['skins', 'schemes'],
    css: '[data-part="button"] ui-button { --ui-input: var(--ui-muted); }',
    expect: skinsSay(/control boundary [\d.]+:1 at button.*, needs 3:1/),
  },
  // Round 5: text is judged by what is drawn; a control's boundary is measured whatever token draws it.
  // Every one of these is ordinary part.css that the lint lets through.
  ...[
    ['a full-size ::after filled with the ground over a label',
      '[data-slot="button"][data-size="lg"] { position: relative; }\n[data-slot="button"][data-size="lg"]::after { content: ""; position: absolute; inset: 0; background-color: var(--ui-background); }',
      /text does not draw at button "Large"/],
    ['filter: brightness(0.25) on hover', '[data-slot="button"]:not([data-variant]):hover { filter: brightness(0.25); }', /drawn text [\d.]+:1 at button "Hover"/, { filter: why }],
    ['mix-blend-mode on a button', '[data-slot="button"]:not([data-variant]) { mix-blend-mode: screen; }', /(text does not draw|drawn text [\d.]+:1) at button/, { 'mix-blend-mode': why }],
    ['opacity on an ancestor', 'ui-button:has(> #button-secondary) { display: inline-flex; opacity: 0.15; }', /drawn text [\d.]+:1 at button#button-secondary/],
    ['a clip-path that hides the label', '[data-slot="button"][data-size="lg"] { clip-path: inset(50%); }', /text does not draw at button "Large"/, { 'clip-path': why }],
    ['a mask that hides the label', '#button-quiet { mask-image: linear-gradient(transparent, transparent); }', /text does not draw at button#button-quiet/, { 'mask-image': why }],
    ['a control with no edge and no fill', '#button-after { --bark-button-edge: transparent; --bark-button-bg: transparent; }', /control boundary 1(\.00)?:1 at button#button-after/],
  ].map(([what, rule, re, props]) => ({
    name: `${what} in part.css turns "every skin" off`,
    only: ['skins', 'schemes'],
    plant: inCss(rule, props),
    expect: skinsSay(re),
  })),
  {
    name: 'font-size: 0 on a size turns "every skin" off',
    only: ['skins', 'schemes'],
    css: '[data-slot="button"][data-size="sm"] { font-size: 0; }',
    expect: skinsSay(/text does not draw at button "Small"/),
  },
  {
    name: 'an edge in --ui-border, with the paint entry that pinned it removed, turns "every skin" off',
    only: ['skins', 'schemes'],
    plant: (d) => {
      edit(join(d, 'part.css'), (s) => s.replace('--bark-button-edge: var(--ui-input);', '--bark-button-edge: var(--ui-border);'))
      edit(join(d, 'part.json'), (s) => s.replace(', "border-top-color": "--ui-input"', ''))
    },
    expect: skinsSay(/control boundary [\d.]+:1 at button/),
  },
  // Round 6: everything in a stage draws in full, in every view part.css can target; text-only is a fact, not a switch.
  ...[
    ['a label pushed out of its own box', '[data-slot="button"][data-size="lg"] { overflow: hidden; justify-content: flex-start; text-indent: -2.6em; }', /label is cut: \d+% of it draws at button "Large"/, { 'text-indent': why }],
    ['a label in a box of no height', '[data-slot="button"][data-size="lg"] { height: 0; min-height: 0; overflow: hidden; }', /label is cut: \d+% of it draws at button "Large"/],
    ['a label truncated by the usual recipe', '#button-secondary { max-width: 3.4em; overflow: hidden; white-space: nowrap; justify-content: flex-start; }', /label is cut: \d+% of it draws at button#button-secondary/],
    ['a label covered by its neighbour', '[data-slot="button"][data-size="lg"] { margin-inline-end: -40px; }\nui-button:has(> [data-size="lg"]) + ui-button > [data-slot="button"] { position: relative; }', /label is cut: \d+% of it draws at button "Large"/],
    ['an icon faded out', '#button-more > svg { opacity: 0.1; }', /drawn graphic [\d.]+:1 at button#button-more/],
    ['an icon in a weak colour', '#button-more { color: var(--ui-border); }', /drawn graphic [\d.]+:1 at button#button-more/],
    ['an icon-only control filtered away', '#button-more { filter: opacity(0.08); }', /(drawn graphic [\d.]+:1|has nothing to show) at button#button-more/, { filter: why }],
    ['an icon-only control hidden', 'ui-button:defined > #button-more { visibility: hidden; }', /(does not draw|has nothing to show) at button#button-more/, { visibility: why }],
    ['an icon-only control clipped away', 'ui-button:defined > #button-more { clip-path: inset(50%); }', /(does not draw|is cut: \d+% of it draws|has nothing to show) at button#button-more/, { 'clip-path': why }],
  ].map(([what, rule, re, props]) => ({
    name: `${what} turns "every skin" off`,
    only: ['skins', 'schemes'],
    plant: inCss(rule, props),
    expect: skinsSay(re),
  })),
  {
    name: 'a label drawn as an <img> in a weak colour turns "every skin" off',
    only: ['skins', 'schemes'],
    plant: (d) => edit(join(d, 'example.html'), (s) => s.replace('data-size="lg" type="button">Large</button>',
      `data-size="lg" type="button"><img alt="Large" src="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='40' height='14'%3E%3Crect width='40' height='14' fill='%23eeeeee'/%3E%3C/svg%3E"></button>`)),
    expect: skinsSay(/drawn graphic [\d.]+:1 at button "" img/),
  },
  {
    name: 'a label blanked at phone width turns "phone" off',
    only: ['phone'],
    plant: inCss('@media (max-width: 600px) { [data-slot="button"][data-size="lg"] { --bark-button-fg: var(--ui-background); } }'),
    expect: phoneSays(/(text does not draw|drawn text [\d.]+:1) at button "Large"/),
  },
  {
    name: 'edges dropped at phone width turn "phone" off',
    only: ['phone'],
    plant: inCss('@media (max-width: 600px) { [data-slot="button"]:not([data-variant]) { --bark-button-edge: transparent; } }'),
    expect: phoneSays(/control boundary [\d.]+:1 at button/),
  },
  {
    name: 'a colour that only applies when motion is allowed is refused at discovery',
    only: ['phone'],
    plant: inCss('@media (prefers-reduced-motion: no-preference) { [data-slot="button"][data-size="lg"] { color: var(--ui-background); } }'),
    expect: refused(/part\.css line \d+: .*prefers-reduced-motion.* only transition, animation and scroll-behavior/),
  },
  {
    name: 'text-only on controls that draw a faint edge turns "every skin" off',
    only: ['skins', 'schemes'],
    plant: (d) => {
      edit(join(d, 'part.css'), (s) => s.replace('--bark-button-edge: var(--ui-input);', '--bark-button-edge: var(--ui-border);'))
      edit(join(d, 'part.json'), (s) => s.replace(', "border-top-color": "--ui-input"', '').replace('"textOnly": ["[data-variant=\\"ghost\\"]"]', '"textOnly": ["[data-variant=\\"ghost\\"]", "[data-slot=\\"button\\"]:not([data-variant])"]'))
    },
    expect: skinsSay(/text-only button.* draws its (edge|fill) at [\d.]+:1/),
  },
  {
    name: 'an honest decorative dot keeps "every skin" on',
    only: ['skins', 'schemes'],
    green: true,
    plant: inCss('#button-after::before { content: ""; display: inline-block; width: 6px; height: 6px; border-radius: 50%; background: var(--ui-primary); }'),
    expect: (p) => p.parts.button.lights.skins.pass && p.parts.button.lights.schemes.pass,
  },
  {
    name: 'a focus ring that cannot be seen against its ground turns the skins off',
    only: ['skins', 'schemes'],
    css: 'ui-button:has(> #button-primary) { display: inline-block; padding: 12px; background-color: var(--ui-primary); }',
    expect: (p) => /focus on button#button-primary.*edge [\d.]+:1 against the ground/.test(p.parts.button.lights.skins.detail),
  },
  ...[
    ['visibility: hidden', /is hidden/],
    ['opacity: 0', /is hidden|opaque/],
  ].map(([rule, why]) => ({
    name: `no-script content under ${rule} turns "printed with no script" off`,
    only: ['noscript'],
    plant: inCss(`ui-button:not(:defined) > [data-slot] { ${rule}; }`, { visibility: why }),
    expect: (p) => why.test(p.parts.button.lights.noscript.detail),
  })),
  {
    name: 'no-script content clipped to a sliver turns "printed with no script" off',
    only: ['noscript'],
    plant: (d) => appendFileSync(join(d, 'part.css'), '\nui-button:not(:defined) { display: inline-block; width: 6px; overflow: hidden; }\n'),
    expect: (p) => /cut off|clipped/.test(p.parts.button.lights.noscript.detail),
  },
  {
    name: 'an icon-only button with no name turns "pressed" off',
    only: ['pressed'],
    plant: (d) => edit(join(d, 'example.html'), (s) => s.replace(' aria-label="More actions"', '')),
    expect: (p) => /#button-more name=""/.test(p.parts.button.lights.pressed.detail),
  },
  {
    name: 'a console error lights nothing, and the page says the run failed',
    only: ['phone'],
    plant: (d) => edit(join(d, 'demo.mjs'), (s) => s.replace('export default function demo(root) {', "export default function demo(root) {\n  console.error('planted')")),
    expect: (p, html) => p.parts.button.failed && !p.parts.button.lights.phone.pass && !html.includes('data-on="true"') && html.includes('The last check run failed'),
  },
  {
    name: 'a part folder without press.mjs fails the run',
    only: ['phone'],
    plant: (d) => rmSync(join(d, 'press.mjs')),
    expect: (p, html, ok) => !ok && p === null,
  },
]

let failures = 0
// node check/selftest.mjs <words>: only the cases whose name holds those words.
const pick = process.argv.slice(2).join(' ')
const run = CASES.filter((c) => c.name.includes(pick))
for (const c of run) {
  const scratch = mkdtempSync(join(tmpdir(), 'barkui-selftest-'))
  try {
    const dir = join(scratch, 'parts')
    cpSync(join(partsDir, 'button'), join(dir, 'button'), { recursive: true })
    c.plant?.(join(dir, 'button'))
    const t0 = Date.now()
    const logs = []
    const { ok, proof } = await runCheck({ dir, out: join(scratch, 'out'), proofFile: join(scratch, 'proof.json'), only: c.only, surfaces: false, plantCss: c.css, log: (l) => logs.push(l) })
    const secs = (Date.now() - t0) / 1000
    let html = ''
    try {
      html = readFileSync(join(scratch, 'out', 'index.html'), 'utf8')
    } catch {}
    const held = (c.green ? ok : !ok) && c.expect(proof, html, ok, logs) && secs < 60
    if (!held) failures++
    console.log(`${held ? 'pass' : 'FAIL'} ${c.name} (${secs.toFixed(1)}s)`)
    if (!held) console.log(logs.map((l) => `    ${l}`).join('\n'))
  } finally {
    rmSync(scratch, { recursive: true, force: true })
  }
}
console.log(`selftest: ${run.length - failures} of ${run.length} breaks caught`)
process.exit(failures ? 1 : 0)

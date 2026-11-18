// node check/selftest.mjs: proves the check can still lose. Each case copies
// the button into a scratch parts folder, plants one break, runs the check on
// it and asserts the light that should go off does, for the right reason.
import { appendFileSync, cpSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { partsDir } from '../build/parts.mjs'
import { runCheck } from './check.mjs'

const edit = (file, fn) => writeFileSync(file, fn(readFileSync(file, 'utf8')))
// Runs `code` at the start of the part's demo, with `root` in scope (example.html holds markup only).
const inDemo = (d, code) => edit(join(d, 'demo.mjs'), (s) => s.replace('export default function demo(root) {', `export default function demo(root) {\n${code}`))
const mark = (d) => edit(join(d, 'example.html'), (s) => s.replace('id="button-after"', 'id="button-after" data-paint-free'))
const skinsSay = (re) => (p) => re.test(p.parts.button.lights.skins.detail)
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
    plant: (d) => inDemo(d, "root.querySelector('#button-after').style.cssText = 'background-color: #ffffff; color: #111111'"),
    expect: skinsSay(/button#button-after .* is not one skin variable/),
  },
  {
    name: 'a paint-free element with its own fill and text turns "every skin" off, by name',
    only: ['skins', 'schemes'],
    plant: (d) => {
      mark(d)
      inDemo(d, "root.querySelector('#button-after').style.cssText = 'background-color: #ffffff; color: #eeeeee'")
    },
    expect: skinsSay(/paint-free button#button-after .* carries its own background/),
  },
  {
    name: 'a paint-free wrapper does not hide the button inside it',
    only: ['skins', 'schemes'],
    plant: (d) => {
      edit(join(d, 'example.html'), (s) => s.replace('<ui-button><button id="button-after"', '<ui-button data-paint-free><button id="button-after"'))
      inDemo(d, "root.querySelector('#button-after').style.cssText = 'background-color: #ffffff; color: #eeeeee'")
    },
    expect: skinsSay(/button#button-after .* is not one skin variable/),
  },
  {
    name: 'a paint-free element hidden with no script turns "printed with no script" off',
    only: ['noscript'],
    plant: (d) => {
      mark(d)
      appendFileSync(join(d, 'part.css'), '\nui-button:not(:defined) > [data-paint-free] { visibility: hidden; }\n')
    },
    expect: (p) => /button#button-after .* is hidden/.test(p.parts.button.lights.noscript.detail),
  },
  ...[
    ['a gradient', "style.backgroundImage = 'linear-gradient(#ff0000, #ff0000)'", /background-image #1 is not one skin variable/],
    ['a shadow colour', "style.boxShadow = '0 0 0 3px #ff0000'", /box-shadow #1 is not one skin variable/],
    ['a bitmap image', "style.backgroundImage = 'url(data:image/gif;base64,R0lGODlhAQABAAAAACw=)'", /shows an image that is not a data: SVG/],
    ['a right border colour', "style.borderRightColor = '#ff0000'", /border-right-color is not one skin variable/],
  ].map(([what, code, re]) => ({
    name: `${what} set on a button turns "every skin" off`,
    only: ['skins', 'schemes'],
    plant: (d) => inDemo(d, `root.querySelector('#button-after').${code}`),
    expect: skinsSay(re),
  })),
  {
    name: 'an icon drawn in its own fill turns "every skin" off',
    only: ['skins', 'schemes'],
    plant: (d) => inDemo(d, "root.querySelector('#button-more svg').style.fill = '#ff0000'"),
    expect: skinsSay(/svg .* fill is not one skin variable/),
  },
  {
    name: 'a <style> in example.html fails the run',
    only: ['phone'],
    plant: (d) => edit(join(d, 'example.html'), (s) => `<style>button { background-image: linear-gradient(#ff0000, #ff0000) }</style>\n${s}`),
    expect: (p, html, ok) => !ok && p === null,
  },
  {
    name: 'a focus ring that cannot be seen against its ground turns the skins off',
    only: ['skins', 'schemes'],
    plant: (d) => inDemo(d, "const b = root.querySelector('#button-primary').parentElement; const w = document.createElement('span'); w.style.cssText = 'padding: 12px; background: var(--ui-primary)'; b.before(w); w.append(b)"),
    expect: (p) => /focus on button#button-primary.*edge [\d.]+:1 against the ground/.test(p.parts.button.lights.skins.detail),
  },
  ...[
    ['visibility: hidden', /is hidden/],
    ['opacity: 0', /is hidden|opaque/],
  ].map(([rule, why]) => ({
    name: `no-script content under ${rule} turns "printed with no script" off`,
    only: ['noscript'],
    plant: (d) => appendFileSync(join(d, 'part.css'), `\nui-button:not(:defined) > [data-slot] { ${rule}; }\n`),
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
for (const c of CASES) {
  const scratch = mkdtempSync(join(tmpdir(), 'barkui-selftest-'))
  try {
    const dir = join(scratch, 'parts')
    cpSync(join(partsDir, 'button'), join(dir, 'button'), { recursive: true })
    c.plant(join(dir, 'button'))
    const t0 = Date.now()
    const logs = []
    const { ok, proof } = await runCheck({ dir, out: join(scratch, 'out'), proofFile: join(scratch, 'proof.json'), only: c.only, log: (l) => logs.push(l) })
    const secs = (Date.now() - t0) / 1000
    let html = ''
    try {
      html = readFileSync(join(scratch, 'out', 'index.html'), 'utf8')
    } catch {}
    const held = !ok && c.expect(proof, html, ok) && secs < 60
    if (!held) failures++
    console.log(`${held ? 'pass' : 'FAIL'} ${c.name} (${secs.toFixed(1)}s)`)
    if (!held) console.log(logs.map((l) => `    ${l}`).join('\n'))
  } finally {
    rmSync(scratch, { recursive: true, force: true })
  }
}
console.log(`selftest: ${CASES.length - failures} of ${CASES.length} breaks caught`)
process.exit(failures ? 1 : 0)

// The selftest's planting tools and its ladder (check/selftest.mjs runs the cases). Each plant edits a scratch
// copy of a part; each check reads a run's proof and log for the reason a light is off.
import { spawnSync } from 'node:child_process'
import { appendFileSync, cpSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { chromium } from 'playwright'
import { capacitySentence, selftestSentence } from './capacity.mjs'

export const edit = (file, fn) => writeFileSync(file, fn(readFileSync(file, 'utf8')))
// Runs `code` at the start of the part's demo, with `root` in scope.
export const inDemo = (d, code) => edit(join(d, 'demo.mjs'), (s) => s.replace('export default function demo(root) {', `export default function demo(root) {\n${code}`))
export const mark = (d, id) => edit(join(d, 'example.html'), (s) => s.replace(`id="${id}"`, `id="${id}" data-paint-free`))
// The "Duplicate" label, wrapped in a plain span.
export const wrap = (d) => edit(join(d, 'example.html'), (s) => s.replace('type="button">Duplicate</button>', 'type="button"><span>Duplicate</span></button>'))
export const inCss = (rule) => (d) => appendFileSync(join(d, 'part.css'), `\n${rule}\n`)
export const all = (...plants) => (d) => plants.forEach((p) => p(d))
// A copy of the part beside it, under another name, its ids renamed to match.
export const copyAs = (d, name) => {
  const to = join(d, '..', name)
  cpSync(d, to, { recursive: true })
  for (const f of ['part.json', 'example.html', 'press.mjs', 'demo.mjs'])
    edit(join(to, f), (t) => t.replace(/(["'#,])button-/g, `$1${name}-`).replace('"name": "button"', `"name": "${name}"`))
  return to
}
export const lights = (p) => p?.parts?.button?.lights ?? {}
export const reasons = (p, l) => lights(p)[l]?.fails ?? [lights(p)[l]?.detail ?? '']
export const says = (l, re) => (p) => !lights(p)[l]?.pass && reasons(p, l).some((f) => re.test(f))
export const skinsSay = (re) => says('skins', re)
export const phoneSays = (re) => says('phone', re)
export const failedSay = (re) => (p) => re.test(p.parts.button.failed ?? '')
// A drawn reading at the planted control, in both wide lights: which reading (gone, cut, not itself, faint) is
// the rasteriser's to decide, so a plant asserts only what holds on every machine.
export const DRAWN = String.raw`(does not draw|is cut: \d+% of it draws|is not drawn as itself: [\d.]+ of it matches its own words drawn alone, needs [\d.]+,|drawn (text|graphic) [\d.]+:1|has nothing to show)`
export const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
export const drawnOff = (control) => (p) => ['skins', 'schemes'].every((l) => says(l, new RegExp(`${DRAWN} at ${esc(control)}`))(p))
export const both = (re) => (p) => ['skins', 'schemes'].every((l) => says(l, re)(p))
export const refused = (re) => (p, html, ok, logs) => !ok && p === null && re.test(logs.join('\n'))
// Several plants in one run: every one must hold.
export const each = (checks) => async (...a) => {
  const missed = []
  for (const [what, check] of Object.entries(checks)) if (!(await check(...a))) missed.push(what)
  if (missed.length) console.log(`    not caught: ${missed.join('; ')}`)
  return !missed.length
}

// The ladder: a ten-letter label, cut and covered step by step. README.md says where it turns the lights off.
export const STEPS = [1, 2, 3, 4, 5, 6, 7]
export const LADDERS = {
  cut: (k) => `#button-ladder-cut-${k} { clip-path: inset(0 ${k}px 0 0); }`,
  ground: (k) => `#button-ladder-ground-${k} > i { position: absolute; right: 0; top: 50%; translate: 0 -50%; width: ${k}px; height: ${k}px; background: var(--bark-button-bg); }`,
  ink: (k) => `#button-ladder-ink-${k} > i { position: absolute; right: 0; top: 50%; translate: 0 -50%; width: ${k}px; height: ${k}px; background: currentColor; }`,
}
// A square is a plain empty element in the label (not a graphic of its own), so only the label's reading sees it.
export const ladderHtml = Object.keys(LADDERS).map((kind) => `<div data-demo-row>${STEPS.map((k) => `<ui-button><button data-slot="button" type="button"><span id="button-ladder-${kind}-${k}">Duplicates${kind === 'cut' ? '' : '<i></i>'}</span></button></ui-button>`).join('')}</div>`).join('\n')
export const ladderCss = ['[id^="button-ladder-"] { position: relative; }', ...Object.values(LADDERS).flatMap((f) => STEPS.map(f))].join('\n')
export const README = new URL('../README.md', import.meta.url)
/** README.md's claim: the label's width on this machine and the first step of each ladder that turns the lights off. */
export function ladderClaim(text = readFileSync(README, 'utf8')) {
  const m = text.replace(/\s+/g, ' ').match(/ten-letter label (\d+) px wide \(in CI, on Linux; (\d+) px on macOS\) turns the lights off when its last (\d+) px are cut away, when a (\d+) px square of its ground covers its end, or when a (\d+) px square of its ink is laid over its end; (\d+) px, (\d+) px and (\d+) px leave them on/)
  if (!m) return null
  const [linux, mac, cut, ground, ink, cutOn, groundOn, inkOn] = m.slice(1).map(Number)
  return { width: process.platform === 'darwin' ? mac : linux, first: { cut, ground, ink }, on: { cut: cutOn, ground: groundOn, ink: inkOn } }
}
export const ladderHolds = async (p, html, ok, logs, out) => {
  const claim = ladderClaim()
  if (!claim) return console.log('    README.md has no ladder sentence'), false
  const off = (l) => new Set(reasons(p, l).flatMap((f) => [...f.matchAll(/at span#button-ladder-(\w+)-(\d+)/g)].map((m) => `${m[1]} ${m[2]}`)))
  const [light, dark] = [off('skins'), off('schemes')]
  const seen = {}
  let held = true
  for (const kind of Object.keys(LADDERS)) {
    const offs = STEPS.filter((k) => light.has(`${kind} ${k}`) && dark.has(`${kind} ${k}`))
    seen[kind] = offs[0]
    const clean = offs.length && offs.every((k, i) => k === offs[0] + i) && offs.at(-1) === STEPS.at(-1) && STEPS.filter((k) => k < offs[0]).every((k) => !light.has(`${kind} ${k}`) && !dark.has(`${kind} ${k}`))
    if (!clean || offs[0] !== claim.first[kind] || claim.on[kind] !== claim.first[kind] - 1) held = false
  }
  // The label's width, read from the same build in the same browser.
  const browser = await chromium.launch({ args: ['--disable-lcd-text'] })
  let width = 0
  try {
    const page = await browser.newPage()
    await page.goto(pathToFileURL(join(out, 'index.html')).href)
    width = Math.round(await page.evaluate(() => document.querySelector('#button-ladder-cut-1').getBoundingClientRect().width))
  } finally {
    await browser.close()
  }
  console.log(`    ladder: a ten-letter label ${width} px wide turns the lights off at a ${seen.cut} px cut, a ${seen.ground} px square of its ground, a ${seen.ink} px square of its ink (README.md: ${claim.width} px, ${claim.first.cut}, ${claim.first.ground}, ${claim.first.ink})`)
  return held && width === claim.width
}

// A ceiling passed fails the run at that moment, wherever it is (ceiling.mjs): a ceiling of 1 s, lowered for
// the test, against a check run and a selftest case that each take longer.
export const CEILING_CASES = [
  {
    name: 'a check run that passes its ceiling stops there, failing, with the sentence',
    direct: async () => {
      const r = spawnSync(process.execPath, [join(import.meta.dirname, 'run.mjs')], { env: { ...process.env, BARKUI_CEILING_SECONDS: '1' }, encoding: 'utf8', timeout: 60000 })
      return r.status === 1 && r.stdout.includes(`check: FAIL the run passed its ceiling of 1 s for `) && r.stdout.includes(capacitySentence()) && !/part\(s\); /.test(r.stdout)
    },
  },
  {
    name: 'a selftest whose last case passes its ceiling stops there, failing, with the sentence',
    direct: async () => {
      const r = spawnSync(process.execPath, [join(import.meta.dirname, 'selftest.mjs'), 'a page whose barkui.css differs from a part'], { env: { ...process.env, BARKUI_CEILING_SECONDS: '1' }, encoding: 'utf8', timeout: 60000 })
      return r.status === 1 && r.stdout.includes('FAIL the selftest passed its ceiling of 1 s while "a page whose barkui.css differs') && r.stdout.includes(selftestSentence()) && !r.stdout.includes('cases held')
    },
  },
]

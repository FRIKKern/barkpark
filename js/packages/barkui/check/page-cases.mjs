// The selftest's rows for the skins light on pages open at once (check/view-pages.mjs): the light read on two pages
// is line for line the light read on one, and the compare that says so can fail: a view whose reading changes on the
// second page alone is seen, by its name.
import { cpSync, mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { partsDir } from '../build/parts.mjs'
import { skinNames, tokensPath } from '../build/showroom.mjs'
import { runCheck } from './check.mjs'
import { spread, viewList } from './view-pages.mjs'

const PART = 'tabs'
/** The lights the compare reads: the views of the skins light. */
const ONLY = ['skins', 'schemes']
const SKINS = skinNames(readFileSync(tokensPath, 'utf8'))
const VIEWS = viewList(SKINS)
/** A declaration in one view alone. */
const inView = ({ skin, scheme }, sel, decl) => `html[data-skin="${skin}"][data-color-scheme="${scheme}"] ${sel} { ${decl} }`
/** The compare is of one page against two. */
const TWO = spread(VIEWS, 2)
/** Fails in a view on each page, so the lines compared are lines of both: a label not drawn, in a view each page
    reads, named with that view. */
const BASE = TWO.map((share, j) => inView(share[1], j ? '#tabs-settings' : '#tabs-analytics', 'color: transparent;')).join('\n')
const BASE_AT = TWO.map((share) => `${share[1].skin} ${share[1].scheme}`)
/** The plant: a view of the second page's alone, its reading changed only where two pages read. */
const CHANGED = TWO[1][0]
const PLANT = inView(CHANGED, '#tabs-overview', 'color: transparent;')

/** Every line the light leaves, as the selftest reads a run: its log, and the part's entry in the proof. A number of
    seconds is no reading and is left out. */
export function lightLines(logs, proof, part = PART) {
  const e = proof?.parts?.[part] ?? {}
  const lights = Object.entries(e.lights ?? {}).flatMap(([k, l]) => [`${k}: ${l.pass ? 'on' : 'OFF'} ${l.detail}`, ...(l.fails ?? []).map((f) => `${k} fails: ${f}`)])
  // The time the top layer took is no reading.
  const measures = e.measures?.layers ? { ...e.measures, layers: { ...e.measures.layers, seconds: '#' } } : e.measures
  const rest = Object.entries({ measures, paintFree: e.paintFree, textOnly: e.textOnly, unread: e.unread, failed: e.failed }).map(([k, v]) => `${k}: ${JSON.stringify(v ?? null)}`)
  return [...logs, ...lights, ...rest].map((l) => l.replace(/\d+(\.\d+)? s\b/g, '# s'))
}
/** The lines in one list and not the other, either way, each as often as it is missing. */
export function differ(a, b) {
  const less = (x, y) => {
    const left = [...y]
    return x.filter((l) => {
      const i = left.indexOf(l)
      if (i < 0) return true
      left.splice(i, 1)
      return false
    })
  }
  return [...less(a, b), ...less(b, a)]
}
/** The light alone, on `pages` pages, with `css` planted: its lines. */
async function read(pages, css) {
  const scratch = mkdtempSync(join(tmpdir(), 'barkui-selftest-'))
  try {
    const dir = join(scratch, 'parts')
    cpSync(join(partsDir, PART), join(dir, PART), { recursive: true })
    const logs = []
    const { proof } = await runCheck({ dir, out: join(scratch, 'out'), proofFile: join(scratch, 'proof.json'), only: ONLY, surfaces: false, motion: false, states: false, plantCss: css, log: (l) => logs.push(l), viewPages: pages })
    return lightLines(logs, proof)
  } finally {
    rmSync(scratch, { recursive: true, force: true })
  }
}

const same = async () => {
  const [one, two] = [await read(1, BASE), await read(2, BASE)]
  const d = differ(one, two)
  const fails = one.filter((l) => / fails: /.test(l))
  const by = BASE_AT.map((at) => `${fails.filter((l) => l.includes(`${at} on base`)).length} in ${at}`)
  console.log(`    lines that differ between one page and two: ${d.length} of ${one.length}; the fails the plant makes: ${by.join(' and ')}, one view on each page${d.length ? `: ${d.slice(0, 3).join(' | ')}` : ''}`)
  return d.length === 0 && BASE_AT.every((at) => fails.some((l) => l.includes(`${at} on base`))) && one.some((l) => l.includes(`views the skins light read: ${VIEWS.length} of ${VIEWS.length}; on two pages: 0; on none: 0`))
}
const seen = async () => {
  const [one, two] = [await read(1, BASE), await read(2, `${BASE}\n${PLANT}`)]
  const d = differ(one, two)
  const at = `${CHANGED.skin} ${CHANGED.scheme}`
  const named = d.filter((l) => l.includes(at))
  console.log(`    with the ${at} view changed on the second page alone: ${d.length} lines differ, ${named.length} of them naming ${at}`)
  return d.length > 0 && named.length > 0
}

export const PAGE_CASES = [
  { name: 'two pages at once: the skins light reads line for line on two pages what it reads on one', only: ONLY, direct: same },
  { name: 'two pages at once: a view whose reading changes on the second page alone is seen by the compare, by its name', only: ONLY, direct: seen },
]
